// SMB 3.x security: key derivation, AES-CMAC and AES-GMAC signing,
// TRANSFORM_HEADER encryption with AES-128-GCM / AES-128-CCM, the SMB 3.1.1
// negotiate contexts and the pre-authentication integrity hash. Node crypto
// only. References: MS-SMB2 2.2.3.1, 2.2.41, 3.1.4.1-3.1.4.3, 3.2.5.3.1;
// SP800-108; RFC 4493 (CMAC); RFC 5084 (CCM/GCM).
import crypto from "node:crypto";
import { SmbError } from "./errors.js";
export const DIALECT_202 = 0x0202;
export const DIALECT_210 = 0x0210;
export const DIALECT_300 = 0x0300;
export const DIALECT_302 = 0x0302;
export const DIALECT_311 = 0x0311;
export const SMB2_GLOBAL_CAP_ENCRYPTION = 0x00000040;
export const SMB2_SESSION_FLAG_IS_GUEST = 0x0001;
export const SMB2_SESSION_FLAG_IS_NULL = 0x0002;
export const SMB2_SESSION_FLAG_ENCRYPT_DATA = 0x0004;
export const SMB2_SHAREFLAG_ENCRYPT_DATA = 0x00008000;
export const PREAUTH_INTEGRITY_CAPABILITIES = 0x0001;
export const ENCRYPTION_CAPABILITIES = 0x0002;
export const SIGNING_CAPABILITIES = 0x0008;
export const HASH_SHA512 = 0x0001;
export var Cipher;
(function (Cipher) {
    Cipher[Cipher["None"] = 0] = "None";
    Cipher[Cipher["Aes128Ccm"] = 1] = "Aes128Ccm";
    Cipher[Cipher["Aes128Gcm"] = 2] = "Aes128Gcm";
})(Cipher || (Cipher = {}));
export var SigningAlgorithm;
(function (SigningAlgorithm) {
    SigningAlgorithm[SigningAlgorithm["HmacSha256"] = -1] = "HmacSha256";
    SigningAlgorithm[SigningAlgorithm["AesCmac"] = 1] = "AesCmac";
    SigningAlgorithm[SigningAlgorithm["AesGmac"] = 2] = "AesGmac";
})(SigningAlgorithm || (SigningAlgorithm = {}));
export const cipherName = (cipher) => cipher === Cipher.Aes128Gcm ? "AES-128-GCM" : cipher === Cipher.Aes128Ccm ? "AES-128-CCM" : "none";
export const signingName = (alg) => alg === SigningAlgorithm.AesGmac ? "AES-GMAC" : alg === SigningAlgorithm.AesCmac ? "AES-CMAC" : "HMAC-SHA256";
const DIALECT_NAMES = {
    [DIALECT_202]: "2.0.2",
    [DIALECT_210]: "2.1",
    [DIALECT_300]: "3.0",
    [DIALECT_302]: "3.0.2",
    [DIALECT_311]: "3.1.1",
};
export const dialectName = (dialect) => DIALECT_NAMES[dialect] ?? `0x${dialect.toString(16).padStart(4, "0")}`;
const SIGNATURE_OFFSET = 48;
const SIGNATURE_SIZE = 16;
const SMB2_FLAGS_SERVER_TO_REDIR = 0x00000001;
const SMB2_FLAGS_SIGNED = 0x00000008;
const SMB2_CANCEL = 0x000c;
// ---- key derivation (SP800-108 counter mode, HMAC-SHA256, L = 128) ----
export function kdf(ki, label, context) {
    const be32 = (n) => {
        const b = Buffer.alloc(4);
        b.writeUInt32BE(n);
        return b;
    };
    return crypto
        .createHmac("sha256", ki)
        .update(be32(1))
        .update(Buffer.from(label, "latin1"))
        .update(Buffer.from([0]))
        .update(context)
        .update(be32(128))
        .digest()
        .subarray(0, 16);
}
// MS-SMB2 3.2.5.3.1. `preauthHash` is required for 3.1.1.
export function deriveKeys(dialect, sessionKey, preauthHash) {
    if (dialect === DIALECT_311) {
        if (!preauthHash)
            throw new SmbError("SMB 3.1.1 key derivation needs the pre-authentication hash");
        return {
            signingKey: kdf(sessionKey, "SMBSigningKey\0", preauthHash),
            encryptionKey: kdf(sessionKey, "SMBC2SCipherKey\0", preauthHash),
            decryptionKey: kdf(sessionKey, "SMBS2CCipherKey\0", preauthHash),
        };
    }
    return {
        signingKey: kdf(sessionKey, "SMB2AESCMAC\0", Buffer.from("SmbSign\0", "latin1")),
        encryptionKey: kdf(sessionKey, "SMB2AESCCM\0", Buffer.from("ServerIn \0", "latin1")),
        decryptionKey: kdf(sessionKey, "SMB2AESCCM\0", Buffer.from("ServerOut\0", "latin1")),
    };
}
// ---- pre-authentication integrity (3.1.1) ----
export const PREAUTH_INITIAL = Buffer.alloc(64);
export function preauthUpdate(hash, message) {
    return crypto.createHash("sha512").update(hash).update(message).digest();
}
// ---- AES-CMAC (RFC 4493) ----
function dbl(block) {
    const out = Buffer.alloc(16);
    let carry = 0;
    for (let i = 15; i >= 0; i--) {
        const b = block[i];
        out[i] = ((b << 1) | carry) & 0xff;
        carry = b >> 7;
    }
    if (block[0] & 0x80)
        out[15] = out[15] ^ 0x87;
    return out;
}
export function aesCmac(key, message) {
    const ecb = crypto.createCipheriv("aes-128-ecb", key, null);
    ecb.setAutoPadding(false);
    const l = ecb.update(Buffer.alloc(16));
    const k1 = dbl(l);
    const k2 = dbl(k1);
    const blocks = Math.max(1, Math.ceil(message.length / 16));
    const complete = message.length > 0 && message.length % 16 === 0;
    const last = Buffer.alloc(16);
    const tail = message.subarray((blocks - 1) * 16);
    tail.copy(last);
    if (!complete)
        last[tail.length] = 0x80;
    const subkey = complete ? k1 : k2;
    for (let i = 0; i < 16; i++)
        last[i] = last[i] ^ subkey[i];
    // CBC with a zero IV over M1..Mn-1 || M'n: the last ciphertext block is T.
    const cbc = crypto.createCipheriv("aes-128-cbc", key, Buffer.alloc(16));
    cbc.setAutoPadding(false);
    cbc.update(message.subarray(0, (blocks - 1) * 16));
    return cbc.update(last).subarray(-16);
}
// ---- SMB 3.x signing (MS-SMB2 3.1.4.1) ----
// AES-GMAC nonce: MessageId, then a 32-bit word whose bit 0 is the
// server-to-client flag and bit 1 marks a CANCEL request.
export function gmacNonce(message) {
    const nonce = Buffer.alloc(12);
    message.copy(nonce, 0, 24, 32);
    const flags = message.readUInt32LE(16);
    let high = flags & SMB2_FLAGS_SERVER_TO_REDIR;
    if (message.readUInt16LE(12) === SMB2_CANCEL)
        high |= 0x2;
    nonce.writeUInt32LE(high, 8);
    return nonce;
}
export function computeSignature3(message, alg, key) {
    const zeroed = Buffer.from(message);
    zeroed.fill(0, SIGNATURE_OFFSET, SIGNATURE_OFFSET + SIGNATURE_SIZE);
    if (alg === SigningAlgorithm.AesGmac) {
        const gcm = crypto.createCipheriv("aes-128-gcm", key, gmacNonce(zeroed));
        gcm.setAAD(zeroed);
        gcm.final();
        return gcm.getAuthTag();
    }
    if (alg === SigningAlgorithm.AesCmac)
        return aesCmac(key, zeroed);
    return crypto.createHmac("sha256", key).update(zeroed).digest().subarray(0, SIGNATURE_SIZE);
}
// Returns a signed copy with the Signed flag set.
export function signMessage3(message, alg, key) {
    const signed = Buffer.from(message);
    signed.writeUInt32LE(signed.readUInt32LE(16) | SMB2_FLAGS_SIGNED, 16);
    computeSignature3(signed, alg, key).copy(signed, SIGNATURE_OFFSET);
    return signed;
}
export function verifySignature3(message, alg, key) {
    if (message.length < 64)
        return false;
    const actual = message.subarray(SIGNATURE_OFFSET, SIGNATURE_OFFSET + SIGNATURE_SIZE);
    return crypto.timingSafeEqual(actual, computeSignature3(message, alg, key));
}
// ---- encryption (MS-SMB2 2.2.41, 3.1.4.3) ----
export const TRANSFORM_HEADER_SIZE = 52;
export const TRANSFORM_PROTOCOL_ID = Buffer.from([0xfd, 0x53, 0x4d, 0x42]);
export function isTransformed(frame) {
    return frame.length >= TRANSFORM_HEADER_SIZE && frame.subarray(0, 4).equals(TRANSFORM_PROTOCOL_ID);
}
export const nonceLength = (cipher) => (cipher === Cipher.Aes128Gcm ? 12 : 11);
// `sessionId` as the 8 wire bytes (the header's hex form decoded). `nonce`
// fills the 16-byte Nonce field from the left (the rest stays zero); the
// cipher uses its first 11 (CCM) or 12 (GCM) bytes, and the whole field is
// part of the AAD.
export function encryptMessage(message, sessionId, cipher, key, nonce) {
    if (nonce.length < nonceLength(cipher) || nonce.length > 16)
        throw new SmbError("bad SMB2 transform nonce length");
    const header = Buffer.alloc(TRANSFORM_HEADER_SIZE);
    TRANSFORM_PROTOCOL_ID.copy(header, 0);
    nonce.copy(header, 20);
    header.writeUInt32LE(message.length, 36);
    header.writeUInt16LE(0x0001, 42); // Flags (3.1.1) / EncryptionAlgorithm AES-128-CCM (3.0.x)
    sessionId.copy(header, 44, 0, 8);
    const aad = header.subarray(20);
    const iv = header.subarray(20, 20 + nonceLength(cipher));
    let ciphertext;
    let tag;
    if (cipher === Cipher.Aes128Gcm) {
        const c = crypto.createCipheriv("aes-128-gcm", key, iv);
        c.setAAD(aad);
        ciphertext = Buffer.concat([c.update(message), c.final()]);
        tag = c.getAuthTag();
    }
    else if (cipher === Cipher.Aes128Ccm) {
        const c = crypto.createCipheriv("aes-128-ccm", key, iv, { authTagLength: 16 });
        c.setAAD(aad, { plaintextLength: message.length });
        ciphertext = Buffer.concat([c.update(message), c.final()]);
        tag = c.getAuthTag();
    }
    else {
        throw new SmbError(`unsupported SMB cipher 0x${cipher.toString(16)}`);
    }
    tag.copy(header, 4);
    return Buffer.concat([header, ciphertext]);
}
export function transformSessionId(frame) {
    return frame.subarray(44, 52);
}
// Throws SmbError when the frame does not authenticate.
export function decryptMessage(frame, cipher, key) {
    if (!isTransformed(frame))
        throw new SmbError("not an SMB2 TRANSFORM_HEADER message");
    const size = frame.readUInt32LE(36);
    if (frame.readUInt16LE(42) !== 0x0001)
        throw new SmbError("unknown SMB2 transform flags");
    if (frame.length - TRANSFORM_HEADER_SIZE !== size)
        throw new SmbError("SMB2 transform size mismatch");
    const aad = frame.subarray(20, TRANSFORM_HEADER_SIZE);
    const iv = frame.subarray(20, 20 + nonceLength(cipher));
    const tag = frame.subarray(4, 20);
    const body = frame.subarray(TRANSFORM_HEADER_SIZE);
    try {
        if (cipher === Cipher.Aes128Gcm) {
            const d = crypto.createDecipheriv("aes-128-gcm", key, iv);
            d.setAuthTag(tag);
            d.setAAD(aad);
            return { sessionId: transformSessionId(frame), message: Buffer.concat([d.update(body), d.final()]) };
        }
        if (cipher === Cipher.Aes128Ccm) {
            const d = crypto.createDecipheriv("aes-128-ccm", key, iv, { authTagLength: 16 });
            d.setAuthTag(tag);
            d.setAAD(aad, { plaintextLength: body.length });
            return { sessionId: transformSessionId(frame), message: Buffer.concat([d.update(body), d.final()]) };
        }
    }
    catch {
        throw new SmbError("SMB2 encrypted message failed authentication");
    }
    throw new SmbError(`unsupported SMB cipher 0x${cipher.toString(16)}`);
}
// Unique nonces per key: a random prefix per connection and a counter.
export class NonceSource {
    counter = 0n;
    prefix = crypto.randomBytes(4);
    next(cipher) {
        const nonce = Buffer.alloc(nonceLength(cipher));
        this.prefix.copy(nonce, 0, 0, nonce.length - 8);
        nonce.writeBigUInt64LE(this.counter++, nonce.length - 8);
        return nonce;
    }
}
function context(type, data) {
    const head = Buffer.alloc(8);
    head.writeUInt16LE(type, 0);
    head.writeUInt16LE(data.length, 2);
    return Buffer.concat([head, data]);
}
const u16list = (values) => {
    const b = Buffer.alloc(2 + 2 * values.length);
    b.writeUInt16LE(values.length, 0);
    values.forEach((v, i) => b.writeUInt16LE(v, 2 + 2 * i));
    return b;
};
// Appends the contexts to a serialized NEGOTIATE request (header + body
// whose ClientStartTime field is zero) and fills NegotiateContextOffset and
// NegotiateContextCount in its place.
export function appendNegotiateContexts(message, offer) {
    const preauth = Buffer.alloc(6 + offer.salt.length);
    preauth.writeUInt16LE(1, 0); // HashAlgorithmCount
    preauth.writeUInt16LE(offer.salt.length, 2);
    preauth.writeUInt16LE(HASH_SHA512, 4);
    offer.salt.copy(preauth, 6);
    const contexts = [context(PREAUTH_INTEGRITY_CAPABILITIES, preauth)];
    if (offer.ciphers.length > 0)
        contexts.push(context(ENCRYPTION_CAPABILITIES, u16list(offer.ciphers)));
    if (offer.signing.length > 0)
        contexts.push(context(SIGNING_CAPABILITIES, u16list(offer.signing)));
    const parts = [message];
    let length = message.length;
    const pad = () => {
        const n = (8 - (length % 8)) % 8;
        if (n) {
            parts.push(Buffer.alloc(n));
            length += n;
        }
    };
    pad();
    const offset = length;
    contexts.forEach((c, i) => {
        if (i > 0)
            pad();
        parts.push(c);
        length += c.length;
    });
    const out = Buffer.concat(parts);
    out.writeUInt32LE(offset, 64 + 28);
    out.writeUInt16LE(contexts.length, 64 + 32);
    out.writeUInt16LE(0, 64 + 34);
    return out;
}
// Parses the contexts of a 3.1.1 NEGOTIATE response (the bare message).
export function parseNegotiateContexts(message) {
    const count = message.readUInt16LE(64 + 6);
    let offset = message.readUInt32LE(64 + 60);
    const result = { cipher: Cipher.None };
    for (let i = 0; i < count; i++) {
        offset += (8 - (offset % 8)) % 8;
        if (offset + 8 > message.length)
            throw new SmbError("truncated SMB 3.1.1 negotiate context list");
        const type = message.readUInt16LE(offset);
        const length = message.readUInt16LE(offset + 2);
        const data = message.subarray(offset + 8, offset + 8 + length);
        if (data.length !== length)
            throw new SmbError("truncated SMB 3.1.1 negotiate context");
        if (type === PREAUTH_INTEGRITY_CAPABILITIES && data.length >= 6) {
            if (data.readUInt16LE(0) !== 1)
                throw new SmbError("server picked more than one preauth hash algorithm");
            result.hashAlgorithm = data.readUInt16LE(4);
        }
        else if (type === ENCRYPTION_CAPABILITIES && data.length >= 4) {
            if (data.readUInt16LE(0) !== 1)
                throw new SmbError("server picked more than one cipher");
            result.cipher = data.readUInt16LE(2);
        }
        else if (type === SIGNING_CAPABILITIES && data.length >= 4) {
            if (data.readUInt16LE(0) !== 1)
                throw new SmbError("server picked more than one signing algorithm");
            result.signing = data.readUInt16LE(2);
        }
        offset += 8 + length;
    }
    return result;
}
//# sourceMappingURL=smb3.js.map