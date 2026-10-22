'use strict';
// Builds small JPEG files for the tests: an EXIF block (camera, orientation, size, a thumbnail in IFD1), an optional
// XMP block with GPano, a SOF0 with the picture size, and padding standing in for the picture data.

function u16(v) {
	const b = Buffer.alloc(2);
	b.writeUInt16BE(v, 0);
	return b;
}

function segment(marker, payload) {
	return Buffer.concat([Buffer.from([0xff, marker]), u16(payload.length + 2), payload]);
}

// A TIFF block, big endian, with IFD0 (Make, Model, Orientation, ExifIFD), the Exif IFD and IFD1 (the thumbnail)
function tiff(options) {
	const make = Buffer.from((options.make || 'RICOH') + '\0', 'latin1');
	const model = Buffer.from((options.model || 'RICOH THETA Z1') + '\0', 'latin1');
	const thumb = options.thumbnail || Buffer.from([0xff, 0xd8, 0xff, 0xd9]);
	const entry = (tag, type, count, value) => {
		const b = Buffer.alloc(12);
		b.writeUInt16BE(tag, 0);
		b.writeUInt16BE(type, 2);
		b.writeUInt32BE(count, 4);
		if (type === 3 && count === 1) b.writeUInt16BE(value, 8);
		else b.writeUInt32BE(value, 8);
		return b;
	};
	const ifd0Count = 4;
	const ifd0At = 8;
	const ifd0Size = 2 + ifd0Count * 12 + 4;
	const exifAt = ifd0At + ifd0Size;
	const exifSize = 2 + 2 * 12 + 4;
	const ifd1At = exifAt + exifSize;
	const ifd1Size = 2 + 2 * 12 + 4;
	const makeAt = ifd1At + ifd1Size;
	const modelAt = makeAt + make.length;
	const thumbAt = modelAt + model.length;
	const parts = [
		Buffer.from('MM'),
		u16(42),
		Buffer.from([0, 0, 0, ifd0At]),
		u16(ifd0Count),
		entry(0x010f, 2, make.length, makeAt),
		entry(0x0110, 2, model.length, modelAt),
		entry(0x0112, 3, 1, options.orientation || 1),
		entry(0x8769, 4, 1, exifAt),
		Buffer.from([0, 0, (ifd1At >> 8) & 255, ifd1At & 255]),
		u16(2),
		entry(0xa002, 4, 1, options.width || 6720),
		entry(0xa003, 4, 1, options.height || 3360),
		Buffer.alloc(4),
		u16(2),
		entry(0x0201, 4, 1, thumbAt),
		entry(0x0202, 4, 1, thumb.length),
		Buffer.alloc(4),
		make,
		model,
		thumb
	];
	return Buffer.concat(parts);
}

/** A JPEG: options {make, model, orientation, width, height, thumbnail, gpano (true for equirectangular), padding} */
function makeJpeg(options) {
	const opts = options || {};
	const parts = [Buffer.from([0xff, 0xd8])];
	if (opts.exif !== false) parts.push(segment(0xe1, Buffer.concat([Buffer.from('Exif\0\0', 'latin1'), tiff(opts)])));
	if (opts.gpano) {
		const xmp =
			'<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">' +
			'<rdf:Description xmlns:GPano="http://ns.google.com/photos/1.0/panorama/" GPano:ProjectionType="equirectangular" ' +
			'GPano:FullPanoWidthPixels="6720" GPano:CroppedAreaImageWidthPixels="6720"/></rdf:RDF></x:xmpmeta>';
		parts.push(segment(0xe1, Buffer.concat([Buffer.from('http://ns.adobe.com/xap/1.0/\0', 'latin1'), Buffer.from(xmp)])));
	}
	const sof = Buffer.alloc(15);
	sof[0] = 8;
	sof.writeUInt16BE(opts.height || 3360, 1);
	sof.writeUInt16BE(opts.width || 6720, 3);
	sof[5] = 3;
	parts.push(segment(0xc0, sof));
	parts.push(segment(0xda, Buffer.alloc(10)));
	parts.push(Buffer.alloc(opts.padding || 100000, 0x55));
	parts.push(Buffer.from([0xff, 0xd9]));
	return Buffer.concat(parts);
}

module.exports = {makeJpeg};
