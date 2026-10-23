// Immuch360: the rules of LG's store that the files of the package can be checked against without a TV, shared by
// tools/check-package.mjs (on the .ipk) and test/unit/store-rules.test.mjs (on webos-meta/).
//
// Sources, read on 23 October 2026 (the LG Apps study of the project):
// * App Resources and the Icon guide: icon.png 80x80 and largeIcon 130x130, the same drawing, on a tile of iconColor;
//   the self checklist 5.0, sheet 2 items 6 to 8: square, not rounded, no transparency, one background colour equal to
//   the tile colour.
// * Screensaver guide: a gallery app declares "screenSaverProperties": {"preferredType": 3} and "useGalleryMode": true,
//   both at the top of appinfo.json.
// * ACG guide: requiredACG lists the ACG group of every Luna method the app and its service call (mandatory from
//   webOS 27, March 2027). The groups below are those of the calls the app makes, see LUNA_CALLS.
// * Supported App Resolution: "resolution": "1280x720" makes the package of Full HD TVs; none means 1920x1080.

/** The icons of webos-meta and the size LG asks for each */
export const ICONS = {'icon.png': 80, 'icon-large.png': 130, 'icon-mini.png': 60};

/** The colour of the app's background, of the icons' tile and of the splash */
export const TILE_COLOR = '#131313';

/**
 * Every Luna method the app and its service call, with its ACG group. The page: the TV's model on the About page; Enact
 * reads the audio guidance setting before it speaks an alert. The service: the activity that keeps it alive while the
 * phone sign in or the media bridge run. The app's calls to its own service need no group.
 */
export const LUNA_CALLS = [
	{service: 'com.webos.service.tv.systemproperty', method: 'getSystemInfo', group: 'systemconfig.query', by: 'src/immuch360/diagnostics/collect.ts'},
	{service: 'com.webos.settingsservice', method: 'getSystemSettings', group: 'settings.query', by: '@enact/webos (audio guidance)'},
	{service: 'com.palm.activitymanager', method: 'create, complete', group: 'activity.operation', by: 'service/service.js'},
];

/**
 * Luna methods the bundled Enact may call that have no group in LG's public ACG list, so none can be declared. Enact
 * handles their failure: if ACG enforcement denies them (webOS 26 lets it be tried), the app goes on.
 */
export const UNLISTED_LUNA_CALLS = [
	{service: 'com.webos.surfacemanager', method: 'getLastInputType', by: '@enact/sandstone ThemeDecorator, once at start (pointer or keys)'},
	{service: 'com.webos.service.tts', method: 'speak', by: '@enact/webos readAlert, only when the audio guidance of the TV is on'},
];

/** The app's own service, which its page calls over Luna; no ACG group is needed for it */
export const OWN_SERVICE = 'com.aprogsys.immuch360.service';

/** requiredACG as appinfo.json must hold it: the groups of LUNA_CALLS, sorted */
export const REQUIRED_ACG = Array.from(new Set(LUNA_CALLS.map((call) => call.group))).sort();

/** The Luna services the app must not call: undocumented, outside LG's ACG list */
export const FORBIDDEN_SERVICES = ['com.webos.service.tvpower'];

/** The resolutions of the two packages */
export const RESOLUTIONS = ['1920x1080', '1280x720'];

/**
 * What a PNG file says of itself: size, colour type, and whether it can hold transparency (an alpha channel, colour
 * types 4 and 6, or a tRNS chunk). Throws on a file that is not a PNG.
 */
export function pngInfo(bytes) {
	const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
	if (bytes.length < 33 || signature.some((byte, i) => bytes[i] !== byte)) throw new Error('not a PNG file');
	let offset = 8;
	let header = null;
	let hasTrns = false;
	while (offset + 8 <= bytes.length) {
		const length = bytes.readUInt32BE(offset);
		const type = bytes.toString('latin1', offset + 4, offset + 8);
		if (type === 'IHDR') {
			header = {width: bytes.readUInt32BE(offset + 8), height: bytes.readUInt32BE(offset + 12), colorType: bytes[offset + 17]};
		}
		if (type === 'tRNS') hasTrns = true;
		if (type === 'IEND') break;
		offset += 12 + length;
	}
	if (!header) throw new Error('PNG without IHDR');
	return {...header, transparent: header.colorType === 4 || header.colorType === 6 || hasTrns};
}

