import File from "../client/File.js";
import PacketType from "../protocol/smb2/PacketType.js";
import CreateDispositionType from "../protocol/smb2/CreateDispositionType.js";
import FilePipePrinterAccess from "../protocol/smb2/FilePipePrinterAccess.js";
import { SmbError } from "../errors.js";
import { NdrReader, NdrWriter } from "./ndr.js";
import { MAX_XMIT_FRAG, PduType, ResponseReader, buildBind, buildRequest, parseBindAck, parseHeader, } from "./dcerpc.js";
const NETR_SHARE_ENUM = 15;
const NETR_SHARE_GET_INFO = 16;
const ERROR_MORE_DATA = 234;
const MAX_ENUM_ROUNDS = 100;
const SHARE_INFO_LEVEL_1005 = 1005;
// MS-SRVS 2.2.4.29 SHARE_INFO_1005.shi1005_flags: the share requires SMB
// encryption (`New-SmbShare -EncryptData $true`).
export const SHI1005_FLAGS_ENCRYPT_DATA = 0x00008000;
export function buildEnumRequest(resumeHandle) {
    const writer = new NdrWriter();
    writer.uint32(0); // ServerName: NULL
    writer.uint32(1); // Level
    writer.uint32(1); // union switch: Level1 arm
    writer.uint32(1); // Level1 referent: empty container follows, the server fills it
    writer.uint32(0); // Level1.EntriesRead
    writer.uint32(0); // Level1.Buffer: NULL
    writer.uint32(0xffffffff); // PreferedMaximumLength
    writer.uint32(0x20000); // ResumeHandle referent (top-level, pointee inline)
    writer.uint32(resumeHandle);
    return writer.buffer();
}
function shareTypeName(shareType) {
    switch (shareType & 0xff) {
        case 0: return "disk";
        case 1: return "printer";
        case 2: return "device";
        case 3: return "ipc";
        default: return `unknown(${shareType})`;
    }
}
export function parseEnumResponse(stub) {
    const reader = new NdrReader(stub);
    reader.uint32(); // InfoStruct.Level
    const tag = reader.uint32(); // union switch; selects the info level
    if (tag !== 1) {
        throw new SmbError(`unsupported NetrShareEnum info level ${tag}`);
    }
    const containerRef = reader.uint32();
    const shares = [];
    if (containerRef !== 0) {
        const count = reader.uint32(); // EntriesRead
        const arrayRef = reader.uint32();
        if (arrayRef !== 0 && count > 0) {
            reader.uint32(); // conformant max_count
            const entries = [];
            for (let index = 0; index < count; index++) {
                entries.push({ name: reader.uint32(), type: reader.uint32(), remark: reader.uint32() });
            }
            // String pointees follow the array in pointer-encounter order.
            // NULL pointers have no pointee; repeated referents share one.
            const strings = new Map();
            for (const entry of entries) {
                for (const ptr of [entry.name, entry.remark]) {
                    if (ptr !== 0 && !strings.has(ptr))
                        strings.set(ptr, reader.cvString());
                }
            }
            for (const entry of entries) {
                shares.push({
                    name: strings.get(entry.name) ?? "",
                    type: shareTypeName(entry.type),
                    comment: strings.get(entry.remark) ?? "",
                });
            }
        }
    }
    reader.uint32(); // TotalEntries
    const resumePtr = reader.uint32();
    let resume = 0;
    if (resumePtr !== 0)
        resume = reader.uint32(); // inline pointee
    const status = reader.uint32();
    return { shares, resume, status };
}
// NetrShareGetInfo(ServerName = NULL, NetName, Level = 1005). NetName is a
// top-level [ref] string pointer, so its pointee follows inline with no
// referent id.
export function buildGetInfoRequest(share) {
    const writer = new NdrWriter();
    writer.uint32(0); // ServerName: NULL
    writer.wstring(share); // NetName
    writer.uint32(SHARE_INFO_LEVEL_1005); // Level
    return writer.buffer();
}
// SHARE_INFO is a non-encapsulated union: the switch value (the level), then
// the arm, a unique pointer to SHARE_INFO_1005 { DWORD shi1005_flags }.
export function parseGetInfoResponse(stub) {
    const reader = new NdrReader(stub);
    const tag = reader.uint32();
    if (tag !== SHARE_INFO_LEVEL_1005) {
        throw new SmbError(`unsupported NetrShareGetInfo info level ${tag}`);
    }
    const ref = reader.uint32();
    const flags = ref !== 0 ? reader.uint32() : undefined;
    const status = reader.uint32();
    return { flags, status };
}
export class SrvsvcClient {
    session;
    callId = 1;
    constructor(session) {
        this.session = session;
    }
    async enumShares() {
        return await this.withPipe(async (tree, pipe) => {
            const shares = [];
            let resume = 0;
            for (let round = 0; round < MAX_ENUM_ROUNDS; round++) {
                await this.writePdu(tree, pipe, buildRequest(this.callId++, NETR_SHARE_ENUM, buildEnumRequest(resume)));
                const { shares: batch, resume: next, status } = parseEnumResponse(await this.readResponseStub(tree, pipe));
                shares.push(...batch);
                if (status === 0)
                    return shares;
                if (status !== ERROR_MORE_DATA) {
                    throw new SmbError(`NetShareEnum failed with status ${status}`);
                }
                resume = next;
            }
            throw new SmbError(`NetShareEnum did not converge after ${MAX_ENUM_ROUNDS} calls`);
        });
    }
    // The share's shi1005_flags (SHI1005_FLAGS_*). Throws SmbError when the
    // server returns a non-zero NET_API_STATUS or no SHARE_INFO_1005.
    async getShareFlags(share) {
        return await this.withPipe(async (tree, pipe) => {
            await this.writePdu(tree, pipe, buildRequest(this.callId++, NETR_SHARE_GET_INFO, buildGetInfoRequest(share)));
            const { flags, status } = parseGetInfoResponse(await this.readResponseStub(tree, pipe));
            if (status !== 0 || flags === undefined) {
                throw new SmbError(`NetShareGetInfo(${share}, 1005) failed with status ${status}`);
            }
            return flags;
        });
    }
    // Connects IPC$, opens and binds the srvsvc pipe, runs `fn`, then closes
    // the pipe and disconnects the tree whatever happens.
    async withPipe(fn) {
        const tree = await this.session.connectTree("IPC$");
        try {
            const pipe = new File(tree);
            await pipe.open("srvsvc", {
                desiredAccess: FilePipePrinterAccess.ReadData | FilePipePrinterAccess.WriteData,
                createDisposition: CreateDispositionType.Open,
            });
            try {
                await this.writePdu(tree, pipe, buildBind(this.callId++));
                parseBindAck(await this.readSinglePdu(tree, pipe, PduType.BindAck));
                return await fn(tree, pipe);
            }
            finally {
                await pipe.close();
            }
        }
        finally {
            await tree.disconnect();
        }
    }
    async writePdu(tree, pipe, pdu) {
        await tree.request({ type: PacketType.Write, creditCharge: 1 }, {
            fileId: pipe._id,
            buffer: pdu,
            offset: 0,
        });
    }
    // Reads pipe bytes until one full PDU of the expected type arrives.
    async readSinglePdu(tree, pipe, want) {
        let pending = Buffer.alloc(0);
        for (;;) {
            if (pending.length >= 16) {
                const header = parseHeader(pending);
                if (pending.length >= header.fragLength) {
                    const pdu = pending.subarray(0, header.fragLength);
                    if (header.ptype === PduType.Fault) {
                        const status = pdu.length >= 28 ? pdu.readUInt32LE(24) : 0;
                        throw new SmbError(`DCE/RPC fault 0x${status.toString(16).padStart(8, "0")}`);
                    }
                    if (header.ptype !== want) {
                        throw new SmbError(`expected DCE/RPC PDU type ${want}, got ${header.ptype}`);
                    }
                    return Buffer.from(pdu);
                }
            }
            pending = Buffer.concat([pending, await this.readChunk(tree, pipe)]);
        }
    }
    // Reads RESPONSE fragments until LAST_FRAG and returns the joined stub.
    async readResponseStub(tree, pipe) {
        const reader = new ResponseReader();
        for (;;) {
            const stub = reader.push(await this.readChunk(tree, pipe));
            if (stub)
                return stub;
        }
    }
    async readChunk(tree, pipe) {
        const response = await tree.request({ type: PacketType.Read, creditCharge: 1 }, {
            fileId: pipe._id,
            length: MAX_XMIT_FRAG,
            offset: 0,
        });
        const chunk = response.body.buffer;
        if (!chunk || chunk.length === 0) {
            throw new SmbError("srvsvc pipe closed mid-response");
        }
        return chunk;
    }
}
//# sourceMappingURL=srvsvc.js.map