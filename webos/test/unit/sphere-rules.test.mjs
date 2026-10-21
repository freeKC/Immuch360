// The 360° rules of src/immuch360/sphere/rules.ts, with the cases of the Dart tests they were ported from
// (mobile/test/domain/models/sphere_coverage_test.dart, raw_360_detection_test.dart, local_panorama_service_test.dart,
// panorama_viewer_test.dart).

import {test, describe} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {
	FULL_SPHERE_CROP,
	HALF_SPHERE_CROP,
	guessSphereCoverage,
	guessStereoLayout,
	initialViewDirection,
	isEquirectCameraPhoto,
	isPanoramaCandidate,
	isPartialSphere,
	isShownAs360,
	leftEyeRect,
	nextStereoLayout,
	parseGPanoCrop,
	parseGPanoInitialView,
	readGPanoTags,
	rect,
	remoteTurnSpeed,
	resolveSphereView,
	sphereCrop,
	zoomFieldOfView,
} from '../../src/immuch360/sphere/rules.ts';

const guess = (options = {}) =>
	guessSphereCoverage({fileName: 'clip.mp4', width: 5760, height: 2880, layout: 'mono', ...options});

describe('guessSphereCoverage', () => {
	test('is a full sphere when nothing tells otherwise', () => {
		assert.equal(guess(), 'full');
		assert.equal(guess({fileName: null, width: null, height: null}), 'full');
		assert.equal(guess({probe: {}}), 'full');
	});

	test('is a half sphere when the file declares one', () => {
		assert.equal(guess({probe: {halfSphere: true}}), 'half');
		assert.equal(guess({probe: {halfSphere: false}}), 'full');
	});

	test('keeps the full sphere the file declares over square eyes and a 180 in the name', () => {
		const fullBounds = {halfSphere: false};
		assert.equal(guess({width: 3840, height: 1920, layout: 'leftRight', probe: fullBounds}), 'full');
		assert.equal(guess({fileName: 'trip_vr180.mp4', probe: fullBounds}), 'full');
	});

	test('is a half sphere when the GPano crop covers half the width and the whole height', () => {
		for (const crop of [rect(0.25, 0, 0.5, 1), rect(0.3, 0.02, 0.45, 0.95), rect(0, 0, 0.55, 1)]) {
			assert.equal(guess({gpanoCrop: crop}), 'half', JSON.stringify(crop));
		}
		for (const crop of [rect(0, 0, 1, 1), rect(0.25, 0.25, 0.5, 0.5), rect(0.3, 0, 0.4, 1), rect(0.2, 0, 0.6, 1), rect(0, 2035 / 4601, 4460 / 9202, 1667 / 4601)]) {
			assert.equal(guess({gpanoCrop: crop}), 'full', JSON.stringify(crop));
		}
	});

	test('is a half sphere when the eyes of a 3D layout are square', () => {
		assert.equal(guess({layout: 'leftRight'}), 'half');
		assert.equal(guess({width: 2880, height: 5760, layout: 'topBottom'}), 'half');
		assert.equal(guess({width: 5760, height: 5760, layout: 'topBottom'}), 'full');
		assert.equal(guess({width: 7680, height: 1920, layout: 'leftRight'}), 'full');
		assert.equal(guess({width: 4096, height: 4096}), 'full');
		assert.equal(guess({width: null, height: null, layout: 'leftRight'}), 'full');
	});

	test('reads VR180 marks in the file name, in any case', () => {
		for (const name of ['VR180_clip.mp4', 'trip.vr180.jpg', 'Concert_180_3D_SBS.mp4', 'beach-180_3d.mp4', 'scene 180x180.mp4', 'trip_180.mp4', 'trip-180-sbs.mp4', 'Tokyo 180°.mov', 'clip.180.mp4', 'CALF_180.MP4']) {
			assert.equal(guess({fileName: name}), 'half', name);
		}
	});

	test('ignores 180 inside longer numbers and words', () => {
		for (const name of ['IMG_1801.JPG', 'DSC_0180.jpg', 'PXL_20240101_180512.mp4', 'VID_20240101_120000.mp4', '3f2a-180b-4c1d.mp4', 'remote_180fps.mp4', 'clip180.mp4', '360_clip.mp4', '']) {
			assert.equal(guess({fileName: name}), 'full', name);
		}
	});
});