/** The tile colour and the icons: opaque squares of the right sizes, iconColor equal to the background */
export function iconProblems(appinfo, icons) {
	const problems = [];
	if (appinfo.iconColor !== TILE_COLOR) problems.push(`appinfo.json iconColor is ${appinfo.iconColor}, not ${TILE_COLOR}`);
	if (appinfo.bgColor && appinfo.bgColor !== appinfo.iconColor) problems.push('appinfo.json bgColor and iconColor differ');
	const names = {'icon.png': appinfo.icon, 'icon-large.png': appinfo.largeIcon, 'icon-mini.png': appinfo.miniicon};
	for (const [file, size] of Object.entries(ICONS)) {
		if (names[file] !== file) problems.push(`appinfo.json does not name ${file}`);
		const bytes = icons[file];
		if (!bytes) {
			problems.push(`missing ${file}`);
			continue;
		}
		let info;
		try {
			info = pngInfo(bytes);
		} catch (error) {
			problems.push(`${file}: ${error.message}`);
			continue;
		}
		if (info.width !== size || info.height !== size) problems.push(`${file} is ${info.width}x${info.height}, not ${size}x${size}`);
		if (info.transparent) problems.push(`${file} can hold transparency (LG wants opaque icons on a solid background)`);
	}
	return problems;
}

/** The screen saver of a gallery app: Type 3 with the gallery mode */
export function screenSaverProblems(appinfo) {
	const problems = [];
	const saver = appinfo.screenSaverProperties;
	if (!saver || saver.preferredType !== 3) problems.push('appinfo.json screenSaverProperties.preferredType is not 3');
	if (appinfo.useGalleryMode !== true) problems.push('appinfo.json useGalleryMode is not true');
	return problems;
}

/** requiredACG: exactly the groups of LUNA_CALLS */
export function acgProblems(appinfo) {
	const acg = appinfo.requiredACG;
	if (!Array.isArray(acg)) return ['appinfo.json has no requiredACG'];
	if (acg.slice().sort().join(',') !== REQUIRED_ACG.join(',')) {
		return [`appinfo.json requiredACG is ${JSON.stringify(acg)}, not ${JSON.stringify(REQUIRED_ACG)}`];
	}
	return [];
}

/** The Luna services a text (the bundle, a source file) names in luna:// addresses */
export function lunaServices(text) {
	const found = new Set();
	for (const match of text.matchAll(/luna:\/\/([A-Za-z0-9.]+)/g)) found.add(match[1]);
	return Array.from(found).sort();
}

/** Luna services named in a text that requiredACG does not cover and that are not known as unlisted */
export function unknownLunaServices(text) {
	const known = new Set([OWN_SERVICE, ...LUNA_CALLS.map((call) => call.service), ...UNLISTED_LUNA_CALLS.map((call) => call.service)]);
	return lunaServices(text).filter((service) => !known.has(service));
}

/** The resolution of a package: no field for 1920x1080, "1280x720" for the package of Full HD TVs */
export function resolutionProblems(appinfo, resolution = '1920x1080') {
	const problems = [];
	if (RESOLUTIONS.indexOf(resolution) < 0) problems.push(`unknown resolution ${resolution}`);
	const declared = appinfo.resolution ?? '1920x1080';
	if (declared !== resolution) problems.push(`appinfo.json resolution is ${declared}, not ${resolution}`);
	return problems;
}

/**
 * Every problem of an appinfo.json and of its icons against the rules above. icons: file name to bytes (those found).
 * resolution: the package's, '1920x1080' or '1280x720'.
 */
export function storeProblems(appinfo, icons, resolution = '1920x1080') {
	return [...iconProblems(appinfo, icons), ...screenSaverProblems(appinfo), ...acgProblems(appinfo), ...resolutionProblems(appinfo, resolution)];
}
