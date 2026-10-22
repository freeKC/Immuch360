// NTLM crypto primitives (MS-NLMP section 6).
// MD4 comes from hash-wasm and DES from des.js because Node 22 / OpenSSL 3
// removed both from the default provider. RC4 is local (OpenSSL 3 removed it).
import { createHash, createHmac } from 'node:crypto';
import { createRequire } from 'node:module';
import { createMD4 } from 'hash-wasm';
const require = createRequire(import.meta.url);
const { DES } = require('des.js');
export function utf16(s) {
    return Buffer.from(s, 'utf16le');
}
export function md5(...parts) {
    const h = createHash('md5');
    for (const p of parts)
        h.update(p);
    return h.digest();
}
export function hmacMd5(key, ...parts) {
    const h = createHmac('md5', key);
    for (const p of parts)
        h.update(p);
    return h.digest();
}
export async function md4(data) {
    const h = await createMD4();
    h.init();
    h.update(data);
    return Buffer.from(h.digest('binary'));
}
// NTOWFv2 == LMOWFv2 (MS-NLMP 3.3.2).
export async function ntowfv2(password, user, domain) {
    const ntHash = await md4(utf16(password));
    return hmacMd5(ntHash, utf16(user.toUpperCase() + domain));
}
// Single DES-ECB block with a 7-byte key, expanded with odd parity (MS-NLMP DES()).
export function desEncryptBlock(key7, data8) {
    if (key7.length !== 7)
        throw new Error(`DES key must be 7 bytes, got ${key7.length}`);
    if (data8.length !== 8)
        throw new Error(`DES block must be 8 bytes, got ${data8.length}`);
    const k = Buffer.alloc(8);
    k[0] = key7[0] & 0xfe;
    k[1] = ((key7[0] << 7) | (key7[1] >> 1)) & 0xfe;
    k[2] = ((key7[1] << 6) | (key7[2] >> 2)) & 0xfe;
    k[3] = ((key7[2] << 5) | (key7[3] >> 3)) & 0xfe;
    k[4] = ((key7[3] << 4) | (key7[4] >> 4)) & 0xfe;
    k[5] = ((key7[4] << 3) | (key7[5] >> 5)) & 0xfe;
    k[6] = ((key7[5] << 2) | (key7[6] >> 6)) & 0xfe;
    k[7] = (key7[6] << 1) & 0xfe;
    for (let i = 0; i < 8; i++) {
        let ones = 0;
        for (let b = k[i]; b > 0; b >>= 1)
            ones += b & 1;
        if (ones % 2 === 0)
            k[i] |= 1;
    }
    const out = DES.create({ key: Array.from(k), type: 'encrypt' }).update(Array.from(data8));
    return Buffer.from(out);
}
export class RC4 {
    s = new Uint8Array(256);
    i = 0;
    j = 0;
    constructor(key) {
        if (key.length === 0)
            throw new Error('RC4 key must not be empty');
        for (let i = 0; i < 256; i++)
            this.s[i] = i;
        let j = 0;
        for (let i = 0; i < 256; i++) {
            j = (j + this.s[i] + key[i % key.length]) & 0xff;
            const t = this.s[i];
            this.s[i] = this.s[j];
            this.s[j] = t;
        }
    }
    update(data) {
        const out = Buffer.allocUnsafe(data.length);
        for (let n = 0; n < data.length; n++) {
            this.i = (this.i + 1) & 0xff;
            this.j = (this.j + this.s[this.i]) & 0xff;
            const t = this.s[this.i];
            this.s[this.i] = this.s[this.j];
            this.s[this.j] = t;
            out[n] = data[n] ^ this.s[(this.s[this.i] + this.s[this.j]) & 0xff];
        }
        return out;
    }
}
export function rc4(key, data) {
    return new RC4(key).update(data);
}
// Current time as a Windows FILETIME (100ns ticks since 1601-01-01).
export function fileTimeNow() {
    return BigInt(Date.now()) * 10000n + 116444736000000000n;
}
//# sourceMappingURL=crypto.js.map