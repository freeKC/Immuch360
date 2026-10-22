// Minimal DCE/RPC connection-oriented PDU layer (MS-RPCE), just enough to
// bind the SRVSVC pipe and call NetrShareEnum. No auth, no fragmentation
// on send; received fragments get reassembled by the caller.
import { SmbError } from "../errors.js";
export var PduType;
(function (PduType) {
    PduType[PduType["Request"] = 0] = "Request";
    PduType[PduType["Response"] = 2] = "Response";
    PduType[PduType["Fault"] = 3] = "Fault";
    PduType[PduType["Bind"] = 11] = "Bind";
    PduType[PduType["BindAck"] = 12] = "BindAck";
})(PduType || (PduType = {}));
export const PFC_FIRST_FRAG = 0x01;
export const PFC_LAST_FRAG = 0x02;
export const SRVSVC_UUID = "4b324fc8-1670-01d3-1278-5a47bf6ee188";
export const SRVSVC_VERSION_MAJOR = 3;
export const SRVSVC_VERSION_MINOR = 0;
export const NDR_SYNTAX_UUID = "8a885d04-1ceb-11c9-9fe8-08002b104860";
export const NDR_SYNTAX_VERSION_MAJOR = 2;
export const NDR_SYNTAX_VERSION_MINOR = 0;
export const MAX_XMIT_FRAG = 4280;
// UUID text to the 16-byte mixed-endian wire form (MS-RPCE 2.3.1.3).
export function uuidToBytes(uuid) {
    const raw = Buffer.from(uuid.replace(/-/g, ""), "hex");
    if (raw.length !== 16)
        throw new SmbError(`bad UUID: ${uuid}`);
    const out = Buffer.alloc(16);
    out.writeUInt32LE(raw.readUInt32BE(0), 0);
    out.writeUInt16LE(raw.readUInt16BE(4), 4);
    out.writeUInt16LE(raw.readUInt16BE(6), 6);
    raw.copy(out, 8, 8, 16);
    return out;
}
// A RESPONSE or FAULT PDU: the 16-byte common header, then alloc hint,
// context id and cancel count (C706 12.6.4.10).
const RESPONSE_HEADER_SIZE = 24;
// The most stub bytes one response may carry, over all its fragments.
export const MAX_RESPONSE_STUB = 16 * 1024 * 1024;
export function parseHeader(pdu) {
    if (pdu.length < 16)
        throw new SmbError("short DCE/RPC header");
    if (pdu[0] !== 5)
        throw new SmbError(`unsupported DCE/RPC version ${pdu[0]}`);
    const header = {
        ptype: pdu[2],
        flags: pdu[3],
        fragLength: pdu.readUInt16LE(8),
        authLength: pdu.readUInt16LE(10),
        callId: pdu.readUInt32LE(12),
    };
    // A fragment shorter than its own header would never move a reader on.
    if (header.fragLength < 16)
        throw new SmbError(`DCE/RPC fragment length ${header.fragLength} is shorter than the header`);
    return header;
}
// A RESPONSE or FAULT must hold its header and its auth trailer.
function checkResponseLength(header) {
    if (header.fragLength < RESPONSE_HEADER_SIZE + header.authLength) {
        throw new SmbError(`DCE/RPC fragment length ${header.fragLength} cannot hold a response header and a ${header.authLength}-byte auth trailer`);
    }
}
function commonHeader(ptype, flags, fragLength, callId) {
    const header = Buffer.alloc(16);
    header[0] = 5;
    header[1] = 0;
    header[2] = ptype;
    header[3] = flags;
    header.writeUInt32LE(0x10, 4); // data representation: little-endian, ASCII
    header.writeUInt16LE(fragLength, 8);
    header.writeUInt16LE(0, 10); // no auth trailer
    header.writeUInt32LE(callId, 12);
    return header;
}
// One-context bind for iface_uuid/if_version over the NDR transfer syntax.
export function buildBind(callId, ifaceUuid = SRVSVC_UUID, ifaceMajor = SRVSVC_VERSION_MAJOR, ifaceMinor = SRVSVC_VERSION_MINOR) {
    const body = Buffer.alloc(56);
    let offset = 0;
    body.writeUInt16LE(MAX_XMIT_FRAG, offset);
    offset += 2;
    body.writeUInt16LE(MAX_XMIT_FRAG, offset);
    offset += 2;
    body.writeUInt32LE(0, offset);
    offset += 4; // assoc group
    body[offset++] = 1; // one context item
    offset += 3; // pad
    body.writeUInt16LE(0, offset);
    offset += 2; // context id
    body[offset++] = 1; // one transfer syntax
    body[offset++] = 0; // reserved
    uuidToBytes(ifaceUuid).copy(body, offset);
    offset += 16;
    body.writeUInt16LE(ifaceMajor, offset);
    offset += 2;
    body.writeUInt16LE(ifaceMinor, offset);
    offset += 2;
    uuidToBytes(NDR_SYNTAX_UUID).copy(body, offset);
    offset += 16;
    body.writeUInt16LE(NDR_SYNTAX_VERSION_MAJOR, offset);
    offset += 2;
    body.writeUInt16LE(NDR_SYNTAX_VERSION_MINOR, offset);
    offset += 2;
    return Buffer.concat([
        commonHeader(PduType.Bind, PFC_FIRST_FRAG | PFC_LAST_FRAG, 16 + body.length, callId),
        body,
    ]);
}
export function parseBindAck(pdu) {
    const header = parseHeader(pdu);
    if (header.ptype !== PduType.BindAck) {
        throw new SmbError(`expected BIND_ACK, got DCE/RPC PDU type ${header.ptype}`);
    }
    let offset = 16 + 2 + 2 + 4; // max_xmit, max_recv, assoc group
    const secondaryLength = pdu.readUInt16LE(offset);
    offset += 2 + secondaryLength;
    offset += (4 - (offset % 4)) % 4;
    const resultCount = pdu[offset];
    offset += 1 + 3;
    if (resultCount < 1)
        throw new SmbError("BIND_ACK carries no context results");
    const ackResult = pdu.readUInt16LE(offset);
    if (ackResult !== 0) {
        throw new SmbError(`DCE/RPC bind rejected (result ${ackResult})`);
    }
}
export function buildRequest(callId, opnum, stub) {
    const body = Buffer.alloc(8);
    body.writeUInt32LE(stub.length, 0); // alloc hint
    body.writeUInt16LE(0, 4); // context id
    body.writeUInt16LE(opnum, 6);
    return Buffer.concat([
        commonHeader(PduType.Request, PFC_FIRST_FRAG | PFC_LAST_FRAG, 16 + body.length + stub.length, callId),
        body,
        stub,
    ]);
}
// Parses one RESPONSE fragment (faults throw). The caller concatenates stubs
// until lastFrag is true.
export function parseResponsePdu(pdu) {
    const header = parseHeader(pdu);
    if (header.ptype === PduType.Fault) {
        const status = pdu.length >= 28 ? pdu.readUInt32LE(24) : 0;
        throw new SmbError(`DCE/RPC fault 0x${status.toString(16).padStart(8, "0")}`);
    }
    if (header.ptype !== PduType.Response) {
        throw new SmbError(`expected RESPONSE, got DCE/RPC PDU type ${header.ptype}`);
    }
    checkResponseLength(header);
    const stubEnd = header.fragLength - header.authLength;
    return {
        stub: Buffer.from(pdu.subarray(RESPONSE_HEADER_SIZE, stubEnd)),
        lastFrag: (header.flags & PFC_LAST_FRAG) !== 0,
    };
}
// Joins the RESPONSE fragments read from a pipe into one stub. Every
// length comes from the server and is checked.
export class ResponseReader {
    pending = Buffer.alloc(0);
    stubs = [];
    total = 0;
    // Takes the next pipe bytes; returns the joined stub once the LAST_FRAG
    // fragment is in, undefined while more is needed.
    push(chunk) {
        this.pending = Buffer.concat([this.pending, chunk]);
        while (this.pending.length >= 16) {
            const header = parseHeader(this.pending);
            checkResponseLength(header);
            if (this.pending.length < header.fragLength)
                break;
            const pdu = this.pending.subarray(0, header.fragLength);
            this.pending = this.pending.subarray(header.fragLength);
            if (header.ptype === PduType.Fault) {
                const status = pdu.length >= 28 ? pdu.readUInt32LE(24) : 0;
                throw new SmbError(`DCE/RPC fault 0x${status.toString(16).padStart(8, "0")}`);
            }
            if (header.ptype !== PduType.Response) {
                throw new SmbError(`expected RESPONSE, got DCE/RPC PDU type ${header.ptype}`);
            }
            const stub = pdu.subarray(RESPONSE_HEADER_SIZE, header.fragLength - header.authLength);
            this.total += stub.length;
            if (this.total > MAX_RESPONSE_STUB)
                throw new SmbError(`SRVSVC response stub is over the ${MAX_RESPONSE_STUB}-byte limit`);
            this.stubs.push(stub);
            if ((header.flags & PFC_LAST_FRAG) !== 0)
                return Buffer.concat(this.stubs);
        }
        return undefined;
    }
}
//# sourceMappingURL=dcerpc.js.map