// A small DER encoder and decoder for CredSSP (MS-CSSP 2.2.1): the
// TSRequest family uses SEQUENCE, context tags [0]..[5], INTEGER and
// OCTET STRING only. A certificate's SubjectPublicKeyInfo needs BIT STRING.
// @winlinux/auth does not import @winlinux/winrm, so this is its own copy.
export const TAG_INTEGER = 0x02;
export const TAG_BIT_STRING = 0x03;
export const TAG_OCTET_STRING = 0x04;
export const TAG_SEQUENCE = 0x30;
// Context-specific, constructed: [n] -> 0xa0 + n.
export function contextTag(n) {
    return 0xa0 + n;
}
export function encodeLength(len) {
    if (len < 0x80)
        return Buffer.from([len]);
    const bytes = [];
    let n = len;
    while (n > 0) {
        bytes.unshift(n & 0xff);
        n = Math.floor(n / 256);
    }
    return Buffer.from([0x80 | bytes.length, ...bytes]);
}
export function tlv(tag, content) {
    return Buffer.concat([Buffer.from([tag]), encodeLength(content.length), content]);
}
export function sequence(...parts) {
    return tlv(TAG_SEQUENCE, Buffer.concat(parts));
}
export function octetString(value) {
    return tlv(TAG_OCTET_STRING, value);
}
export function explicit(n, inner) {
    return tlv(contextTag(n), inner);
}
// DER INTEGER, two's complement, minimal length. Range: signed 32-bit, plus
// the unsigned 32-bit values an NTSTATUS or HRESULT error code takes.
export function integer(value) {
    if (!Number.isInteger(value) || value < -0x80000000 || value > 0xffffffff) {
        throw new Error(`DER: integer out of range: ${value}`);
    }
    const bytes = [];
    let n = BigInt(value);
    for (;;) {
        bytes.unshift(Number(n & 0xffn));
        n >>= 8n;
        const top = bytes[0];
        if ((n === 0n && (top & 0x80) === 0) || (n === -1n && (top & 0x80) !== 0))
            break;
    }
    return tlv(TAG_INTEGER, Buffer.from(bytes));
}
export function readTlv(buf, offset) {
    if (offset + 2 > buf.length)
        throw new Error('DER: truncated header');
    const tag = buf[offset];
    if ((tag & 0x1f) === 0x1f)
        throw new Error('DER: multi-byte tags are not supported');
    let len = buf[offset + 1];
    let header = 2;
    if (len & 0x80) {
        const count = len & 0x7f;
        if (count === 0)
            throw new Error('DER: indefinite length is not allowed');
        if (count > 4)
            throw new Error('DER: length is too long');
        if (offset + 2 + count > buf.length)
            throw new Error('DER: truncated length');
        len = 0;
        for (let i = 0; i < count; i++)
            len = len * 256 + buf[offset + 2 + i];
        if (len < 0x80 || (count > 1 && buf[offset + 2] === 0))
            throw new Error('DER: length is not minimal');
        header = 2 + count;
    }
    if (offset + header + len > buf.length)
        throw new Error('DER: truncated value');
    return { tag, content: buf.subarray(offset + header, offset + header + len), total: header + len };
}
// Exactly one TLV that fills `buf`.
export function readOne(buf, what) {
    const t = readTlv(buf, 0);
    if (t.total !== buf.length)
        throw new Error(`DER: trailing bytes after ${what}`);
    return t;
}
// The total length of the TLV at the start of `buf`, or null while `buf`
// holds less than one whole TLV.
export function tlvLength(buf) {
    try {
        return readTlv(buf, 0).total;
    }
    catch (err) {
        if (/truncated/.test(err.message))
            return null;
        throw err;
    }
}
export function children(content) {
    const out = [];
    let off = 0;
    while (off < content.length) {
        const t = readTlv(content, off);
        out.push(t);
        off += t.total;
    }
    return out;
}
export function expectTag(t, tag, what) {
    if (t.tag !== tag)
        throw new Error(`DER: expected ${what}, got tag 0x${t.tag.toString(16)}`);
    return t.content;
}
// The single element inside an explicit context tag.
export function unwrapExplicit(t, what) {
    return readOne(t.content, what);
}
export function readInteger(t, what) {
    const c = expectTag(t, TAG_INTEGER, `${what} INTEGER`);
    if (c.length === 0)
        throw new Error(`DER: empty INTEGER for ${what}`);
    if (c.length > 5)
        throw new Error(`DER: INTEGER for ${what} is too large`);
    if (c.length > 1 && ((c[0] === 0x00 && (c[1] & 0x80) === 0) || (c[0] === 0xff && (c[1] & 0x80) !== 0))) {
        throw new Error(`DER: INTEGER for ${what} is not minimal`);
    }
    let n = BigInt.asIntN(8, BigInt(c[0]));
    for (let i = 1; i < c.length; i++)
        n = n * 256n + BigInt(c[i]);
    return Number(n);
}
export function readOctetString(t, what) {
    return expectTag(t, TAG_OCTET_STRING, `${what} OCTET STRING`);
}
// SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier,
// subjectPublicKey BIT STRING } (RFC 5280 4.1). Returns the BIT STRING
// value without its unused-bits octet: the bytes MS-CSSP 3.1.5 hashes.
export function subjectPublicKey(spkiDer) {
    return subjectPublicKeyOf(expectTag(readOne(spkiDer, 'SubjectPublicKeyInfo'), TAG_SEQUENCE, 'SubjectPublicKeyInfo'));
}
// The SubjectPublicKey of a DER X.509 certificate, read from the
// certificate's own SubjectPublicKeyInfo (RFC 5280 4.1):
//   Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
//   TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber,
//     signature, issuer, validity, subject, subjectPublicKeyInfo, ... }
// No re-encoding through a key object: the server hashes the bytes in
// its certificate (MS-CSSP 3.1.5), so the client takes the same bytes.
export function certificateSubjectPublicKey(certDer) {
    const cert = children(expectTag(readOne(certDer, 'Certificate'), TAG_SEQUENCE, 'Certificate'));
    if (cert.length !== 3)
        throw new Error('DER: Certificate must hold three elements');
    const tbs = children(expectTag(cert[0], TAG_SEQUENCE, 'TBSCertificate'));
    const spki = tbs[tbs[0]?.tag === contextTag(0) ? 6 : 5];
    if (!spki)
        throw new Error('DER: TBSCertificate has no SubjectPublicKeyInfo');
    return subjectPublicKeyOf(expectTag(spki, TAG_SEQUENCE, 'SubjectPublicKeyInfo'));
}
function subjectPublicKeyOf(spki) {
    const kids = children(spki);
    if (kids.length !== 2)
        throw new Error('DER: SubjectPublicKeyInfo must hold two elements');
    expectTag(kids[0], TAG_SEQUENCE, 'AlgorithmIdentifier');
    const bits = expectTag(kids[1], TAG_BIT_STRING, 'subjectPublicKey BIT STRING');
    if (bits.length < 2 || bits[0] !== 0)
        throw new Error('DER: subjectPublicKey must be a whole number of octets');
    return Buffer.from(bits.subarray(1));
}
//# sourceMappingURL=der.js.map