describe('resolveSphereView', () => {
	const resolve = (options = {}) => resolveSphereView({fileName: 'clip.mp4', width: 5760, height: 2880, ...options});

	test('shows a regular 2:1 panorama mono over the whole sphere', () => {
		assert.deepEqual(resolve(), {layout: 'mono', coverage: 'full', coverageGuess: 'full'});
	});

	test('shows a VR180 file as two square eyes side by side over the front half', () => {
		assert.deepEqual(resolve({fileName: 'clip_VR180.mp4'}), {layout: 'leftRight', coverage: 'half', coverageGuess: 'half'});
	});

	test('prefers what the file declares to the guesses', () => {
		const view = resolve({probe: {stereo: 'topBottom', halfSphere: true}});
		assert.equal(view.layout, 'topBottom');
		assert.equal(view.coverage, 'half');
	});

	test('takes a 2:1 frame the file declares side by side for a half sphere', () => {
		const view = resolve({probe: {stereo: 'leftRight'}});
		assert.equal(view.layout, 'leftRight');
		assert.equal(view.coverage, 'half');
	});

	test('prefers what the user picked, and keeps the guess apart', () => {
		assert.deepEqual(resolve({fileName: 'clip_vr180.mp4', chosenCoverage: 'full'}), {layout: 'mono', coverage: 'full', coverageGuess: 'half'});
		const picked = resolve({chosenLayout: 'leftRight'});
		assert.equal(picked.layout, 'leftRight');
		assert.equal(picked.coverage, 'half');
		const both = resolve({chosenLayout: 'topBottom', chosenCoverage: 'half'});
		assert.equal(both.layout, 'topBottom');
		assert.equal(both.coverage, 'half');
	});

	test('shows a partial panorama mono, a half sphere one included', () => {
		const view = resolve({width: 4096, height: 4096, gpanoCrop: rect(0.25, 0, 0.5, 1)});
		assert.equal(view.layout, 'mono');
		assert.equal(view.coverage, 'half');
	});
});

describe('sphereCrop and isPartialSphere', () => {
	test('is the whole sphere, or its front half, without a GPano crop', () => {
		assert.deepEqual(sphereCrop('full'), FULL_SPHERE_CROP);
		assert.deepEqual(sphereCrop('half'), HALF_SPHERE_CROP);
	});

	test('is the GPano crop of a partial panorama, whatever the coverage', () => {
		const crop = rect(0, 0.25, 1, 0.5);
		assert.deepEqual(sphereCrop('full', crop), crop);
		assert.deepEqual(sphereCrop('half', crop), crop);
	});

	test('takes the front half over a GPano crop that covers the whole sphere', () => {
		const crop = rect(0, 0, 4095 / 4096, 1);
		assert.deepEqual(sphereCrop('full', crop), crop);
		assert.deepEqual(sphereCrop('half', crop), HALF_SPHERE_CROP);
	});

	test('the front half spans longitudes -90° to +90° and all latitudes', () => {
		assert.equal(360 * (HALF_SPHERE_CROP.left - 0.5), -90);
		assert.equal(360 * (HALF_SPHERE_CROP.left + HALF_SPHERE_CROP.width - 0.5), 90);
	});

	test('a crop covering the whole sphere, within rounding, is no partial panorama', () => {
		assert.equal(isPartialSphere(rect(0, 0, 1, 1)), false);
		assert.equal(isPartialSphere(rect(0, 0, 4095 / 4096, 2047 / 2048)), false);
		assert.equal(isPartialSphere(HALF_SPHERE_CROP), true);
	});
});

