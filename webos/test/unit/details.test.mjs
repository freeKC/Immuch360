// The details panel of the viewer (src/immuch360/details/rows.ts): which lines show, and how sizes and cameras read.

import {test, describe} from 'node:test';
import assert from 'node:assert/strict';
import {cameraName, detailsRows, formatBytes} from '../../src/immuch360/details/rows.ts';

const asset = {
	id: 'a1',
	type: 'IMAGE',
	ratio: 1.5,
	localDateTime: '2024-06-01T10:20:00.000Z',
	durationSeconds: null,
	city: 'Lyon',
	country: 'France',
};

describe('the details panel', () => {
	test('sizes in steps of 1024, one decimal from KB on', () => {
		assert.equal(formatBytes(512, 'en-US'), '512 B');
		assert.equal(formatBytes(1536, 'en-US'), '1.5 KB');
		assert.equal(formatBytes(5 * 1024 * 1024, 'en-US'), '5.0 MB');
		assert.equal(formatBytes(3.25 * 1024 ** 3, 'en-US'), '3.3 GB');
	});

	test('the make is not repeated when the model starts with it', () => {
		assert.equal(cameraName('Canon', 'Canon EOS R6'), 'Canon EOS R6');
		assert.equal(cameraName('GoPro', 'MAX'), 'GoPro MAX');
		assert.equal(cameraName('DJI', null), 'DJI');
		assert.equal(cameraName(null, null), '');
	});

	test('before the server answers: the date and the place', () => {
		const rows = detailsRows(asset, null);
		assert.deepEqual(rows.map((row) => row.label), ['Date and Time', 'Location']);
		assert.equal(rows[1].value, 'Lyon, France');
	});

	test('with the details of the asset, the lines without a value left out', () => {
		const details = {
			id: 'a1',
			type: 'IMAGE',
			originalFileName: 'IMG_0001.JPG',
			originalMimeType: 'image/jpeg',
			width: 6000,
			height: 4000,
			make: 'Canon',
			model: 'Canon EOS R6',
			projectionType: null,
			fileSize: 8 * 1024 * 1024,
		};
		const rows = detailsRows({...asset, city: null, country: null}, details);
		assert.deepEqual(
			rows.map((row) => [row.label, row.value]),
			[
				['Filename', 'IMG_0001.JPG'],
				['Date and Time', rows[1].value],
				['Resolution', '6000 × 4000'],
				['File size', '8.0 MB'],
				['Camera', 'Canon EOS R6'],
				['Type', 'image/jpeg'],
			]
		);
		assert.match(rows[1].value, /2024/);
	});
});
