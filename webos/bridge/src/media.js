'use strict';
// What a file of a share is for the TV, from its name (and the type a server gives): a photo it shows, a video it
// plays, a photo it cannot decode (HEIC), or nothing it lists.

const IMAGE = {jpg: 'image/jpeg', jpeg: 'image/jpeg', jpe: 'image/jpeg', png: 'image/png', gif: 'image/gif', webp: 'image/webp', bmp: 'image/bmp'};
const UNSUPPORTED_IMAGE = {heic: 'image/heic', heif: 'image/heif', avif: 'image/avif', dng: 'image/x-adobe-dng', cr2: 'image/x-canon-cr2', nef: 'image/x-nikon-nef', arw: 'image/x-sony-arw'};
const VIDEO = {
	mp4: 'video/mp4',
	m4v: 'video/mp4',
	mov: 'video/quicktime',
	mkv: 'video/x-matroska',
	webm: 'video/webm',
	avi: 'video/x-msvideo',
	ts: 'video/mp2t',
	m2ts: 'video/mp2t',
	mts: 'video/mp2t',
	'3gp': 'video/3gpp',
	mpg: 'video/mpeg',
	mpeg: 'video/mpeg',
	wmv: 'video/x-ms-wmv'
};

function extensionOf(name) {
	const dot = String(name).lastIndexOf('.');
	return dot > 0 ? String(name).slice(dot + 1).toLowerCase() : '';
}

/** {kind: 'image' | 'video' | 'unsupported' | null, mime}: null for a file the TV app does not list */
function classify(name, serverType) {
	const ext = extensionOf(name);
	if (IMAGE[ext]) return {kind: 'image', mime: IMAGE[ext]};
	if (VIDEO[ext]) return {kind: 'video', mime: VIDEO[ext]};
	if (UNSUPPORTED_IMAGE[ext]) return {kind: 'unsupported', mime: UNSUPPORTED_IMAGE[ext]};
	const type = String(serverType || '').toLowerCase();
	if (/^image\/(jpeg|png|gif|webp|bmp)/.test(type)) return {kind: 'image', mime: type.split(';')[0]};
	if (/^video\//.test(type)) return {kind: 'video', mime: type.split(';')[0]};
	if (/^image\/(heic|heif|avif)/.test(type)) return {kind: 'unsupported', mime: type.split(';')[0]};
	return {kind: null, mime: null};
}

/** The type to answer a file with when the server gives none */
function mimeOf(name) {
	return classify(name).mime || 'application/octet-stream';
}

const collator = typeof Intl !== 'undefined' && Intl.Collator ? new Intl.Collator(undefined, {numeric: true, sensitivity: 'base'}) : null;

/** Names in the order a person expects: case aside, numbers by value ("IMG_2" before "IMG_10") */
function compareNames(a, b) {
	if (collator) return collator.compare(a, b);
	const x = a.toLowerCase();
	const y = b.toLowerCase();
	return x < y ? -1 : x > y ? 1 : 0;
}

/** A folder listing as the page gets it: the folders, then the files it shows, each sorted by name */
function shapeListing(folders, files) {
	const sortedFolders = folders.slice().sort((a, b) => compareNames(a.name, b.name));
	const shown = files.filter((file) => file.kind);
	shown.sort((a, b) => compareNames(a.name, b.name));
	return {folders: sortedFolders, files: shown};
}

/** Whether a name is hidden on the server side: dot files, the Windows and macOS system folders and files */
function isHiddenName(name) {
	return /^\./.test(name) || /^(\$RECYCLE\.BIN|System Volume Information|@eaDir|#recycle|Thumbs\.db|desktop\.ini|lost\+found)$/i.test(name);
}

module.exports = {classify, mimeOf, extensionOf, compareNames, shapeListing, isHiddenName};
