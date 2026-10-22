// MS-CSSP 2.2.1 messages: TSRequest, TSCredentials and TSPasswordCreds,
// plus the version 5+ pubKeyAuth hash (MS-CSSP 3.1.5, the CVE-2018-0886
// fix). Pure functions: no network, no TLS, no secrets in errors.
//
// TSRequest ::= SEQUENCE {
//   version     [0] INTEGER,
//   negoTokens  [1] NegoData OPTIONAL,
//   authInfo    [2] OCTET STRING OPTIONAL,
//   pubKeyAuth  [3] OCTET STRING OPTIONAL,
//   errorCode   [4] INTEGER OPTIONAL,
//   clientNonce [5] OCTET STRING OPTIONAL }
// NegoData ::= SEQUENCE OF SEQUENCE { negoToken [0] OCTET STRING }
// TSCredentials ::= SEQUENCE { credType [0] INTEGER, credentials [1] OCTET STRING }
// TSPasswordCreds ::= SEQUENCE { domainName [0] OCTET STRING,
//   userName [1] OCTET STRING, password [2] OCTET STRING }
import { createHash } from 'node:crypto';
import { TAG_SEQUENCE, children, expectTag, explicit, integer, octetString, readInteger, readOctetString, readOne, sequence, unwrapExplicit, } from './der.js';
// The version this client speaks, and the oldest server version it accepts.
// Version 5 added the nonce and the hashed pubKeyAuth; version 6 is the
// version every server patched for CVE-2018-0886 speaks. Older servers get
// the unhashed, unbound pubKeyAuth that the CVE broke, so they are refused.
export const CREDSSP_VERSION = 6;
export const MIN_SERVER_VERSION = 6;
export const NONCE_LENGTH = 32;
// TSCredentials credType 1: TSPasswordCreds (MS-CSSP 2.2.1.2).
export const CRED_TYPE_PASSWORD = 1;
export const CLIENT_SERVER_HASH_MAGIC = Buffer.from('CredSSP Client-To-Server Binding Hash\0', 'ascii');
export const SERVER_CLIENT_HASH_MAGIC = Buffer.from('CredSSP Server-To-Client Binding Hash\0', 'ascii');
function checkNonce(nonce, what) {
    if (!nonce)
        throw new Error(`CredSSP: ${what} has no clientNonce`);
    if (nonce.length !== NONCE_LENGTH) {
        throw new Error(`CredSSP: ${what} clientNonce is ${nonce.length} bytes, not ${NONCE_LENGTH}`);
    }
    return nonce;
}
export function encodeTSRequest(req) {
    const parts = [explicit(0, integer(req.version))];
    if (req.negoTokens !== undefined) {
        if (req.negoTokens.length === 0)
            throw new Error('CredSSP: negoTokens must hold at least one token');
        parts.push(explicit(1, sequence(...req.negoTokens.map((t) => sequence(explicit(0, octetString(t)))))));
    }
    if (req.authInfo !== undefined)
        parts.push(explicit(2, octetString(req.authInfo)));
    if (req.pubKeyAuth !== undefined)
        parts.push(explicit(3, octetString(req.pubKeyAuth)));
    if (req.errorCode !== undefined)
        parts.push(explicit(4, integer(req.errorCode)));
    if (req.clientNonce !== undefined)
        parts.push(explicit(5, octetString(checkNonce(req.clientNonce, 'TSRequest'))));
    return sequence(...parts);
}
function decodeNegoData(t) {
    const list = expectTag(unwrapExplicit(t, 'negoTokens'), TAG_SEQUENCE, 'NegoData');
    const tokens = [];
    for (const item of children(list)) {
        const fields = children(expectTag(item, TAG_SEQUENCE, 'NegoData item'));
        const first = fields[0];
        if (fields.length !== 1 || !first || first.tag !== 0xa0)
            throw new Error('CredSSP: a NegoData item must hold negoToken [0] only');
        tokens.push(Buffer.from(readOctetString(unwrapExplicit(first, 'negoToken'), 'negoToken')));
    }
    if (tokens.length === 0)
        throw new Error('CredSSP: negoTokens is empty');
    return tokens;
}
// Decodes one whole TSRequest. Fields must come in tag order, once each.
export function decodeTSRequest(buf) {
    const body = expectTag(readOne(buf, 'TSRequest'), TAG_SEQUENCE, 'TSRequest');
    let version;
    const out = {};
    let last = -1;
    for (const f of children(body)) {
        const n = f.tag - 0xa0;
        if (n < 0 || n > 5)
            throw new Error(`CredSSP: unknown TSRequest field tag 0x${f.tag.toString(16)}`);
        if (n <= last)
            throw new Error('CredSSP: TSRequest fields are out of order or repeated');
        last = n;
        switch (n) {
            case 0:
                version = readInteger(unwrapExplicit(f, 'version'), 'version');
                break;
            case 1:
                out.negoTokens = decodeNegoData(f);
                break;
            case 2:
                out.authInfo = Buffer.from(readOctetString(unwrapExplicit(f, 'authInfo'), 'authInfo'));
                break;
            case 3:
                out.pubKeyAuth = Buffer.from(readOctetString(unwrapExplicit(f, 'pubKeyAuth'), 'pubKeyAuth'));
                break;
            case 4:
                out.errorCode = readInteger(unwrapExplicit(f, 'errorCode'), 'errorCode');
                break;
            case 5:
                out.clientNonce = checkNonce(Buffer.from(readOctetString(unwrapExplicit(f, 'clientNonce'), 'clientNonce')), 'TSRequest');
                break;
        }
    }
    if (version === undefined)
        throw new Error('CredSSP: TSRequest has no version');
    if (version < 0)
        throw new Error(`CredSSP: TSRequest version ${version} is not valid`);
    return { version, ...out };
}
// Refuses a server that cannot bind pubKeyAuth to the nonce.
export function checkServerVersion(version) {
    if (version < MIN_SERVER_VERSION) {
        throw new Error(`CredSSP: the server speaks version ${version}; winlinux needs version ${MIN_SERVER_VERSION} or later ` +
            '(the CVE-2018-0886 fix). Update the server, or use another mechanism');
    }
}
// An NTSTATUS or HRESULT, as Windows prints it.
export function formatErrorCode(code) {
    return `0x${(code >>> 0).toString(16).padStart(8, '0')}`;
}
// MS-CSSP 3.1.5 (version 5 and later): SHA-256 of the magic string, the
// 32-byte client nonce and the SubjectPublicKey of the server certificate.
export function pubKeyAuthHash(direction, nonce, subjectPublicKey) {
    checkNonce(nonce, 'pubKeyAuth');
    if (subjectPublicKey.length === 0)
        throw new Error('CredSSP: the server certificate has no public key');
    const magic = direction === 'client-to-server' ? CLIENT_SERVER_HASH_MAGIC : SERVER_CLIENT_HASH_MAGIC;
    return createHash('sha256')
        .update(magic)
        .update(nonce)
        .update(subjectPublicKey)
        .digest();
}
// TSCredentials { credType 1, credentials = DER TSPasswordCreds }, with each
// string UTF-16LE (MS-CSSP 2.2.1.2.1). The caller zeroes the result once it
// is sealed; the intermediate buffers are zeroed here.
export function encodeTSCredentials(creds) {
    const domain = Buffer.from(creds.domain, 'utf16le');
    const user = Buffer.from(creds.username, 'utf16le');
    const password = Buffer.from(creds.password, 'utf16le');
    const inner = sequence(explicit(0, octetString(domain)), explicit(1, octetString(user)), explicit(2, octetString(password)));
    try {
        return sequence(explicit(0, integer(CRED_TYPE_PASSWORD)), explicit(1, octetString(inner)));
    }
    finally {
        password.fill(0);
        inner.fill(0);
    }
}
// The inverse, for tests and the test server. Strings come back as UTF-16LE
// buffers so a caller can zero them.
export function decodeTSCredentials(buf) {
    const kids = children(expectTag(readOne(buf, 'TSCredentials'), TAG_SEQUENCE, 'TSCredentials'));
    if (kids.length !== 2 || kids[0]?.tag !== 0xa0 || kids[1]?.tag !== 0xa1)
        throw new Error('CredSSP: TSCredentials needs credType [0] and credentials [1]');
    const credType = readInteger(unwrapExplicit(kids[0], 'credType'), 'credType');
    if (credType !== CRED_TYPE_PASSWORD)
        throw new Error(`CredSSP: TSCredentials credType ${credType} is not a password`);
    const raw = readOctetString(unwrapExplicit(kids[1], 'credentials'), 'credentials');
    const fields = children(expectTag(readOne(raw, 'TSPasswordCreds'), TAG_SEQUENCE, 'TSPasswordCreds'));
    if (fields.length !== 3 || fields.some((f, i) => f.tag !== 0xa0 + i))
        throw new Error('CredSSP: TSPasswordCreds needs [0], [1] and [2]');
    const [domain, username, password] = fields.map((f, i) => Buffer.from(readOctetString(unwrapExplicit(f, `TSPasswordCreds [${i}]`), 'TSPasswordCreds')));
    return { credType, domain, username, password };
}
//# sourceMappingURL=tsrequest.js.map