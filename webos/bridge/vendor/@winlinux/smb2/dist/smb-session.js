// Public SMB2 session API. One SmbSession per server connection.
// Paths are share-relative with forward slashes; the protocol layer converts
// them to SMB backslash form. Credentials pass through to the AuthProvider
// untouched — this module never reads passwords.
import { pipeline } from "node:stream/promises";
import { createWriteStream } from "node:fs";
import { open, rm } from "node:fs/promises";
import Client from "./client/Client.js";
import File from "./client/File.js";
import PacketType from "./protocol/smb2/PacketType.js";
import * as structureUtil from "./protocol/structureUtil.js";
import { CreateOptions } from "./protocol/smb2/packets/Create.js";
import { FileInfoClass, InfoType } from "./protocol/smb2/packets/SetInfo.js";
import CreateDispositionType from "./protocol/smb2/CreateDispositionType.js";
import FilePipePrinterAccess from "./protocol/smb2/FilePipePrinterAccess.js";
import * as util from "./protocol/util.js";
import { SmbAccessDeniedError, SmbConnectionError, SmbEncryptionRequiredError, SmbError, SmbFileTooLargeError, SmbIsADirectoryError, SmbNotADirectoryError, throwIfAborted, toSmbError, } from "./errors.js";
import { SHI1005_FLAGS_ENCRYPT_DATA, SrvsvcClient } from "./rpc/srvsvc.js";
export const DEFAULT_PORT = 445;
export const DEFAULT_REQUEST_TIMEOUT_MS = 30_000;
// readFile/writeFile buffer whole files; bigger transfers must stream.
export const MAX_BUFFERED_FILE_BYTES = 64 * 1024 * 1024;
export async function connect(opts) {
    const client = new Client(opts.host, {
        port: opts.port ?? DEFAULT_PORT,
        requestTimeout: opts.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS,
        ...(opts.connectTimeoutMs !== undefined ? { connectTimeout: opts.connectTimeoutMs } : {}),
    });
    try {
        const session = await client.authenticate({
            authProvider: opts.authProvider,
            credentials: opts.credentials,
            signing: opts.signing,
            ...(opts.maxDialect ? { maxDialect: opts.maxDialect } : {}),
        });
        return new SmbSession(client, session);
    }
    catch (error) {
        await client.close().catch(() => undefined);
        const typed = toSmbError(error, `connect to ${opts.host}`);
        if (typed instanceof SmbError)
            throw typed;
        if (error instanceof Error) {
            const wrapped = new SmbConnectionError(`cannot connect to ${opts.host}:${opts.port ?? DEFAULT_PORT}: ${error.message}`);
            wrapped.cause = error;
            throw wrapped;
        }
        throw typed;
    }
}
function toDirEntry(entry) {
    return {
        name: entry.filename.replace(/^\.\//, ""),
        isDirectory: entry.type === "Directory",
        sizeBytes: entry.fileSize,
        mtime: entry.lastWriteTime,
        isReparsePoint: entry.fileAttributes.includes("ReparsePoint"),
    };
}
export class SmbSession {
    client;
    session;
    trees = new Map();
    constructor(client, session) {
        this.client = client;
        this.session = session;
    }
    get security() {
        return { ...this.session.security };
    }
    async treeFor(share) {
        let tree = this.trees.get(share);
        if (!tree) {
            try {
                tree = await this.session.connectTree(share);
            }
            catch (error) {
                const typed = toSmbError(error, `tree connect to ${share}`);
                if (typed instanceof SmbAccessDeniedError && !(typed instanceof SmbEncryptionRequiredError)) {
                    throw await this.refineTreeConnectDenied(share, typed);
                }
                throw typed;
            }
            this.trees.set(share, tree);
        }
        return tree;
    }
    // Windows answers a TREE_CONNECT to a share that requires encryption, on a
    // dialect below 3.0 with RejectUnencryptedAccess on (the default), with a
    // bare STATUS_ACCESS_DENIED (MS-SMB2 3.3.5.7). The error response carries
    // no ShareFlags, so the SMB exchange alone cannot tell it from a share ACL
    // that excludes the account. SRVSVC NetrShareGetInfo level 1005 can: its
    // shi1005_flags carry SHI1005_FLAGS_ENCRYPT_DATA (MS-SRVS 2.2.4.29). The
    // probe runs over IPC$ on this session. When it fails for any reason, or
    // the flag is clear, the original access-denied error stands, so a real
    // ACL deny is never reported as an encryption problem.
    async refineTreeConnectDenied(share, denied) {
        let flags;
        try {
            flags = await new SrvsvcClient(this.session).getShareFlags(share);
        }
        catch {
            return denied;
        }
        if ((flags & SHI1005_FLAGS_ENCRYPT_DATA) === 0)
            return denied;
        return new SmbEncryptionRequiredError(`share ${share} requires SMB encryption, which this connection did not negotiate (dialect ${this.session.security.dialect || "unknown"}, cipher ${this.session.security.cipher})`, denied.status);
    }
    async listShares() {
        try {
            return await new SrvsvcClient(this.session).enumShares();
        }
        catch (error) {
            throw toSmbError(error, "list shares");
        }
    }
    async list(share, dirPath, opts = {}) {
        const context = `list ${share}/${dirPath ?? ""}`;
        throwIfAborted(opts.signal, context);
        try {
            const tree = await this.treeFor(share);
            const entries = await tree.readDirectory(dirPath ?? "", { signal: opts.signal });
            return entries.map(toDirEntry);
        }
        catch (error) {
            throw toSmbError(error, context);
        }
    }
    async *listIter(share, dirPath, opts = {}) {
        const context = `list ${share}/${dirPath ?? ""}`;
        throwIfAborted(opts.signal, context);
        let tree;
        try {
            tree = await this.treeFor(share);
        }
        catch (error) {
            throw toSmbError(error, context);
        }
        // The handle closes when the pages end, when the consumer stops early
        // (return() on this iterator closes the inner one) or on an error.
        const pages = tree.readDirectoryPages(dirPath ?? "", { signal: opts.signal });
        try {
            for await (const page of pages) {
                for (const entry of page)
                    yield toDirEntry(entry);
            }
        }
        catch (error) {
            throw toSmbError(error, context);
        }
    }
    async stat(share, filePath, opts = {}) {
        const context = `stat ${share}/${filePath}`;
        throwIfAborted(opts.signal, context);
        const tree = await this.treeFor(share);
        const file = new File(tree);
        try {
            await this.openForStat(file, filePath, opts.signal);
            const basic = await this.queryInfo(tree, file, FileInfoClass.BasicInformation, opts.signal);
            const standard = await this.queryInfo(tree, file, FileInfoClass.StandardInformation, opts.signal);
            const attributes = basic.readUInt32LE(32);
            return {
                sizeBytes: standard.readBigUInt64LE(8),
                mtime: structureUtil.parseDate(basic.subarray(16, 24)),
                atime: structureUtil.parseDate(basic.subarray(8, 16)),
                isDirectory: standard[21] !== 0 || (attributes & 0x10) !== 0,
                readonly: (attributes & 0x1) !== 0,
            };
        }
        catch (error) {
            throw toSmbError(error, context);
        }
        finally {
            await file.close();
        }
    }
    // Some servers require FILE_DIRECTORY_FILE to open a directory; opening a
    // file with that flag fails. Try plain first, retry flagged, keep the
    // first error when both fail. A CREATE never takes the signal: an abort
    // during it is seen once it has answered, so the handle it opened is
    // known and closes.
    async openForStat(file, filePath, signal) {
        try {
            await file.open(filePath, { desiredAccess: FilePipePrinterAccess.ReadAttributes });
        }
        catch (first) {
            throwIfAborted(signal, "stat");
            try {
                await file.open(filePath, {
                    desiredAccess: FilePipePrinterAccess.ReadAttributes,
                    createOptions: CreateOptions.Directory,
                });
            }
            catch {
                throw first;
            }
        }
    }
    async queryInfo(tree, file, infoClass, signal) {
        throwIfAborted(signal, "stat");
        const response = await tree.request({ type: PacketType.QueryInfo }, {
            infoType: InfoType.File,
            fileInfoClass: infoClass,
            fileId: file._id,
            buffer: Buffer.alloc(0),
        }, { signal });
        return response.body.buffer;
    }
    async readFile(share, filePath, opts = {}) {
        const context = `read ${share}/${filePath}`;
        throwIfAborted(opts.signal, context);
        const tree = await this.treeFor(share);
        const file = new File(tree);
        try {
            await file.open(filePath);
            if (file.fileSize > BigInt(MAX_BUFFERED_FILE_BYTES)) {
                throw new SmbFileTooLargeError(`file ${share}/${filePath} is ${file.fileSize} bytes, above the ${MAX_BUFFERED_FILE_BYTES} byte buffer cap; use download() to stream it`);
            }
            return await file.read({ signal: opts.signal });
        }
        catch (error) {
            throw toSmbError(error, context);
        }
        finally {
            await file.close();
        }
    }
    async readRange(share, filePath, offset, length, opts = {}) {
        const context = `read ${share}/${filePath} at ${offset}`;
        if (typeof offset === "bigint" ? offset < 0n : !Number.isInteger(offset) || offset < 0) {
            throw new RangeError(`readRange offset must be a non-negative integer, got ${String(offset)}`);
        }
        if (!Number.isInteger(length) || length < 0)
            throw new RangeError(`readRange length must be a non-negative integer, got ${String(length)}`);
        if (length > MAX_BUFFERED_FILE_BYTES) {
            throw new SmbFileTooLargeError(`range of ${length} bytes is above the ${MAX_BUFFERED_FILE_BYTES} byte buffer cap; read smaller ranges, or use download() to stream the file`);
        }
        throwIfAborted(opts.signal, context);
        const tree = await this.treeFor(share);
        const file = new File(tree);
        try {
            await file.open(filePath); // read-only, share read | write | delete
            return await file.readRange(typeof offset === "bigint" ? offset : BigInt(offset), length, { signal: opts.signal });
        }
        catch (error) {
            throw toSmbError(error, context);
        }
        finally {
            await file.close();
        }
    }
    async writeFile(share, filePath, data) {
        const buffer = Buffer.isBuffer(data) ? data : Buffer.from(data, "utf8");
        if (buffer.length > MAX_BUFFERED_FILE_BYTES) {
            throw new SmbFileTooLargeError(`data is ${buffer.length} bytes, above the ${MAX_BUFFERED_FILE_BYTES} byte buffer cap; use upload() to stream it`);
        }
        const tree = await this.treeFor(share);
        const file = new File(tree);
        try {
            await file.open(filePath, {
                desiredAccess: FilePipePrinterAccess.WriteData,
                createDisposition: CreateDispositionType.OverwriteIf,
            });
            await file.setSize(BigInt(buffer.length));
            if (buffer.length > 0)
                await file.write(buffer);
        }
        catch (error) {
            throw toSmbError(error, `write ${share}/${filePath}`);
        }
        finally {
            await file.close();
        }
    }
    async upload(localPath, share, remotePath) {
        // Open the local file before the OverwriteIf CREATE, so a missing or
        // unreadable source never truncates the remote file.
        const source = await open(localPath, "r");
        let reader;
        try {
            if (!(await source.stat()).isFile()) {
                throw Object.assign(new Error(`EISDIR: ${localPath} is not a regular file`), {
                    code: "EISDIR",
                    path: localPath,
                });
            }
            const tree = await this.treeFor(share);
            const file = new File(tree);
            try {
                await file.open(remotePath, {
                    desiredAccess: FilePipePrinterAccess.WriteData,
                    createDisposition: CreateDispositionType.OverwriteIf,
                });
                const writer = file.createWriteStream();
                reader = source.createReadStream();
                await pipeline(reader, writer);
                await file.setSize(BigInt(writer.bytesWritten));
            }
            catch (error) {
                throw toSmbError(error, `upload ${localPath} to ${share}/${remotePath}`);
            }
            finally {
                await file.close();
            }
        }
        finally {
            if (!reader)
                await source.close();
        }
    }
    // A download that fails or aborts leaves no partial file at localPath
    //: the write stream is closed by pipeline(), then the file is
    // removed (a missing one is fine), and the original error is thrown.
    // Only a file this call opened for writing is removed: a failure before
    // that (the remote CREATE, or a local open that fails) leaves an existing
    // file at localPath untouched.
    async download(share, remotePath, localPath, opts = {}) {
        const context = `download ${share}/${remotePath} to ${localPath}`;
        throwIfAborted(opts.signal, context);
        const tree = await this.treeFor(share);
        const file = new File(tree);
        let written = false;
        try {
            await file.open(remotePath);
            const writer = createWriteStream(localPath);
            writer.once("open", () => {
                written = true;
            });
            await pipeline(file.createReadStream({ signal: opts.signal }), writer);
        }
        catch (error) {
            if (written)
                await rm(localPath, { force: true }).catch(() => undefined);
            throw toSmbError(error, context);
        }
        finally {
            await file.close();
        }
    }
    async delete(share, filePath) {
        try {
            const tree = await this.treeFor(share);
            const info = await this.stat(share, filePath);
            if (info.isDirectory) {
                await tree.removeDirectory(filePath);
            }
            else {
                await tree.removeFile(filePath);
            }
        }
        catch (error) {
            throw toSmbError(error, `delete ${share}/${filePath}`);
        }
    }
    // rm: a directory is refused before any delete, so `rm` can never take a
    // tree away.
    async deleteFile(share, filePath) {
        try {
            const tree = await this.treeFor(share);
            const info = await this.stat(share, filePath);
            if (info.isDirectory) {
                throw new SmbIsADirectoryError(`is a directory: ${share}/${filePath}; use rmdir`);
            }
            await tree.removeFile(filePath);
        }
        catch (error) {
            throw toSmbError(error, `delete ${share}/${filePath}`);
        }
    }
    // rmdir: the server refuses a directory that still has entries with
    // STATUS_DIRECTORY_NOT_EMPTY (SmbDirectoryNotEmptyError); nothing here
    // recurses.
    async deleteDirectory(share, dirPath) {
        try {
            const tree = await this.treeFor(share);
            const info = await this.stat(share, dirPath);
            if (!info.isDirectory) {
                throw new SmbNotADirectoryError(`not a directory: ${share}/${dirPath}; use delete`);
            }
            await tree.removeDirectory(dirPath);
        }
        catch (error) {
            throw toSmbError(error, `rmdir ${share}/${dirPath}`);
        }
    }
    // mv within one share: SMB2 RenameInformation. An existing target is not
    // replaced (STATUS_OBJECT_NAME_COLLISION, SmbAlreadyExistsError).
    async rename(share, fromPath, toPath) {
        try {
            const tree = await this.treeFor(share);
            const info = await this.stat(share, fromPath);
            if (info.isDirectory) {
                await tree.renameDirectory(fromPath, util.toWindowsFilePath(toPath));
            }
            else {
                await tree.renameFile(fromPath, toPath);
            }
        }
        catch (error) {
            throw toSmbError(error, `rename ${share}/${fromPath} to ${share}/${toPath}`);
        }
    }
    async mkdir(share, dirPath) {
        try {
            const tree = await this.treeFor(share);
            await tree.createDirectory(dirPath);
        }
        catch (error) {
            throw toSmbError(error, `mkdir ${share}/${dirPath}`);
        }
    }
    async close() {
        this.trees.clear();
        try {
            await this.session.logoff();
        }
        finally {
            await this.client.close();
        }
    }
}
//# sourceMappingURL=smb-session.js.map