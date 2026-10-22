// Minimal SPNEGO framing (RFC 4178) plus a tiny DER reader/writer.
// Carries raw mechanism tokens (NTLM type1/2/3, Kerberos AP-REQ/AP-REP)
// inside NegTokenInit / NegTokenResp so consumers see one opaque blob.
export const OID_SPNEGO = '1.3.6.1.5.5.2';
export const OID_KRB5 = '1.2.840.113554.1.2.2';
export const OID_NTLMSSP = '1.3.6.1.4.1.311.2.2.10';
export const NegState = {
    acceptCompleted: 0,
    acceptIncomplete: 1,
    reject: 2,
    requestMic: 3,
};
// RFC 4178 ContextFlags we request: mutual + replay + sequence + conf + integ.
export const DEFAULT_REQ_FLAGS = Buffer.from([0x76]);
function encodeLength(len) {
    if (len < 0x80)
        return Buffer.from([len]);
    const bytes = [];
    let n = len;
    while (n > 0) {
        bytes.unshift(n & 0xff);
        n >>>= 8;
    }
    return Buffer.from([0x80 | bytes.length, ...bytes]);
}
function tlv(tag, content) {
    return Buffer.concat([Buffer.from([tag]), encodeLength(content.length), content]);
}
function seq(...parts) {
    return tlv(0x30, Buffer.concat(parts));
}
export function encodeOid(text) {
    const arcs = text.split('.').map(Number);
    const body = [arcs[0] * 40 + arcs[1]];
    for (const arc of arcs.slice(2)) {
        if (arc < 0x80) {
            body.push(arc);
        }
        else {
            const tmp = [];
            let n = arc;
            tmp.unshift(n & 0x7f);
            n >>>= 7;
            while (n > 0) {
                tmp.unshift(0x80 | (n & 0x7f));
                n >>>= 7;
            }
            body.push(...tmp);
        }
    }
    return tlv(0x06, Buffer.from(body));
}
function bitString(flags) {
    // 1 unused bit: only 7 ContextFlags are defined.
    return tlv(0x03, Buffer.concat([Buffer.from([0x01]), flags]));
}
// DER MechTypeList (SEQUENCE OF OID): the bytes a SPNEGO mechListMIC covers.
export function encodeMechTypeList(mechOids) {
    return seq(...mechOids.map(encodeOid));
}
export function frameNegTokenInit(mechOids, mechToken, reqFlags = DEFAULT_REQ_FLAGS) {
    const parts = [tlv(0xa0, encodeMechTypeList(mechOids))];
    if (reqFlags)
        parts.push(tlv(0xa1, bitString(reqFlags)));
    if (mechToken)
        parts.push(tlv(0xa2, tlv(0x04, mechToken)));
    return tlv(0x60, Buffer.concat([encodeOid(OID_SPNEGO), tlv(0xa0, seq(...parts))]));
}
export function frameNegTokenResp(f) {
    const parts = [];
    if (f.negState !== undefined)
        parts.push(tlv(0xa0, tlv(0x0a, Buffer.from([f.negState]))));
    if (f.supportedMech !== undefined)
        parts.push(tlv(0xa1, encodeOid(f.supportedMech)));
    if (f.responseToken !== undefined)
        parts.push(tlv(0xa2, tlv(0x04, f.responseToken)));
    if (f.mechListMIC !== undefined)
        parts.push(tlv(0xa3, tlv(0x04, f.mechListMIC)));
    return tlv(0xa1, seq(...parts));
}
function readTlv(buf, offset) {
    if (offset + 2 > buf.length)
        throw new Error('SPNEGO: truncated TLV header');
    const tag = buf[offset];
    let len = buf[offset + 1];
    let header = 2;
    if (len & 0x80) {
        const count = len & 0x7f;
        if (count === 0 || count > 4)
            throw new Error('SPNEGO: bad length encoding');
        if (offset + 2 + count > buf.length)
            throw new Error('SPNEGO: truncated length');
        len = 0;
        for (let i = 0; i < count; i++)
            len = len * 256 + buf[offset + 2 + i];
        header = 2 + count;
    }
    if (offset + header + len > buf.length)
        throw new Error('SPNEGO: truncated value');
    return { tag, content: buf.subarray(offset + header, offset + header + len), total: header + len };
}
function expectTag(t, tag, what) {
    if (t.tag !== tag)
        throw new Error(`SPNEGO: expected ${what}, got tag 0x${t.tag.toString(16)}`);
    return t.content;
}
function decodeOidContent(body) {
    if (body.length === 0)
        throw new Error('SPNEGO: empty OID');
    const arcs = [Math.floor(body[0] / 40), body[0] % 40];
    let n = 0;
    for (let i = 1; i < body.length; i++) {
        n = n * 128 + (body[i] & 0x7f);
        if (!(body[i] & 0x80)) {
            arcs.push(n);
            n = 0;
        }
    }
    if (body[body.length - 1] & 0x80)
        throw new Error('SPNEGO: truncated OID arc');
    return arcs.join('.');
}
function readOid(t) {
    return decodeOidContent(expectTag(t, 0x06, 'OID'));
}
function readOctet(t) {
    return expectTag(t, 0x04, 'OCTET STRING');
}
function eachChild(content) {
    const out = [];
    let off = 0;
    while (off < content.length) {
        const t = readTlv(content, off);
        out.push(t);
        off += t.total;
    }
    return out;
}
export function unframeSpnego(token) {
    if (token.length === 0)
        throw new Error('SPNEGO: empty token');
    if (token[0] !== 0x60 && token[0] !== 0xa1)
        return { kind: 'raw', token };
    const outer = readTlv(token, 0);
    if (outer.total !== token.length)
        throw new Error('SPNEGO: trailing bytes after token');
    if (outer.tag === 0x60) {
        const kids = eachChild(outer.content);
        if (kids.length !== 2)
            throw new Error('SPNEGO: InitToken must hold OID + inner token');
        readOid(kids[0]); // thisMech; must be present, value is not enforced
        const innerSeq = expectTag(readTlv(expectTag(kids[1], 0xa0, 'NegTokenInit'), 0), 0x30, 'Init SEQ');
        const out = { kind: 'init', mechTypes: [] };
        for (const f of eachChild(innerSeq)) {
            if (f.tag === 0xa0) {
                const mechs = expectTag(readTlv(f.content, 0), 0x30, 'MechTypeList');
                for (const m of eachChild(mechs))
                    out.mechTypes.push(readOid(m));
            }
            else if (f.tag === 0xa1) {
                const bs = expectTag(readTlv(f.content, 0), 0x03, 'BIT STRING');
                out.reqFlags = bs.subarray(1);
            }
            else if (f.tag === 0xa2) {
                out.mechToken = readOctet(readTlv(f.content, 0));
            }
        }
        if (out.mechTypes.length === 0)
            throw new Error('SPNEGO: NegTokenInit has no mechTypes');
        return out;
    }
    const respSeq = expectTag(readTlv(outer.content, 0), 0x30, 'Resp SEQ');
    const out = { kind: 'resp' };
    for (const f of eachChild(respSeq)) {
        if (f.tag === 0xa0)
            out.negState = expectTag(readTlv(f.content, 0), 0x0a, 'ENUMERATED')[0];
        else if (f.tag === 0xa1)
            out.supportedMech = readOid(readTlv(f.content, 0));
        else if (f.tag === 0xa2)
            out.responseToken = readOctet(readTlv(f.content, 0));
        else if (f.tag === 0xa3)
            out.mechListMIC = readOctet(readTlv(f.content, 0));
    }
    return out;
}
//# sourceMappingURL=spnego.js.map