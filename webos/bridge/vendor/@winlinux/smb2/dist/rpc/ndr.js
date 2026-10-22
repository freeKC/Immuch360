// Minimal NDR (little-endian) helpers, just enough for SRVSVC NetShareEnum
// and NetShareGetInfo. The writer emits uint32 fields and conformant-varying
// wide strings; the reader pads string pointees to 4 bytes.
import { SmbError } from "../errors.js";
// The most UTF-16 code units one string may carry. Share names and
// remarks are short; the cap keeps a server from sizing a huge read.
export const MAX_NDR_STRING = 64 * 1024;
// Drops trailing NULs with a backward scan: /\0+$/ takes quadratic time on
// a long run of NULs that is not at the end.
export function trimTrailingNuls(text) {
    let end = text.length;
    while (end > 0 && text.charCodeAt(end - 1) === 0)
        end--;
    return text.slice(0, end);
}
export class NdrWriter {
    parts = [];
    uint32(value) {
        const out = Buffer.alloc(4);
        out.writeUInt32LE(value >>> 0, 0);
        this.parts.push(out);
    }
    bytes(value) {
        this.parts.push(value);
    }
    // Conformant-varying wchar string pointee ([string] wchar_t*): max_count,
    // offset, actual_count, the UTF-16 code units with a NUL, padded to 4.
    wstring(text) {
        const chars = Buffer.from(text + "\0", "utf16le");
        const count = chars.length / 2;
        this.uint32(count);
        this.uint32(0);
        this.uint32(count);
        this.parts.push(chars);
        if (chars.length % 4 !== 0)
            this.parts.push(Buffer.alloc(4 - (chars.length % 4)));
    }
    buffer() {
        return Buffer.concat(this.parts);
    }
}
export class NdrReader {
    buf;
    offset = 0;
    constructor(buf) {
        this.buf = buf;
    }
    get length() {
        return this.buf.length;
    }
    need(count) {
        if (this.offset + count > this.buf.length) {
            throw new SmbError(`short SRVSVC response: need ${count} bytes at offset ${this.offset}, have ${this.buf.length}`);
        }
    }
    uint32() {
        this.need(4);
        const value = this.buf.readUInt32LE(this.offset);
        this.offset += 4;
        return value;
    }
    uint16() {
        this.need(2);
        const value = this.buf.readUInt16LE(this.offset);
        this.offset += 2;
        return value;
    }
    bytes(count) {
        this.need(count);
        const value = this.buf.subarray(this.offset, this.offset + count);
        this.offset += count;
        return value;
    }
    skip(count) {
        this.need(count);
        this.offset += count;
    }
    align(boundary) {
        this.offset += (boundary - (this.offset % boundary)) % boundary;
    }
    // Conformant-varying wchar string pointee: max_count, offset, actual_count,
    // then actual_count UTF-16 code units (usually NUL-terminated), padded to
    // a 4-byte boundary.
    cvString() {
        this.uint32(); // max_count
        this.uint32(); // offset
        const actual = this.uint32();
        if (actual > MAX_NDR_STRING)
            throw new SmbError(`SRVSVC string of ${actual} characters is over the ${MAX_NDR_STRING} limit`);
        const text = trimTrailingNuls(this.bytes(actual * 2).toString("utf16le"));
        this.align(4);
        return text;
    }
}
//# sourceMappingURL=ndr.js.map