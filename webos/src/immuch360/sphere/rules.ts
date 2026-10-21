// Immuch360: the 360° rules of the app, ported from the Dart of the fork so that the TV decides as the phones do.
//
// Sources, at the commit this folder was written from (a0af38a54):
// - mobile/lib/domain/models/stereo_layout.dart (guessStereoLayout, leftEyeRect)
// - mobile/lib/domain/models/sphere_coverage.dart (guessSphereCoverage, resolveSphereView, sphereCrop, isPartialSphere)
// - mobile/lib/domain/services/raw/raw_360_detection.dart (isEquirectCameraPhoto and the raw file names)
// - mobile/lib/domain/services/local_panorama.service.dart (the name and shape rules of a 360° candidate)
// - mobile/lib/presentation/widgets/asset_viewer/panorama_viewer.widget.dart (the GPano reader, the initial view)
// - mobile/lib/presentation/widgets/tv/remote_keys.dart (remoteTurnSpeed, remotePitchFactor)
//
// webOS 4 runs Chromium 53, which has no lookbehind in regular expressions: the Dart patterns that use one are
// written here with a group that matches the start of the name or the character before instead.

/** A part of a frame or of the sphere, in fractions of it, top left origin */
export interface Rect {
	left: number;
	top: number;
	width: number;
	height: number;
}

export type StereoLayout = 'mono' | 'topBottom' | 'leftRight';
export type SphereCoverage = 'full' | 'half';

/** How a viewer shows a 360° media: the layout of its eyes and the coverage, with the guess kept apart */
export interface SphereView {
	layout: StereoLayout;
	coverage: SphereCoverage;
	coverageGuess: SphereCoverage;
}

export const rect = (left: number, top: number, width: number, height: number): Rect => ({left, top, width, height});

/** The whole sphere, as a GPano crop */
export const FULL_SPHERE_CROP: Rect = rect(0, 0, 1, 1);

/** The front half of the sphere (VR180): longitudes -90° to +90°, all latitudes */
export const HALF_SPHERE_CROP: Rect = rect(0.25, 0, 0.5, 1);

// ---------------------------------------------------------------------------------------------------------------
// Stereo layout

/**
 * Guesses how the eyes of a 360° media of width x height pixels are laid out. Each eye of a full sphere is a 2:1
 * image: stacked they make a square frame, side by side a 4:1 frame. Each eye of a half sphere is square: stacked a
 * 1:2 frame, side by side a 2:1 frame. Within 10%. Anything else is mono, as are unknown sizes and partial panoramas.
 */
export function guessStereoLayout(
	width: number | null | undefined,
	height: number | null | undefined,
	hasGPanoCrop = false,
	coverage: SphereCoverage = 'full'
): StereoLayout {
	if (hasGPanoCrop || !width || !height || width <= 0 || height <= 0) return 'mono';
	const eyeAspectRatio = coverage === 'full' ? 2 : 1;
	const near = (aspectRatio: number) => Math.abs(width / height - aspectRatio) <= aspectRatio * 0.1 + 1e-9;
	if (near(eyeAspectRatio / 2)) return 'topBottom';
	if (near(eyeAspectRatio * 2)) return 'leftRight';
	return 'mono';
}

/** Part of the frame the left eye fills; a TV shows that eye only */
export function leftEyeRect(layout: StereoLayout): Rect {
	switch (layout) {
		case 'topBottom':
			return rect(0, 0, 1, 0.5);
		case 'leftRight':
			return rect(0, 0, 0.5, 1);
		default:
			return rect(0, 0, 1, 1);
	}
}

/** The layout the 3D button switches to: mono, top and bottom, side by side, mono again */
export function nextStereoLayout(layout: StereoLayout): StereoLayout {
	return layout === 'mono' ? 'topBottom' : layout === 'topBottom' ? 'leftRight' : 'mono';
}

// ---------------------------------------------------------------------------------------------------------------
// Coverage

/** Whether a GPano crop leaves part of the sphere out; within 1% a crop is the whole sphere */
export function isPartialSphere(crop: Rect): boolean {
	return Math.abs(crop.left) > 0.01 || Math.abs(crop.top) > 0.01 || Math.abs(crop.width - 1) > 0.01 || Math.abs(crop.height - 1) > 0.01;
}

// "vr180", "180x180" and "180_3d" anywhere, and 180 alone after an underscore, a dash, a dot or a space, but not as
// the start of a longer number or word. No lookbehind is needed here: the character before is part of the match.
const HALF_SPHERE_FILE_NAME = /vr180|180x180|180[_\- ]3d|[_\-. ]180(?![a-z0-9])/i;

