// PNG without any package: the pictures of the fake Immich server (server.mjs) are written here, and the pixels of the
// screenshots of the end to end test (run.mjs) are read here. 8 bit RGB and RGBA, no interlace: what Chromium writes.

import {deflateSync, inflateSync, crc32} from 'node:zlib';

function chunk(type, data) {
	const head = Buffer.alloc(8);
	head.writeUInt32BE(data.length, 0);
	head.write(type, 4, 'latin1');
	const crc = Buffer.alloc(4);
	crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])) >>> 0, 0);
	return Buffer.concat([head, data, crc]);
}

/** A PNG of width x height, each pixel [r, g, b] from pixel(x, y) */
export function encodePng(width, height, pixel) {
	const raw = Buffer.alloc((width * 3 + 1) * height);
	for (let y = 0; y < height; y++) {
		const row = y * (width * 3 + 1);
		for (let x = 0; x < width; x++) {
			const [r, g, b] = pixel(x, y);
			raw[row + 1 + x * 3] = r;
			raw[row + 2 + x * 3] = g;
			raw[row + 3 + x * 3] = b;
		}
	}
	const header = Buffer.alloc(13);
	header.writeUInt32BE(width, 0);
	header.writeUInt32BE(height, 4);
	header[8] = 8;
	header[9] = 2;
	return Buffer.concat([
		Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
		chunk('IHDR', header),
		chunk('IDAT', deflateSync(raw, {level: 1})),
		chunk('IEND', Buffer.alloc(0)),
	]);
}

/** The pixels of a PNG: {width, height, rgba(x, y)} */
export function decodePng(png) {
	let offset = 8;
	let width = 0;
	let height = 0;
	let colorType = 0;
	const data = [];
	while (offset < png.length) {
		const length = png.readUInt32BE(offset);
		const type = png.toString('latin1', offset + 4, offset + 8);
		const body = png.subarray(offset + 8, offset + 8 + length);
		if (type === 'IHDR') {
			width = body.readUInt32BE(0);
			height = body.readUInt32BE(4);
			if (body[8] !== 8 || body[12] !== 0) throw new Error('only 8 bit, non interlaced PNG');
			colorType = body[9];
		} else if (type === 'IDAT') data.push(body);
		offset += 12 + length;
	}
	const channels = colorType === 6 ? 4 : colorType === 2 ? 3 : 0;
	if (!channels) throw new Error(`PNG colour type ${colorType}`);
	const raw = inflateSync(Buffer.concat(data));
	const stride = width * channels;
	const out = Buffer.alloc(stride * height);
	for (let y = 0; y < height; y++) {
		const filter = raw[y * (stride + 1)];
		const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
		for (let i = 0; i < stride; i++) {
			const left = i >= channels ? out[y * stride + i - channels] : 0;
			const up = y > 0 ? out[(y - 1) * stride + i] : 0;
			const upLeft = y > 0 && i >= channels ? out[(y - 1) * stride + i - channels] : 0;
			let value = line[i];
			if (filter === 1) value += left;
			else if (filter === 2) value += up;
			else if (filter === 3) value += (left + up) >> 1;
			else if (filter === 4) {
				const p = left + up - upLeft;
				const pa = Math.abs(p - left);
				const pb = Math.abs(p - up);
				const pc = Math.abs(p - upLeft);
				value += pa <= pb && pa <= pc ? left : pb <= pc ? up : upLeft;
			}
			out[y * stride + i] = value & 255;
		}
	}
	return {
		width,
		height,
		rgba(x, y) {
			const at = (y * width + x) * channels;
			return [out[at], out[at + 1], out[at + 2], channels === 4 ? out[at + 3] : 255];
		},
	};
}
