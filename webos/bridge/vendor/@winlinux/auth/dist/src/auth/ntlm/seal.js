// NTLMSSP session security: SIGNKEY/SEALKEY (MS-NLMP 3.4.5) plus SEAL/MAC
// for NTLMv2 with extended session security, connection-oriented (3.4.3/3.4.4.2).
// Produces and verifies GSS_Wrap-style blobs: 16-byte signature + sealed data.
import { timingSafeEqual } from 'node:crypto';
import { RC4, hmacMd5, md5 } from './crypto.js';
const CLIENT_SIGN_MAGIC = 'session key to client-to-server signing key magic constant\0';
const SERVER_SIGN_MAGIC = 'session key to server-to-client signing key magic constant\0';
const CLIENT_SEAL_MAGIC = 'session key to client-to-server sealing key magic constant\0';
const SERVER_SEAL_MAGIC = 'session key to server-to-client sealing key magic constant\0';
const NEGOTIATE_128 = 0x20000000;
export function signKey(exportedSessionKey, mode) {
    const magic = mode === 'Client' ? CLIENT_SIGN_MAGIC : SERVER_SIGN_MAGIC;
    return md5(exportedSessionKey, Buffer.from(magic, 'ascii'));
}
// MS-NLMP 3.4.5.3 with NEGOTIATE_128. The 56- and 40-bit keys (the first
// 7 or 5 bytes of the session key) are not derived:
// negotiateResponseFlags refuses a CHALLENGE without NEGOTIATE_128.
export function sealKey(exportedSessionKey, negotiatedFlags, mode) {
    if (!(negotiatedFlags & NEGOTIATE_128))
        throw new Error('NTLM: sealing needs 128-bit keys (NEGOTIATE_128)');
    const magic = mode === 'Client' ? CLIENT_SEAL_MAGIC : SERVER_SEAL_MAGIC;
    return md5(exportedSessionKey, Buffer.from(magic, 'ascii'));
}
export class NtlmSealSession {
    clientSign;
    serverSign;
    clientSealKey;
    serverSealKey;
    clientRc4;
    serverRc4;
    keyExchange;
    clientSeq = 0;
    serverSeq = 0;
    constructor(opts) {
        this.clientSign = signKey(opts.exportedSessionKey, 'Client');
        this.serverSign = signKey(opts.exportedSessionKey, 'Server');
        this.clientSealKey = sealKey(opts.exportedSessionKey, opts.negotiatedFlags, 'Client');
        this.serverSealKey = sealKey(opts.exportedSessionKey, opts.negotiatedFlags, 'Server');
        this.clientRc4 = new RC4(this.clientSealKey);
        this.serverRc4 = new RC4(this.serverSealKey);
        this.keyExchange = opts.keyExchange;
    }
    // MS-SPNG 3.3.5.1: after the SPNEGO mechListMIC, the RC4 state of that
    // direction goes back to its initial state, so the mechListMIC and the
    // first application message use the same key stream. The sequence
    // number does NOT reset: the first message after the MIC takes seq 1.
    resetRc4(direction) {
        if (direction === 'client')
            this.clientRc4 = new RC4(this.clientSealKey);
        else
            this.serverRc4 = new RC4(this.serverSealKey);
    }
    // SEAL: returns signature (16) + sealed data. Client to server.
    seal(plaintext) {
        const seq = Buffer.alloc(4);
        seq.writeUInt32LE(this.clientSeq, 0);
        const sealed = this.clientRc4.update(plaintext);
        let checksum = hmacMd5(this.clientSign, seq, plaintext).subarray(0, 8);
        if (this.keyExchange)
            checksum = this.clientRc4.update(checksum);
        this.clientSeq += 1;
        const sig = Buffer.concat([Buffer.from([0x01, 0x00, 0x00, 0x00]), checksum, seq]);
        return Buffer.concat([sig, sealed]);
    }
    // MAC only (MS-NLMP 3.4.4.2): 16-byte signature over `message`. Client to server.
    sign(message) {
        const seq = Buffer.alloc(4);
        seq.writeUInt32LE(this.clientSeq, 0);
        let checksum = hmacMd5(this.clientSign, seq, message).subarray(0, 8);
        if (this.keyExchange)
            checksum = this.clientRc4.update(checksum);
        this.clientSeq += 1;
        return Buffer.concat([Buffer.from([0x01, 0x00, 0x00, 0x00]), checksum, seq]);
    }
    // MAC check (MS-NLMP 3.4.4.2) of a 16-byte server-to-client signature
    // over `message`, for example the server's SPNEGO mechListMIC.
    verify(message, signature) {
        if (signature.length !== 16 || signature.readUInt32LE(0) !== 1)
            return false;
        if (signature.readUInt32LE(12) !== this.serverSeq)
            return false;
        const seq = Buffer.alloc(4);
        seq.writeUInt32LE(this.serverSeq, 0);
        let expected = hmacMd5(this.serverSign, seq, message).subarray(0, 8);
        if (this.keyExchange)
            expected = this.serverRc4.update(expected);
        this.serverSeq += 1;
        return timingSafeEqual(expected, signature.subarray(4, 12));
    }
    // UNSEAL: verifies the signature, then returns the plaintext. Server to client.
    unseal(packet) {
        if (packet.length < 16)
            throw new Error('NTLM unseal: packet shorter than signature');
        const sig = packet.subarray(0, 16);
        if (sig.readUInt32LE(0) !== 1)
            throw new Error('NTLM unseal: bad signature version');
        const wireSeq = sig.readUInt32LE(12);
        if (wireSeq !== this.serverSeq) {
            throw new Error(`NTLM unseal: expected seq ${this.serverSeq}, got ${wireSeq}`);
        }
        const seq = Buffer.alloc(4);
        seq.writeUInt32LE(this.serverSeq, 0);
        const sealed = packet.subarray(16);
        const plaintext = this.serverRc4.update(sealed);
        let wireChecksum = sig.subarray(4, 12);
        if (this.keyExchange)
            wireChecksum = this.serverRc4.update(Buffer.from(wireChecksum));
        const expected = hmacMd5(this.serverSign, seq, plaintext).subarray(0, 8);
        if (!wireChecksum.equals(expected))
            throw new Error('NTLM unseal: checksum mismatch');
        this.serverSeq += 1;
        return plaintext;
    }
}
//# sourceMappingURL=seal.js.map