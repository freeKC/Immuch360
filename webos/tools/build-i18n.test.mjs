// The check of tools/build-i18n.mjs on the t() calls whose key it cannot read: such a key is not bundled, and the
// app would show the key instead of its text (the 2D/3D button did, with a key chosen by a ternary).

import {test} from 'node:test';
import assert from 'node:assert/strict';
import {tArguments, unfollowedKey} from './build-i18n.mjs';

test('reads the first argument of each t() call', () => {
	const code = `
		const a = t('photos');
		const b = t("albums", {count: 2});
		const c = t(label);
		const d = t(NAMES[view.layout]);
		const e = t(x === 'mono' ? 'panorama_stereo_mono' : 'panorama_stereo_left_right');
		const f = t(\`webos_\${name}\`);
		const g = item.t('not ours');
		export function t(key: string) {}
	`;
	assert.deepEqual(tArguments(code), [
		"'photos'",
		'"albums"',
		'label',
		'NAMES[view.layout]',
		"x === 'mono' ? 'panorama_stereo_mono' : 'panorama_stereo_left_right'",
		'`webos_${name}`',
	]);
});

test('follows quoted keys, and plain names in a file that holds its keys with i18nKey', () => {
	assert.equal(unfollowedKey("'photos'", false), null);
	assert.equal(unfollowedKey('"errors.unable_to_connect"', false), null);
	assert.equal(unfollowedKey('label', true), null);
	assert.equal(unfollowedKey('item.label', true), null);
	assert.equal(unfollowedKey('NAMES[resolved.layout]', true), null);
});

test('fails on a key chosen by an expression, or a name with no i18nKey in its file', () => {
	assert.ok(unfollowedKey("layout === 'mono' ? 'panorama_stereo_mono' : 'panorama_stereo_top_bottom'", true));
	assert.ok(unfollowedKey('`webos_${name}`', true));
	assert.ok(unfollowedKey("'webos_' + name", true));
	assert.ok(unfollowedKey('keyFor(layout)', true));
	assert.ok(unfollowedKey('label', false));
	assert.ok(unfollowedKey("'two words'", true));
});
