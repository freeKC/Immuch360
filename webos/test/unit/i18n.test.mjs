// The ICU reader and the locale matching of src/immuch360/i18n, against texts of the fork's i18n/ files.

import {test, describe} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, readdirSync} from 'node:fs';
import {formatMessage} from '../../src/immuch360/i18n/format.ts';
import {localeTag, matchLocale, pickLocale} from '../../src/immuch360/i18n/locale.ts';

const I18N = new URL('../../../i18n/', import.meta.url);
const available = readdirSync(I18N).filter((name) => name.endsWith('.json')).map((name) => name.slice(0, -5));
const en = JSON.parse(readFileSync(new URL('en.json', I18N), 'utf8'));

describe('formatMessage', () => {
	test('fills in arguments and leaves plain texts alone', () => {
		assert.equal(formatMessage('Close'), 'Close');
		assert.equal(formatMessage('Buffering {percent}%', {percent: 42}), 'Buffering 42%');
		assert.equal(formatMessage('Up to {width} x {height}', {width: 3840, height: 2160}), 'Up to 3,840 x 2,160');
		assert.equal(formatMessage('Hello {name}', {}), 'Hello {name}', 'a missing argument stays visible');
	});

	test('plurals with #, =0 and nested numbers, as Immich writes them', () => {
		assert.equal(formatMessage(en.assets_count, {count: 1}), '1 asset');
		assert.equal(formatMessage(en.assets_count, {count: 1234}), '1,234 assets');
		assert.equal(formatMessage(en.albums_count, {count: 1}), '1 Album');
		assert.equal(formatMessage(en.albums_count, {count: 12}), '12 Albums');
		assert.equal(formatMessage(en.map_assets_in_bounds, {count: 0}), 'No photos in this area');
		assert.equal(formatMessage(en.map_assets_in_bounds, {count: 3}), '3 photos');
	});

	test('plurals follow the rules of the locale', () => {
		const fr = JSON.parse(readFileSync(new URL('fr.json', I18N), 'utf8'));
		assert.match(formatMessage(fr.albums_count, {count: 0}, 'fr'), /^0 album$/i);
		assert.match(formatMessage(fr.albums_count, {count: 2}, 'fr'), /^2 albums$/i);
	});

	test('selects, quotes and broken messages', () => {
		assert.equal(formatMessage('{name, select, null {nobody} other {{name}}}', {name: null}), 'nobody');
		assert.equal(formatMessage('{name, select, null {nobody} other {{name}}}', {name: 'Ann'}), 'Ann');
		assert.equal(formatMessage("It''s '{literal}'"), "It's {literal}");
		assert.equal(formatMessage('{count, plural, one {# item'), '{count, plural, one {# item', 'returned as it is');
	});

	test('every text of en.json the app may read parses', () => {
		const flat = [];
		const walk = (object) => {
			for (const value of Object.values(object)) {
				if (typeof value === 'string') flat.push(value);
				else walk(value);
			}
		};
		walk(en);
		for (const message of flat) assert.equal(typeof formatMessage(message, {count: 2, name: 'x'}), 'string');
	});
});

describe('locale matching', () => {
	test('picks the closest locale file for the tags a TV reports', () => {
		const table = [
			['fr-FR', 'fr'], ['fr', 'fr'], ['de-CH', 'de_CH'], ['de-DE', 'de'], ['pt-BR', 'pt_BR'], ['pt-PT', 'pt'],
			['zh-CN', 'zh_Hans'], ['zh-Hans-CN', 'zh_Hans'], ['zh-TW', 'zh_Hant'], ['zh-HK', 'zh_Hant'], ['zh-Hant', 'zh_Hant'],
			['nb-NO', 'nb_NO'], ['no', 'nb_NO'], ['sr-RS', 'sr_Cyrl'], ['sr-Latn-RS', 'sr_Latn'], ['en-GB', 'en_GB'],
			['en-US', 'en'], ['ko-KR', 'ko'], ['yue-HK', 'yue_Hant'], ['es-419', 'es'],
		];
		for (const [tag, locale] of table) assert.equal(matchLocale(tag, available), locale, tag);
		assert.equal(matchLocale('xx-YY', available), null);
	});

	test('the first preferred tag with a file wins, English when none has one', () => {
		assert.equal(pickLocale(['xx', 'it-IT', 'fr'], available), 'it');
		assert.equal(pickLocale([], available), 'en');
		assert.equal(pickLocale(['xx'], available), 'en');
	});

	test('the BCP 47 tag of a file', () => {
		assert.equal(localeTag('pt_BR'), 'pt-BR');
		assert.equal(localeTag('zh_Hans'), 'zh-Hans');
		assert.equal(localeTag('fr'), 'fr');
	});
});