function hasSquareEyes(layout: StereoLayout, width: number | null | undefined, height: number | null | undefined): boolean {
	if (layout === 'mono' || !width || !height || width <= 0 || height <= 0) return false;
	const eye = leftEyeRect(layout);
	const aspectRatio = (width * eye.width) / (height * eye.height);
	return aspectRatio >= 0.9 && aspectRatio <= 1.1;
}

/** What a video file declares, when a probe read it (the TV app has no probe yet: always null for now) */
export interface SphericalDeclaration {
	halfSphere?: boolean | null;
	stereo?: StereoLayout | null;
}

/**
 * Guesses whether a 360° media covers the full sphere or the front half (VR180): what the file declares, a GPano
 * crop about half the width and the whole height, square eyes of a 3D layout, or a VR180 mark in the file name.
 */
export function guessSphereCoverage(options: {
	fileName: string | null | undefined;
	width: number | null | undefined;
	height: number | null | undefined;
	layout?: StereoLayout;
	gpanoCrop?: Rect | null;
	probe?: SphericalDeclaration | null;
}): SphereCoverage {
	const {fileName, width, height, layout = 'mono', gpanoCrop, probe} = options;
	if (probe?.halfSphere === true) return 'half';
	if (probe?.halfSphere === false) return 'full';
	if (gpanoCrop && gpanoCrop.width >= 0.45 && gpanoCrop.width <= 0.55 && gpanoCrop.height > 0.9) return 'half';
	if (hasSquareEyes(layout, width, height)) return 'half';
	if (fileName && HALF_SPHERE_FILE_NAME.test(fileName)) return 'half';
	return 'full';
}

/**
 * How the viewer shows a 360° media: the coverage the user picked, else the guess; the layout the user picked, else
 * the one the file declares, else the guess for that coverage.
 */
export function resolveSphereView(options: {
	fileName: string | null | undefined;
	width: number | null | undefined;
	height: number | null | undefined;
	gpanoCrop?: Rect | null;
	probe?: SphericalDeclaration | null;
	chosenLayout?: StereoLayout | null;
	chosenCoverage?: SphereCoverage | null;
}): SphereView {
	const {fileName, width, height, gpanoCrop, probe, chosenLayout, chosenCoverage} = options;
	const hasGPanoCrop = !!gpanoCrop && isPartialSphere(gpanoCrop);
	const knownLayout = chosenLayout ?? probe?.stereo ?? null;
	const coverageGuess = guessSphereCoverage({
		fileName,
		width,
		height,
		layout: knownLayout ?? guessStereoLayout(width, height, hasGPanoCrop),
		gpanoCrop,
		probe,
	});
	const coverage = chosenCoverage ?? coverageGuess;
	const layout = knownLayout ?? guessStereoLayout(width, height, hasGPanoCrop, coverage);
	return {layout, coverage, coverageGuess};
}

/** The part of the full sphere an image covers: a partial GPano crop, else the front half for VR180, else all */
export function sphereCrop(coverage: SphereCoverage, gpanoCrop?: Rect | null): Rect {
	if (gpanoCrop && isPartialSphere(gpanoCrop)) return gpanoCrop;
	return coverage === 'full' ? gpanoCrop ?? FULL_SPHERE_CROP : HALF_SPHERE_CROP;
}

// ---------------------------------------------------------------------------------------------------------------
// Names and shapes

const RAW_PHOTO_NAME = /\.insp$/i;
const RAW_VIDEO_NAME = /\.(insv|360|osv)$/i;
const CAMERA_EQUIRECT_PHOTO_NAME = /\.36p$/i;

/** A raw Insta360 photo (.insp): two fisheye circles, never shown as an equirect picture */
export const isRawPhotoName = (name: string): boolean => RAW_PHOTO_NAME.test(name);

/** A raw 360° video: Insta360 .insv, GoPro .360, DJI .osv */
export const isRawVideoName = (name: string): boolean => RAW_VIDEO_NAME.test(name);

/** Whether a frame holds two squares side by side, 2:1 within 1%; null when its size is unknown */
export function isSideBySideFrame(width: number | null | undefined, height: number | null | undefined): boolean | null {
	if (!width || !height || width <= 0 || height <= 0) return null;
	return Math.abs(width / height / 2 - 1) <= 0.01;
}

/**
 * Whether a photo is an equirect JPEG a 360° camera stitched itself: named .36p (GoPro MAX 2), or 2:1 within 1% from
 * a known 360° camera (GoPro MAX, DJI 360 or OQ, Insta360 "Arashi Vision"). Never a raw .insp.
 */