describe('stereo layout', () => {
	test('guesses the layout from the shape of the frame', () => {
		assert.equal(guessStereoLayout(5760, 2880), 'mono');
		assert.equal(guessStereoLayout(4096, 4096), 'topBottom');
		assert.equal(guessStereoLayout(7680, 1920), 'leftRight');
		assert.equal(guessStereoLayout(5760, 2880, false, 'half'), 'leftRight');
		assert.equal(guessStereoLayout(2880, 5760, false, 'half'), 'topBottom');
		assert.equal(guessStereoLayout(4096, 4096, true), 'mono');
		assert.equal(guessStereoLayout(null, 2000), 'mono');
	});

	test('the left eye and the order of the 3D button', () => {
		assert.deepEqual(leftEyeRect('topBottom'), rect(0, 0, 1, 0.5));
		assert.deepEqual(leftEyeRect('leftRight'), rect(0, 0, 0.5, 1));
		assert.deepEqual(leftEyeRect('mono'), rect(0, 0, 1, 1));
		assert.equal(nextStereoLayout('mono'), 'topBottom');
		assert.equal(nextStereoLayout('topBottom'), 'leftRight');
		assert.equal(nextStereoLayout('leftRight'), 'mono');
	});
});

describe('names and shapes', () => {
	test('equirect photos of 360° cameras', () => {
		assert.equal(isEquirectCameraPhoto({name: 'GS010012.36P'}), true);
		assert.equal(isEquirectCameraPhoto({name: 'IMG_1.insp', make: 'Arashi Vision', width: 6080, height: 3040}), false);
		assert.equal(isEquirectCameraPhoto({name: 'GSAA0001.JPG', make: 'GoPro', model: 'GoPro Max', width: 5760, height: 2880}), true);
		assert.equal(isEquirectCameraPhoto({name: 'DJI_0001.JPG', make: 'DJI', model: 'Osmo 360', width: 7680, height: 3840}), true);
		assert.equal(isEquirectCameraPhoto({name: 'DJI_0002.JPG', make: 'DJI', model: 'OQ001', width: 7680, height: 3840}), true);
		assert.equal(isEquirectCameraPhoto({name: 'IMG_0001.JPG', make: 'Arashi Vision', model: 'X4', width: 11904, height: 5952}), true);
		assert.equal(isEquirectCameraPhoto({name: 'DJI_0003.JPG', make: 'DJI', model: 'Mavic 3', width: 7680, height: 3840}), false);
		assert.equal(isEquirectCameraPhoto({name: 'GSAA0002.JPG', make: 'GoPro', model: 'GoPro Max', width: 4000, height: 3000}), false);
		assert.equal(isEquirectCameraPhoto({name: 'GSAA0003.JPG', make: 'GoPro', model: 'GoPro Max'}), false);
	});

	test('360° candidates by name and shape, without a lookbehind', () => {
		for (const name of ['360_trip.jpg', 'trip 360.mp4', 'PANO_0001.jpg', 'PXL_20240101_PANO.jpg', 'clip_vr180.mp4', 'IMG.insp', 'VID.insv', 'x.osv', 'GS01.36p']) {
			assert.equal(isPanoramaCandidate(name, null, null), true, name);
		}
		for (const name of ['IMG_1360.JPG', '20240613_103600.jpg', '3600.jpg']) {
			assert.equal(isPanoramaCandidate(name, 4000, 3000), false, name);
		}
		assert.equal(isPanoramaCandidate('IMG_1.jpg', 6000, 3000), true);
		assert.equal(isPanoramaCandidate('IMG_1.jpg', 5900, 3000), true, 'within 2 percent');
		assert.equal(isPanoramaCandidate('trip_3D.jpg', 4000, 4000), true);
		assert.equal(isPanoramaCandidate('IMG_3D41.JPG', 4000, 4000), false);
		assert.equal(isPanoramaCandidate('3d.jpg', 2000, 4000), true);
	});

	test('what the viewer shows as 360°', () => {
		assert.equal(isShownAs360({isVideo: false, projectionType: 'EQUIRECTANGULAR'}), true);
		assert.equal(isShownAs360({isVideo: true, projectionType: 'EQUIRECTANGULAR'}), true);
		assert.equal(isShownAs360({isVideo: false, projectionType: null}), false);
		assert.equal(isShownAs360({isVideo: false, forced: true}), true);
		assert.equal(isShownAs360({isVideo: false, projectionType: 'EQUIRECTANGULAR', name: 'IMG_1.insp'}), false, 'raw');
		assert.equal(isShownAs360({isVideo: true, forced: true, name: 'VID_1.insv'}), false, 'raw');
		assert.equal(isShownAs360({isVideo: false, name: 'GS1.36P'}), true);
		assert.equal(isShownAs360({isVideo: false, name: 'G.JPG', make: 'GoPro', model: 'MAX', width: 5760, height: 2880}), true);
		assert.equal(isShownAs360({isVideo: false, name: 'I.JPG', make: 'Arashi Vision', model: 'X3', width: 5760, height: 2880}), false, 'Insta360 make alone');
		assert.equal(isShownAs360({isVideo: true, name: 'G.MP4', make: 'GoPro', model: 'MAX', width: 5760, height: 2880}), false);
	});
});

