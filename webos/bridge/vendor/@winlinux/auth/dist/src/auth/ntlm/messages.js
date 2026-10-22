// NTLMv2 messages: NEGOTIATE (type1), CHALLENGE (type2) parse, AUTHENTICATE
// (type3) build. MS-NLMP 2.2.1, 3.1.5.1.2, 3.3.2. NTLMv2 only; NTLMv1 is not
// implemented. Requires UNICODE + NTLM + extended session security.
import { randomBytes } from 'node:crypto';
import { fileTimeNow, hmacMd5, ntowfv2, rc4, utf16 } from './crypto.js';
export const F_UNICODE = 0x00000001;
export const F_OEM = 0x00000002;
export const F_REQUEST_TARGET = 0x00000004;
export const F_SIGN = 0x00000010;
export const F_SEAL = 0x00000020;
export const F_NTLM = 0x00000200;
export const F_ALWAYS_SIGN = 0x00008000;
export const F_ESS = 0x00080000;
export const F_TARGET_INFO = 0x00800000;
export const F_TARGET_TYPE_DOMAIN = 0x00010000;
export const F_TARGET_TYPE_SERVER = 0x00020000;
export const F_TARGET_TYPE_SHARE = 0x00040000;
export const F_VERSION = 0x02000000;
export const F_128 = 0x20000000;
export const F_KEY_EXCH = 0x40000000;
export const F_56 = 0x80000000;
export const TYPE1_FLAGS = 
// eslint-disable-next-line no-bitwise
F_UNICODE |
    F_REQUEST_TARGET |
    F_SIGN |
    F_SEAL |
    F_NTLM |
    F_ALWAYS_SIGN |
    F_ESS |
    F_TARGET_INFO |
    F_VERSION |
    F_128 |
    F_KEY_EXCH |
    F_56;