export function isEquirectCameraPhoto(options: {
	name: string;
	make?: string | null;
	model?: string | null;
	width?: number | null;
	height?: number | null;
}): boolean {
	const {name, make, model, width, height} = options;
	if (isRawPhotoName(name)) return false;
	if (CAMERA_EQUIRECT_PHOTO_NAME.test(name)) return true;
	if (isSideBySideFrame(width, height) !== true) return false;
	const maker = (make ?? '').trim().toLowerCase();
	const camera = (model ?? '').trim().toLowerCase();
	return (
		(maker.indexOf('gopro') >= 0 && camera.indexOf('max') >= 0) ||
		(maker.indexOf('dji') >= 0 && (camera.indexOf('360') >= 0 || camera.indexOf('oq') >= 0)) ||
		maker === 'arashi vision'
	);
}

// "360" on its own (not in "IMG_1360.JPG"), "pano", "vr180", the raw files and the .36p photos. The Dart pattern has
// a lookbehind, (?<![0-9])360; here the start of the name or a character that is no digit comes before.
const PANORAMA_NAME = /(?:^|[^0-9])360(?![0-9])|pano|vr180|\.(ins[pv]|osv|36p)$/i;
// "3d" on its own (not in "IMG_3D41.JPG") and the VR180 words
const STEREO_NAME = /(?:^|[^a-z0-9])3d(?![a-z0-9])|vr180|180x180/i;

const isAbout = (ratio: number, target: number) => Math.abs(ratio / target - 1) <= 0.02;

/**
 * Whether a photo or video may be 360°, so that a closer look is worth it: a 2:1 frame within 2%, a name that says so,
 * or a square or 1:2 frame with a name that tells 3D or VR180.
 */
export function isPanoramaCandidate(name: string, width: number | null | undefined, height: number | null | undefined): boolean {
	if (PANORAMA_NAME.test(name)) return true;
	if (!width || !height || width <= 0 || height <= 0) return false;
	const ratio = width / height;
	if (isAbout(ratio, 2)) return true;
	return (isAbout(ratio, 1) || isAbout(ratio, 0.5)) && STEREO_NAME.test(name);
}

/** The projection type the server flags 360° media with, from the exif or the timeline, in any case */
export const isEquirectangularProjection = (projectionType: string | null | undefined): boolean =>
	!!projectionType && projectionType.toLowerCase() === 'equirectangular';

/**
 * Whether the viewer shows an asset as 360°, as isEquirectangularProvider does on the phones: the server flags it, or
 * the user chose so, or it is a photo a 360° camera stitched itself. Never a raw file of a 360° camera. The Insta360
 * make alone does not count for a photo from the server (a raw .insp renamed .jpg has it too, and only its trailer,
 * which the server does not keep, tells them apart).
 */
export function isShownAs360(options: {
	isVideo: boolean;
	projectionType?: string | null;
	forced?: boolean;
	name?: string | null;
	make?: string | null;
	model?: string | null;
	width?: number | null;
	height?: number | null;
}): boolean {
	const {isVideo, projectionType, forced, name, make, model, width, height} = options;
	if (name && (isRawPhotoName(name) || isRawVideoName(name))) return false;
	if (forced || isEquirectangularProjection(projectionType)) return true;
	if (isVideo || !name) return false;
	if (isEquirectCameraPhoto({name})) return true;
	if ((make ?? '').trim().toLowerCase() === 'arashi vision') return false;
	return isEquirectCameraPhoto({name, make, model, width, height});
}

// ---------------------------------------------------------------------------------------------------------------
// GPano

/** The view a panorama asks to open on, in degrees; the centre of the image points to poseHeading */
export interface GPanoInitialView {
	heading: number;
	pitch: number;
	poseHeading: number;
}

export interface GPanoTags {
	projectionType: string | null;
	crop: Rect | null;
	initialView: GPanoInitialView | null;
}

// Value of a GPano tag, written as an attribute (GPano:Name="1.5") or as an element (<GPano:Name>1.5</GPano:Name>)
function gpanoTag(xmp: string, name: string): number | null {
	const match = new RegExp('GPano:' + name + '(?:\\s*=\\s*["\']|>)\\s*([-+]?(?:\\d+\\.?\\d*|\\.\\d+))').exec(xmp);
	if (!match) return null;
	const value = parseFloat(match[1]!);
	return isFinite(value) ? value : null;
}

