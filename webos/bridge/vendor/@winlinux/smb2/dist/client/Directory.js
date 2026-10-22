import { EventEmitter } from "events";
import * as util from "../protocol/util.js";
import StatusCode from "../protocol/smb2/StatusCode.js";
import PacketType from "../protocol/smb2/PacketType.js";
import FileAttribute from "../protocol/smb2/FileAttribute.js";
import ShareAccessType from "../protocol/smb2/ShareAccessType.js";
import DirectoryAccess from "../protocol/smb2/DirectoryAccess.js";
import { CreateOptions } from "../protocol/smb2/packets/Create.js";
import * as structureUtil from "../protocol/structureUtil.js";
import { InfoType, FileInfoClass } from "../protocol/smb2/packets/SetInfo.js";
import CreateDispositionType from "../protocol/smb2/CreateDispositionType.js";
import { Flags as ChangeNotifyFlags } from "../protocol/smb2/packets/ChangeNotify.js";
import { throwIfAborted } from "../errors.js";
class Directory extends EventEmitter {
    tree;
    _id;
    isOpen = false;
    watching = false;
    watchingMessageIds = [];
    watchRecursive;
    constructor(tree) {
        super();
        this.tree = tree;
    }
    async open(path, options = {}) {
        if (this.isOpen)
            return;
        const buffer = Buffer.from(util.toWindowsFilePath(path), "ucs2");
        const response = await this.tree.request({ type: PacketType.Create }, {
            buffer,
            desiredAccess: typeof options.desiredAccess === "number" ?
                options.desiredAccess :
                (DirectoryAccess.ListDirectory |
                    DirectoryAccess.ReadAttributes |
                    DirectoryAccess.Synchronize),
            fileAttributes: FileAttribute.Directory,
            shareAccess: ShareAccessType.Read |
                ShareAccessType.Write |
                ShareAccessType.Delete,
            createDisposition: typeof options.createDisposition === "number" ?
                options.createDisposition :
                CreateDispositionType.Open,
            createOptions: typeof options.createOptions === "number" ?
                options.createOptions :
                CreateOptions.Directory, // every Directory.open targets a directory
            nameOffset: 0x0078,
            createContextsOffset: 0x007a + buffer.length
        });
        this._id = response.body.fileId;
        this.isOpen = true;
        this.emit("open", this);
    }
    async create(path) {
        await this.open(path, {
            createDisposition: CreateDispositionType.Create,
            createOptions: CreateOptions.Directory
        });
    }
    async watch(recursive = true) {
        if (this.watching)
            return;
        this.watching = true;
        this.watchRecursive = recursive;
        await this.requestWatch();
        this.tree.session.client.addListener("changeNotify", this.onChangeNotify);
    }
    async unwatch() {
        if (!this.watching)
            return;
        this.watching = false;
        this.tree.session.client.removeListener("changeNotify", this.onChangeNotify);
        await this.close();
    }
    onChangeNotify = async (response) => {
        const messageId = response.header.messageId;
        const messageIdIndex = this.watchingMessageIds.indexOf(messageId);
        if (messageIdIndex !== -1) {
            this.watchingMessageIds.splice(messageIdIndex, 1);
            this.emit("change", response);
            await this.requestWatch();
        }
    };
    async requestWatch() {
        const request = this.tree.createRequest({ type: PacketType.ChangeNotify }, {
            flags: this.watchRecursive ?
                ChangeNotifyFlags.WatchTreeRecursively :
                ChangeNotifyFlags.None,
            fileId: this._id
        });
        this.watchingMessageIds.push(request.header.messageId);
        const response = await this.tree.session.client.send(request);
        if (response.header.status !== StatusCode.Success &&
            response.header.status !== StatusCode.Pending)
            throw new Error(`ChangeNotify: ${structureUtil.parseEnumValue(StatusCode, response.header.status)} (${response.header.status})`);
        return response;
    }
    async flush() {
        await this.tree.request({
            type: PacketType.Flush
        }, {
            fileId: this._id
        });
    }
    // Reads the whole directory: each QUERY_DIRECTORY call continues the
    // enumeration on the open handle until the server answers NO_MORE_FILES.
    async read(options = {}) {
        const entries = [];
        for await (const page of this.pages(options))
            entries.push(...page);
        return entries;
    }
    // One array per QUERY_DIRECTORY response, in server order, without "."
    // and "..", so a caller can stop after any page. On abort no
    // further request goes out and the iterator rejects with SmbAbortError;
    // closing the handle is the caller's job (Tree.readDirectoryPages).
    async *pages(options = {}) {
        const { signal } = options;
        for (;;) {
            throwIfAborted(signal, `QUERY_DIRECTORY of ${this._id}`);
            let response;
            try {
                response = await this.tree.request({ type: PacketType.QueryDirectory }, {
                    fileId: this._id,
                    buffer: Buffer.from("*", "ucs2")
                }, { signal });
            }
            catch (error) {
                if (error?.header?.status === StatusCode.NoMoreFiles)
                    return;
                throw error;
            }
            if (!response.data)
                return;
            yield response.data.filter(x => x.filename !== "." && x.filename !== "..");
        }
    }
    async exists(path) {
        try {
            await this.open(path);
        }
        catch (err) {
            if (err.header.status === StatusCode.FileNameNotFound ||
                err.header.status === StatusCode.FilePathNotFound) {
                return false;
            }
            throw err;
        }
        return true;
    }
    async remove() {
        const buffer = Buffer.alloc(1);
        buffer.writeUInt8(1, 0);
        await this.setInfo(FileInfoClass.DispositionInformation, buffer);
    }
    async rename(newPath) {
        const newPathUCS2 = Buffer.from(newPath, "ucs2");
        const buffer = Buffer.alloc(1 + 7 + 8 + 4 + newPathUCS2.length);
        buffer.fill(0x00);
        buffer.writeUInt8(0, 0); // ReplaceIfExists = 0, like File.rename
        buffer.writeUInt32LE(newPathUCS2.length, 16);
        buffer.fill(newPathUCS2, 20);
        await this.setInfo(FileInfoClass.RenameInformation, buffer);
    }
    async setInfo(fileInfoClass, buffer) {
        await this.tree.request({ type: PacketType.SetInfo }, {
            infoType: InfoType.File,
            fileId: this._id,
            fileInfoClass,
            buffer
        });
    }
    async close() {
        if (this.watching)
            return await this.unwatch();
        if (!this.isOpen)
            return;
        this.isOpen = false;
        // A dropped connection took the handle with it; a CLOSE would only
        // replace the error that dropped it with "not_connected".
        if (this.tree.session.client.connected) {
            await this.tree.request({ type: PacketType.Close }, { fileId: this._id });
        }
        this.emit("close", this);
    }
}
export default Directory;
//# sourceMappingURL=Directory.js.map