export const SIGNATURE = 'NTLMSSP\0';
// Non-Windows client: modern major/minor, zero build, W2K3 revision.
export const CLIENT_VERSION = { major: 10, minor: 0, build: 0, reserved: 0, revision: 0x0f };
export const AV_EOL = 0;
export const AV_NB_COMPUTER = 1;
export const AV_NB_DOMAIN = 2;
export const AV_DNS_COMPUTER = 3;
export const AV_DNS_DOMAIN = 4;
export const AV_FLAGS = 6;
export const AV_TIMESTAMP = 7;
export const AV_TARGET_NAME = 9;
export const AV_CHANNEL_BINDINGS = 10;
export const AV_FLAG_MIC = 0x2;
export function parseAvPairs(buf) {
    const out = [];
    let off = 0;
    for (;;) {
        if (off + 4 > buf.length)
            throw new Error('NTLM: truncated AV pair header');
        const id = buf.readUInt16LE(off);
        const len = buf.readUInt16LE(off + 2);
        if (off + 4 + len > buf.length)
            throw new Error('NTLM: truncated AV pair value');
        out.push({ id, value: buf.subarray(off + 4, off + 4 + len) });
        off += 4 + len;
        if (id === AV_EOL)
            break;
    }
    return out;
}
export function encodeAvPairs(pairs) {
    const parts = [];
    for (const p of pairs) {
        const h = Buffer.alloc(4);
        h.writeUInt16LE(p.id, 0);
        h.writeUInt16LE(p.value.length, 2);
        parts.push(h, p.value);
    }
    return Buffer.concat(parts);
}
function writeSecurityBuffer(h, off, len, pos) {
    h.writeUInt16LE(len, off);
    h.writeUInt16LE(len, off + 2);
    h.writeUInt32LE(pos, off + 4);
}
function writeVersion(h, off, v, include) {
    if (!include) {
        h.fill(0, off, off + 8);
        return;
    }
    h[off] = v.major;
    h[off + 1] = v.minor;
    h.writeUInt16LE(v.build, off + 2);
    h.writeUInt16LE(0, off + 4);
    h[off + 6] = v.reserved;
    h[off + 7] = v.revision;
}
export function buildType1(opts) {
    const flags = (opts.flags ?? TYPE1_FLAGS) >>> 0;
    const version = opts.version ?? CLIENT_VERSION;
    const d = utf16(opts.domain);
    const w = utf16(opts.workstation);
    const h = Buffer.alloc(40);
    h.write(SIGNATURE, 0, 'ascii');
    h.writeUInt32LE(1, 8);
    h.writeUInt32LE(flags, 12);
    writeSecurityBuffer(h, 16, d.length, 40);
    writeSecurityBuffer(h, 24, w.length, 40 + d.length);
    // eslint-disable-next-line no-bitwise
    writeVersion(h, 32, version, (flags & F_VERSION) !== 0);
    return Buffer.concat([h, d, w]);
}
function sliceChecked(buf, len, off, what) {
    if (off + len > buf.length)
        throw new Error(`NTLM type2: ${what} out of bounds`);
    return buf.subarray(off, off + len);
}
export function parseType2(buf) {
    if (buf.length < 48)
        throw new Error('NTLM type2: message too short');
    if (buf.subarray(0, 8).toString('ascii') !== SIGNATURE)
        throw new Error('NTLM type2: bad signature');
    if (buf.readUInt32LE(8) !== 2)
        throw new Error('NTLM type2: not a CHALLENGE_MESSAGE');
    const flags = buf.readUInt32LE(20);
    const serverChallenge = Buffer.from(buf.subarray(24, 32));
    const targetName = Buffer.from(sliceChecked(buf, buf.readUInt16LE(12), buf.readUInt32LE(16), 'target'));
    const infoRaw = sliceChecked(buf, buf.readUInt16LE(40), buf.readUInt32LE(44), 'target info');
    const targetInfo = infoRaw.length === 0 ? [] : parseAvPairs(Buffer.from(infoRaw));
    return {
        flags,
        serverChallenge,
        targetName,
        targetInfo,
        targetInfoRaw: Buffer.from(infoRaw),
        raw: Buffer.from(buf),
    };
}
// Response flags: our type1 offer minus capabilities the server lacks.
// The server's target-type advertisement is never echoed (MS-NLMP 4.2.4.3:
// challenge 0xe28a8233 -> response 0xe2888235).
export function negotiateResponseFlags(type1Flags, challengeFlags) {
    // eslint-disable-next-line no-bitwise
    if (!(challengeFlags & F_UNICODE))
        throw new Error('NTLM: server did not offer UNICODE');
    // eslint-disable-next-line no-bitwise
    if (!(challengeFlags & F_NTLM))
        throw new Error('NTLM: server did not offer NTLM');
    // eslint-disable-next-line no-bitwise
    if (!(challengeFlags & F_ESS)) {
        throw new Error('NTLM: server did not offer extended session security (NTLMv1 is not supported)');
    }
    // Without NEGOTIATE_128 the sealing key is cut to 56 or 40 bits of RC4
    // (MS-NLMP 3.4.5.3). A server, or anyone on the path, must not be able
    // to choose that.
    // eslint-disable-next-line no-bitwise
    if (!(challengeFlags & F_128)) {
        throw new Error('NTLM: server did not offer 128-bit keys (NEGOTIATE_128); 56- and 40-bit sealing keys are refused');
    }
    // eslint-disable-next-line no-bitwise
    let f = (type1Flags & ~(F_TARGET_TYPE_DOMAIN | F_TARGET_TYPE_SERVER | F_TARGET_TYPE_SHARE)) >>> 0;
    for (const bit of [F_128, F_56, F_KEY_EXCH, F_SIGN, F_SEAL, F_ALWAYS_SIGN, F_VERSION]) {
        // eslint-disable-next-line no-bitwise
        if (!(challengeFlags & bit))
            f = (f & ~bit) >>> 0;
    }
    return f >>> 0;
}
export async function buildType3(opts) {
    const version = opts.version ?? CLIENT_VERSION;
    const flags = opts.responseFlags >>> 0;
    const ch = opts.challenge;
    const clientChallenge = opts.clientChallenge ?? randomBytes(8);
    const serverPairs = ch.targetInfo.filter((p) => p.id !== AV_EOL);
    const tsPair = serverPairs.find((p) => p.id === AV_TIMESTAMP);
    const hasTimestamp = tsPair !== undefined && tsPair.value.length === 8;
    const time = opts.timeOverride ?? (hasTimestamp ? tsPair.value.readBigUInt64LE(0) : fileTimeNow());
    const tempHead = Buffer.alloc(28);
    tempHead[0] = 1;
    tempHead[1] = 1;
    tempHead.writeBigUInt64LE(time, 8);
    clientChallenge.copy(tempHead, 16);
    // temp = head + ServerName + Z(4) (MS-NLMP 3.3.2). The client adds its
    // own pairs (3.1.5.1.2): the channel binding when the caller has one, and
    // the target name; with a server timestamp also the MIC flag (the MIC
    // needs the timestamp), and the target name even when empty. The client's
    // pairs replace any copies in the CHALLENGE, which must not decide what
    // this AUTHENTICATE binds to. With no binding the pair is left
    // out, as pyspnego does: Windows over TLS refuses an all-zero binding
    //. With nothing to add or replace, the server AV list (EOL
    // included) is relayed verbatim.
    if (opts.channelBindings && opts.channelBindings.length !== 16) {
        throw new Error('NTLM type3: channel bindings must be a 16-byte MD5');
    }
    const clientPairs = [];
    if (opts.channelBindings)
        clientPairs.push({ id: AV_CHANNEL_BINDINGS, value: Buffer.from(opts.channelBindings) });
    if (hasTimestamp || opts.targetName !== undefined) {
        clientPairs.push({ id: AV_TARGET_NAME, value: utf16(opts.targetName ?? '') });
    }
    const clientOwned = (p) => p.id === AV_CHANNEL_BINDINGS || p.id === AV_TARGET_NAME;
    const eol = Buffer.from([0x00, 0x00, 0x00, 0x00]);
    let temp;
    if (hasTimestamp || clientPairs.length > 0 || serverPairs.some(clientOwned)) {
        const pairs = serverPairs.filter((p) => !clientOwned(p)).map((p) => ({ id: p.id, value: Buffer.from(p.value) }));
        if (hasTimestamp) {
            const flagPair = pairs.find((p) => p.id === AV_FLAGS);
            if (flagPair && flagPair.value.length === 4) {
                const v = Buffer.from(flagPair.value);
                // eslint-disable-next-line no-bitwise
                v.writeUInt32LE(v.readUInt32LE(0) | AV_FLAG_MIC, 0);
                flagPair.value = v;
            }
            else if (!flagPair) {
                const v = Buffer.alloc(4);
                v.writeUInt32LE(AV_FLAG_MIC, 0);
                pairs.push({ id: AV_FLAGS, value: v });
            }
        }
        pairs.push(...clientPairs);
        temp = Buffer.concat([tempHead, encodeAvPairs(pairs), eol, Buffer.alloc(4)]);
    }
    else {
        temp = Buffer.concat([tempHead, ch.targetInfoRaw, Buffer.alloc(4)]);
    }
    const responseKey = await ntowfv2(opts.password, opts.username, opts.domain);
    const ntProof = hmacMd5(responseKey, ch.serverChallenge, temp);
    const ntResponse = Buffer.concat([ntProof, temp]);
    const lmResponse = hasTimestamp
        ? Buffer.alloc(24)
        : Buffer.concat([hmacMd5(responseKey, ch.serverChallenge, clientChallenge), clientChallenge]);
    const sessionBaseKey = hmacMd5(responseKey, ntProof);
    // eslint-disable-next-line no-bitwise
    const keyExchActive = (flags & F_KEY_EXCH) !== 0 && (flags & (F_SIGN | F_SEAL)) !== 0;
    const exportedSessionKey = opts.exportedSessionKey ?? (keyExchActive ? randomBytes(16) : Buffer.from(sessionBaseKey));
    const encKey = keyExchActive ? rc4(sessionBaseKey, exportedSessionKey) : Buffer.alloc(0);
    const domainB = utf16(opts.domain);
    const userB = utf16(opts.username);
    const wksB = utf16(opts.workstation);
    const micIncluded = hasTimestamp;
    const headLen = micIncluded ? 88 : 72;
    const h = Buffer.alloc(headLen);
    h.write(SIGNATURE, 0, 'ascii');
    h.writeUInt32LE(3, 8);
    let pos = headLen;
    writeSecurityBuffer(h, 28, domainB.length, pos);
    pos += domainB.length;
    writeSecurityBuffer(h, 36, userB.length, pos);
    pos += userB.length;
    writeSecurityBuffer(h, 44, wksB.length, pos);
    pos += wksB.length;
    writeSecurityBuffer(h, 12, lmResponse.length, pos);
    pos += lmResponse.length;
    writeSecurityBuffer(h, 20, ntResponse.length, pos);
    pos += ntResponse.length;
    writeSecurityBuffer(h, 52, encKey.length, pos);
    h.writeUInt32LE(flags, 60);
    // eslint-disable-next-line no-bitwise
    writeVersion(h, 64, version, (flags & F_VERSION) !== 0);
    const payload = [domainB, userB, wksB, lmResponse, ntResponse, encKey];
    let message = Buffer.concat([h, ...payload]);
    if (micIncluded) {
        if (!opts.negotiateMessage)
            throw new Error('NTLM type3: MIC needs the raw type1 message');
        const mic = hmacMd5(exportedSessionKey, opts.negotiateMessage, ch.raw, message);
        mic.copy(message, 72);
    }
    return { message, sessionBaseKey, exportedSessionKey, micIncluded };
}
//# sourceMappingURL=messages.js.map