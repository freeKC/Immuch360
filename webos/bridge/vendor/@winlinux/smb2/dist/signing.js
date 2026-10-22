// SMB2 signing (MS-SMB2 3.2.4.1.1): for the SMB 2.0.2/2.1 dialects the
// 16-byte Signature header field holds the first 16 bytes of
// HMAC-SHA256(sessionKey, message), computed over the SMB2 message with the
// Signature field zeroed. The 4-byte NetBIOS session-service header is NOT
// part of the signed bytes, so callers pass the bare SMB2 message.
import crypto from "node:crypto";
export const SMB2_HEADER_SIZE = 64;
export const SMB2_SIGNATURE_OFFSET = 48;
export const SMB2_SIGNATURE_SIZE = 16;
// MS-SMB2 3.2.5.3.1: Session.SessionKey is the first 16 bytes of the
// cryptographic key from the GSS layer, right-padded with zeros when it is
// shorter. NTLM keys are 16 bytes already; a Kerberos aes256 key is 32.
export const SMB2_SESSION_KEY_SIZE = 16;
export function smbSessionKey(gssKey) {
    const key = Buffer.alloc(SMB2_SESSION_KEY_SIZE);
    gssKey.copy(key, 0, 0, Math.min(SMB2_SESSION_KEY_SIZE, gssKey.length));
    return key;
}
export function computeSignature(message, sessionKey) {
    const zeroed = Buffer.from(message);
    zeroed.fill(0, SMB2_SIGNATURE_OFFSET, SMB2_SIGNATURE_OFFSET + SMB2_SIGNATURE_SIZE);
    return crypto.createHmac("sha256", sessionKey).update(zeroed).digest().subarray(0, SMB2_SIGNATURE_SIZE);
}
// Returns a signed copy; the input buffer is left untouched.
export function signMessage(message, sessionKey) {
    const signed = Buffer.from(message);
    computeSignature(signed, sessionKey).copy(signed, SMB2_SIGNATURE_OFFSET);
    return signed;
}
export function verifySignature(message, sessionKey) {
    if (message.length < SMB2_HEADER_SIZE)
        return false;
    const actual = message.subarray(SMB2_SIGNATURE_OFFSET, SMB2_SIGNATURE_OFFSET + SMB2_SIGNATURE_SIZE);
    return crypto.timingSafeEqual(actual, computeSignature(message, sessionKey));
}
//# sourceMappingURL=signing.js.map