/** The GPano crop: which part of the full sphere the image covers, in fractions */
export function parseGPanoCrop(xmp: string): Rect | null {
	const fullWidth = gpanoTag(xmp, 'FullPanoWidthPixels');
	const fullHeight = gpanoTag(xmp, 'FullPanoHeightPixels');
	const left = gpanoTag(xmp, 'CroppedAreaLeftPixels');
	const top = gpanoTag(xmp, 'CroppedAreaTopPixels');
	const width = gpanoTag(xmp, 'CroppedAreaImageWidthPixels');
	const height = gpanoTag(xmp, 'CroppedAreaImageHeightPixels');
	if (fullWidth === null || fullHeight === null || left === null || top === null || width === null || height === null) return null;
	if (fullWidth <= 0 || fullHeight <= 0) return null;
	return rect(left / fullWidth, top / fullHeight, width / fullWidth, height / fullHeight);
}

/** The initial view, only when both the heading and the pitch are set (as Photo Sphere Viewer on the web) */
export function parseGPanoInitialView(xmp: string): GPanoInitialView | null {
	const heading = gpanoTag(xmp, 'InitialViewHeadingDegrees');
	const pitch = gpanoTag(xmp, 'InitialViewPitchDegrees');
	if (heading === null || pitch === null) return null;
	return {heading, pitch, poseHeading: gpanoTag(xmp, 'PoseHeadingDegrees') ?? 0};
}

/** The GPano projection, as written: "equirectangular" for a 360° panorama */
export function parseGPanoProjectionType(xmp: string): string | null {
	const match = /GPano:ProjectionType(?:\s*=\s*["']|>)\s*([A-Za-z_-]+)/.exec(xmp);
	return match ? match[1]! : null;
}

export function parseGPanoTags(xmp: string): GPanoTags | null {
	const projectionType = parseGPanoProjectionType(xmp);
	const crop = parseGPanoCrop(xmp);
	const initialView = parseGPanoInitialView(xmp);
	if (projectionType === null && crop === null && initialView === null) return null;
	return {projectionType, crop, initialView};
}

/** Length of the windows at the head and at the tail of a file where the GPano XMP is looked for */
export const GPANO_WINDOW = 131072;

// Latin-1 decoding of bytes, enough for the ASCII of the XMP tags, in slices to keep the argument lists short
function latin1(bytes: Uint8Array): string {
	let text = '';
	for (let i = 0; i < bytes.length; i += 8192) {
		text += String.fromCharCode.apply(null, Array.prototype.slice.call(bytes, i, Math.min(i + 8192, bytes.length)) as number[]);
	}
	return text;
}

/**
 * Reads the GPano tags of a whole file in memory, from the same windows the phones read with ranges: its head, where
 * JPEG files carry their XMP, else its tail, where WebP previews carry it. Null when neither holds GPano tags.
 */
export function readGPanoTags(bytes: Uint8Array): GPanoTags | null {
	const head = parseGPanoTags(latin1(bytes.subarray(0, Math.min(GPANO_WINDOW, bytes.length))));
	if (head) return head;
	if (bytes.length <= GPANO_WINDOW) return null;
	return parseGPanoTags(latin1(bytes.subarray(bytes.length - GPANO_WINDOW)));
}

/**
 * Where the viewer looks first for a GPano initial view, as its longitude and latitude in degrees: the longitude is
 * how far clockwise the initial heading is from the pose heading, the centre of the image.
 */
export function initialViewDirection(view: GPanoInitialView): {longitude: number; latitude: number} {
	const longitude = ((((view.heading - view.poseHeading + 180) % 360) + 360) % 360) - 180;
	return {longitude, latitude: Math.max(-90, Math.min(90, view.pitch))};
}

// ---------------------------------------------------------------------------------------------------------------
// Remote control of the sphere

/**
 * Degrees per second the view turns once an arrow has been held for heldSeconds, at a field of view of fieldOfView
 * degrees: a short press nudges, holding speeds up to a third of a turn per second, a zoomed in view turns slower.
 */
export function remoteTurnSpeed(heldSeconds: number, fieldOfView: number): number {
	return (Math.min(40 + 160 * Math.max(heldSeconds, 0), 120) * fieldOfView) / 90;
}

/** Up and down turn the view a little slower than left and right */
export const REMOTE_PITCH_FACTOR = 0.75;

/** The field of view the viewer opens with, and its bounds, in degrees (vertical), as the photo sphere of the phones */
export const DEFAULT_FIELD_OF_VIEW = 90;
export const MIN_FIELD_OF_VIEW = 15;
export const MAX_FIELD_OF_VIEW = 115;

/** One step of the zoom buttons and of the channel keys */
export const ZOOM_STEP = 1.25;

/** The field of view after one zoom step in (true) or out, within the bounds */
export function zoomFieldOfView(fieldOfView: number, zoomIn: boolean): number {
	const next = zoomIn ? fieldOfView / ZOOM_STEP : fieldOfView * ZOOM_STEP;
	return Math.max(MIN_FIELD_OF_VIEW, Math.min(MAX_FIELD_OF_VIEW, next));
}
