import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rgbAlphaToRgba, addLogicalAliases, addSelectorTwins, lowerForChromium53, findChromium53Unsupported } from './legacy-css.mjs';

test('rgb() with an alpha becomes rgba() with a numeric alpha', () => {
	assert.equal(rgbAlphaToRgba('a{color:rgb(var(--c,1,2,3),30%)}'), 'a{color:rgba(var(--c,1,2,3),0.3)}');
	assert.equal(rgbAlphaToRgba('a{color:rgb(var(--c),var(--a,40%))}'), 'a{color:rgba(var(--c),var(--a,0.4))}');
	assert.equal(rgbAlphaToRgba('a{color:rgb(1,2,3,50%)}'), 'a{color:rgba(1,2,3,0.5)}');
	assert.equal(rgbAlphaToRgba('a{box-shadow:0 1px rgb(var(--s),30%),0 2px rgb(var(--s),10%)}'), 'a{box-shadow:0 1px rgba(var(--s),0.3),0 2px rgba(var(--s),0.1)}');
});

test('rgb() without an alpha is left alone', () => {
	const css = 'a{color:rgb(var(--c,1,2,3));background:rgb(1,2,3)}';
	assert.equal(rgbAlphaToRgba(css), css);
});

test('logical margins and paddings get their -webkit- alias first', () => {
	assert.equal(addLogicalAliases('a{margin-inline-start:1px}'), 'a{-webkit-margin-start:1px;margin-inline-start:1px}');
	assert.equal(addLogicalAliases('a{color:red;padding-block-end:0!important}'), 'a{color:red;-webkit-padding-after:0!important;padding-block-end:0!important}');
	assert.equal(addLogicalAliases('a{--margin-inline-start:1px}'), 'a{--margin-inline-start:1px}');
});

test('::placeholder and :focus-within rules get one Chromium 53 twin right after them', () => {
	assert.equal(addSelectorTwins('.i::placeholder{color:red}'), '.i::placeholder{color:red}.i::-webkit-input-placeholder{color:red}');
	assert.equal(addSelectorTwins('@media (x){.f:focus-within .b{c:d}}'), '@media (x){.f:focus-within .b{c:d}.f.focus-within .b{c:d}}');
	assert.equal(addSelectorTwins('.f:focus-within::placeholder{c:d}'), '.f:focus-within::placeholder{c:d}.f.focus-within::-webkit-input-placeholder{c:d}');
	assert.equal(addSelectorTwins('@charset "UTF-8";.i::placeholder{c:d}'), '@charset "UTF-8";.i::placeholder{c:d}.i::-webkit-input-placeholder{c:d}');
	assert.equal(addSelectorTwins('.a:focus{c:d}'), '.a:focus{c:d}');
});

test('findChromium53Unsupported reports what Chromium 53 would drop', () => {
	const css = [
		'.a{color:#0000004d}',
		'.b{color:rgb(var(--c),30%)}',
		'.c{color:rgba(1,2,3,50%)}',
		'.d{margin-inline:0}',
		'.e{inset:0}',
		'.f{width:clamp(1px,2vw,3px)}',
		'.g{position:sticky}',
		'.h:is(.x){color:red}',
	].join('');
	assert.equal(findChromium53Unsupported(css).length, 8);
});

test('findChromium53Unsupported accepts what Chromium 53 parses', () => {
	const css = [
		'#face{color:#abc;background:#aabbcc}',
		'.a{content:"#fade";background:url(x.svg#ffff)}',
		'.b{grid-template-columns:repeat(5,minmax(0,1fr));display:inline-block}',
		'.c{-webkit-margin-start:1px;margin-inline-start:1px;--padding-inline:2px}',
		'.d{color:rgba(var(--c),var(--a,1))}',
	].join('');
	assert.deepEqual(findChromium53Unsupported(css), []);
});

test('lowered Sandstone-style CSS has nothing left for Chromium 53 to drop', () => {
	const css = '.f{color:rgb(var(--c,1,2,3),30%);margin-inline-end:0}.i::placeholder{color:rgb(var(--c),var(--a,40%))}';
	assert.deepEqual(findChromium53Unsupported(lowerForChromium53(css)), []);
});
