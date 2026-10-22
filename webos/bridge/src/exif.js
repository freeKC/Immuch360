'use strict';
// What the head of a JPEG file tells, read from its first bytes (64 KiB hold it for nearly every camera): the small
// picture the camera wrote in its EXIF block (a thumbnail for the grid, so that the TV does not decode 12 MP
// originals), the picture size, the camera, the orientation, and whether XMP marks it as a 360° photo (GPano).

const HEAD_BYTES = 64 * 1024;

function tiffReader(buf, start, end) {
	const little = buf.toString('latin1', start, start + 2) === 'II';
	const u16 = (offset) => (offset + 2 <= end - start ? (little ? buf.readUInt16LE(start + offset) : buf.readUInt16BE(start + offset)) : null);
	const u32 = (offset) => (offset + 4 <= end - start ? (little ? buf.readUInt32LE(start + offset) : buf.readUInt32BE(start + offset)) : null);
	return {u16, u32};
}

// The entries of the IFD at offset (relative to the TIFF header): tag -> {type, count, value offset}
function readIfd(buf, start, end, reader, offset) {
	const entries = {};
	const count = reader.u16(offset);
	if (count === null || count > 1000) return {entries, next: 0};
	for (let i = 0; i < count; i++) {
		const at = offset + 2 + i * 12;
		const tag = reader.u16(at);
		if (tag === null) break;
		entries[tag] = {type: reader.u16(at + 2), count: reader.u32(at + 4), at: at + 8};
	}
	const next = reader.u32(offset + 2 + count * 12);
	return {entries, next: next || 0};
}

function entryNumber(entry, reader) {
	if (!entry) return null;
	if (entry.type === 3) return reader.u16(entry.at);
	if (entry.type === 4) return reader.u32(entry.at);
	return null;
}

function entryAscii(entry, reader, buf, start, end) {
	if (!entry || entry.type !== 2 || !entry.count) return null;
	const where = entry.count > 4 ? reader.u32(entry.at) : entry.at;
	if (where === null || start + where + entry.count > end) return null;
	return buf.toString('latin1', start + where, start + where + entry.count).replace(/\0+$/, '').trim() || null;
}

function readExif(buf, start, end, out) {
	if (buf.toString('latin1', start, start + 6) !== 'Exif\0\0') return;
	const tiff = start + 6;
	const reader = tiffReader(buf, tiff, end);
	if (reader.u16(2) !== 42) return;
	const first = readIfd(buf, tiff, end, reader, reader.u32(4));
	const ifd0 = first.entries;
	out.make = entryAscii(ifd0[0x010f], reader, buf, tiff, end);
	out.model = entryAscii(ifd0[0x0110], reader, buf, tiff, end);
	out.orientation = entryNumber(ifd0[0x0112], reader);
	const exifPointer = entryNumber(ifd0[0x8769], reader);
	if (exifPointer) {
		const exif = readIfd(buf, tiff, end, reader, exifPointer).entries;
		const width = entryNumber(exif[0xa002], reader);
		const height = entryNumber(exif[0xa003], reader);
		if (width && height && !out.width) {
			out.width = width;
			out.height = height;
		}
	}
	if (first.next) {
		const ifd1 = readIfd(buf, tiff, end, reader, first.next).entries;
		const offset = entryNumber(ifd1[0x0201], reader);
		const length = entryNumber(ifd1[0x0202], reader);
		if (offset && length && tiff + offset + length <= end) {
			const thumb = buf.slice(tiff + offset, tiff + offset + length);
			if (thumb[0] === 0xff && thumb[1] === 0xd8) out.thumbnail = Buffer.from(thumb);
		}
	}
}

const XMP_HEADER = 'http://ns.adobe.com/xap/1.0/\0';

function xmpValue(xmp, name) {
	const attr = new RegExp('GPano:' + name + '\\s*=\\s*["\']([^"\']*)["\']').exec(xmp);
	if (attr) return attr[1];
	const element = new RegExp('<GPano:' + name + '>([^<]*)</GPano:' + name + '>').exec(xmp);
	return element ? element[1] : null;
}

function readXmp(buf, start, end, out) {
	if (buf.toString('latin1', start, start + XMP_HEADER.length) !== XMP_HEADER) return;
	const xmp = buf.toString('utf8', start + XMP_HEADER.length, end);
	const projection = xmpValue(xmp, 'ProjectionType');
	if (projection) out.projection = projection.trim().toLowerCase();
	const fullWidth = Number(xmpValue(xmp, 'FullPanoWidthPixels'));
	const croppedWidth = Number(xmpValue(xmp, 'CroppedAreaImageWidthPixels'));
	if (fullWidth && croppedWidth) out.panoCoverage = croppedWidth / fullWidth;
}

/**
 * What the first bytes of a JPEG tell: {width, height, make, model, orientation, projection, panoCoverage, thumbnail}
 * (each null when unknown). Not a JPEG: every field null.
 */
function readJpegHead(buf) {
	const out = {width: null, height: null, make: null, model: null, orientation: null, projection: null, panoCoverage: null, thumbnail: null};
	if (!buf || buf.length < 4 || buf[0] !== 0xff || buf[1] !== 0xd8) return out;
	let at = 2;
	while (at + 4 <= buf.length) {
		if (buf[at] !== 0xff) break;
		const marker = buf[at + 1];
		if (marker === 0xff) {
			at += 1;
			continue;
		}
		if (marker === 0xd9 || marker === 0xda) break;
		const length = buf.readUInt16BE(at + 2);
		const start = at + 4;
		const end = Math.min(buf.length, at + 2 + length);
		if (marker === 0xe1) {
			readExif(buf, start, end, out);
			readXmp(buf, start, end, out);
		} else if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
			if (start + 5 <= buf.length) {
				out.height = buf.readUInt16BE(start + 1);
				out.width = buf.readUInt16BE(start + 3);
			}
			break;
		}
		at += 2 + length;
	}
	return out;
}

module.exports = {HEAD_BYTES, readJpegHead};