describe('GPano', () => {
	const attributes = readFileSync(new URL('../fixtures/gpano-attributes.xmp', import.meta.url), 'latin1');
	const elements = readFileSync(new URL('../fixtures/gpano-elements.xmp', import.meta.url), 'latin1');

	test('reads the crop and the initial view written as attributes, as cameras do', () => {
		const crop = parseGPanoCrop(attributes);
		assert.ok(crop);
		assert.equal(crop.left, 0);
		assert.ok(Math.abs(crop.top - 1000 / 4000) < 1e-9);
		assert.equal(crop.width, 1);
		assert.ok(Math.abs(crop.height - 2000 / 4000) < 1e-9);
		assert.deepEqual(parseGPanoInitialView(attributes), {heading: 90, pitch: -10.5, poseHeading: 45});
	});

	test('reads the tags written as elements, as the copy of the server into previews does', () => {
		assert.deepEqual(parseGPanoCrop(elements), rect(0.25, 0, 0.5, 1));
		assert.equal(parseGPanoInitialView(elements), null, 'no pitch, no initial view');
	});

	test('finds the XMP at the head of a file, else at its tail', () => {
		const xmp = new TextEncoder().encode(elements);
		const head = new Uint8Array(300000);
		head.set(xmp, 10);
		assert.equal(readGPanoTags(head).projectionType, 'equirectangular');
		const tail = new Uint8Array(300000);
		tail.set(xmp, tail.length - xmp.length - 10);
		assert.deepEqual(readGPanoTags(tail).crop, rect(0.25, 0, 0.5, 1));
		const middle = new Uint8Array(400000);
		middle.set(xmp, 200000);
		assert.equal(readGPanoTags(middle), null, 'outside both windows');
		assert.equal(readGPanoTags(new Uint8Array(1000)), null);
	});

	test('the initial view points the given heading, from the pose heading', () => {
		assert.deepEqual(initialViewDirection({heading: 90, pitch: -10, poseHeading: 45}), {longitude: 45, latitude: -10});
		assert.deepEqual(initialViewDirection({heading: 10, pitch: 100, poseHeading: 350}), {longitude: 20, latitude: 90});
		assert.deepEqual(initialViewDirection({heading: 350, pitch: 0, poseHeading: 10}), {longitude: -20, latitude: 0});
	});
});

describe('remote control of the sphere', () => {
	test('turns faster while an arrow is held, slower once zoomed in', () => {
		assert.equal(remoteTurnSpeed(0, 90), 40);
		assert.equal(remoteTurnSpeed(0.25, 90), 80);
		assert.equal(remoteTurnSpeed(5, 90), 120);
		assert.equal(remoteTurnSpeed(5, 45), 60);
		assert.equal(remoteTurnSpeed(-1, 90), 40);
	});

	test('zooms by 1.25 a step, within 15° and 115°', () => {
		assert.equal(zoomFieldOfView(90, true), 72);
		assert.equal(zoomFieldOfView(72, false), 90);
		assert.equal(zoomFieldOfView(16, true), 15);
		assert.equal(zoomFieldOfView(100, false), 115);
	});
});
