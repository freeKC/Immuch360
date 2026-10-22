'use strict';
// Fragmented MP4 (ISO BMFF) for Media Source Extensions and for HLS: an init segment (ftyp and moov with one H.264
// track), then one moof and mdat per frame. A remux only: the TV's hardware decodes the video.

function box(type, parts) {
	const body = Buffer.concat(parts);
	const head = Buffer.alloc(8);
	head.writeUInt32BE(8 + body.length, 0);
	head.write(type, 4, 'ascii');
	return Buffer.concat([head, body]);
}

function u32(v) {
	const b = Buffer.alloc(4);
	b.writeUInt32BE(v >>> 0, 0);
	return b;
}

function u16(v) {
	const b = Buffer.alloc(2);
	b.writeUInt16BE(v & 0xffff, 0);
	return b;
}

function fullBox(type, version, flags, parts) {
	return box(type, [Buffer.from([version, (flags >> 16) & 255, (flags >> 8) & 255, flags & 255])].concat(parts));
}

const MATRIX = Buffer.concat([u32(0x10000), u32(0), u32(0), u32(0), u32(0x10000), u32(0), u32(0), u32(0), u32(0x40000000)]);
const TIMESCALE = 90000;

/** The init segment of an H.264 track of that size, from its SPS and PPS */
function initSegment(sps, pps, size) {
	const avcC = box('avcC', [Buffer.from([1, sps[1], sps[2], sps[3], 0xff, 0xe1]), u16(sps.length), sps, Buffer.from([1]), u16(pps.length), pps]);
	const avc1 = box('avc1', [
		Buffer.alloc(6),
		u16(1),
		Buffer.alloc(16),
		u16(size.width),
		u16(size.height),
		u32(0x480000),
		u32(0x480000),
		u32(0),
		u16(1),
		Buffer.alloc(32),
		u16(0x18),
		u16(0xffff),
		avcC
	]);
	const stbl = box('stbl', [
		fullBox('stsd', 0, 0, [u32(1), avc1]),
		fullBox('stts', 0, 0, [u32(0)]),
		fullBox('stsc', 0, 0, [u32(0)]),
		fullBox('stsz', 0, 0, [u32(0), u32(0)]),
		fullBox('stco', 0, 0, [u32(0)])
	]);
	const minf = box('minf', [fullBox('vmhd', 0, 1, [Buffer.alloc(8)]), box('dinf', [fullBox('dref', 0, 0, [u32(1), fullBox('url ', 0, 1, [])])]), stbl]);
	const mdia = box('mdia', [
		fullBox('mdhd', 0, 0, [u32(0), u32(0), u32(TIMESCALE), u32(0), u16(0x55c4), u16(0)]),
		fullBox('hdlr', 0, 0, [u32(0), Buffer.from('vide'), Buffer.alloc(12), Buffer.from('VideoHandler\0')]),
		minf
	]);
	const tkhd = fullBox('tkhd', 0, 3, [u32(0), u32(0), u32(1), u32(0), u32(0), Buffer.alloc(8), u16(0), u16(0), u16(0), u16(0), MATRIX, u32(size.width * 65536), u32(size.height * 65536)]);
	const trak = box('trak', [tkhd, mdia]);
	const mvex = box('mvex', [fullBox('trex', 0, 0, [u32(1), u32(1), u32(0), u32(0), u32(0)])]);
	const mvhd = fullBox('mvhd', 0, 0, [u32(0), u32(0), u32(1000), u32(0), u32(0x10000), u16(0x100), Buffer.alloc(10), MATRIX, Buffer.alloc(24), u32(2)]);
	return Buffer.concat([box('ftyp', [Buffer.from('isom'), u32(0x200), Buffer.from('isomiso6avc1mp41')]), box('moov', [mvhd, trak, mvex])]);
}

/**
 * One frame as a moof and mdat: sequence number, decode time and duration in 90 kHz units, whether it is a key frame,
 * and its NAL units (written with 4 byte lengths)
 */
function fragment(sequence, decodeTime, duration, key, nals) {
	const parts = [];
	nals.forEach((nal) => {
		parts.push(u32(nal.length));
		parts.push(nal);
	});
	const sample = Buffer.concat(parts);
	const flags = key ? 0x02000000 : 0x01010000;
	const high = Math.floor(decodeTime / 4294967296);
	const low = decodeTime % 4294967296;
	const traf = (dataOffset) =>
		box('traf', [
			fullBox('tfhd', 0, 0x020000, [u32(1)]),
			fullBox('tfdt', 1, 0, [u32(high), u32(low)]),
			fullBox('trun', 0, 0x000701, [u32(1), u32(dataOffset), u32(duration), u32(sample.length), u32(flags)])
		]);
	const moofSize = box('moof', [fullBox('mfhd', 0, 0, [u32(sequence)]), traf(0)]).length;
	const moof = box('moof', [fullBox('mfhd', 0, 0, [u32(sequence)]), traf(moofSize + 8)]);
	return Buffer.concat([moof, box('mdat', [sample])]);
}

/** The top level boxes of a buffer: [{type, size}] (for the tests and the checks) */
function topBoxes(buf) {
	const out = [];
	let at = 0;
	while (at + 8 <= buf.length) {
		const size = buf.readUInt32BE(at);
		if (size < 8) break;
		out.push({type: buf.toString('ascii', at + 4, at + 8), size: size});
		at += size;
	}
	return out;
}

module.exports = {initSegment, fragment, topBoxes, TIMESCALE};
