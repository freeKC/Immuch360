'use strict';
const test = require('node:test');
const assert = require('node:assert');
const xml = require('../src/xml');

test('elements ignore namespace prefixes and match whole names only', () => {
	const doc = '<d:multistatus xmlns:d="DAV:"><d:response><d:href>/a</d:href></d:response><D:response><D:href>/b</D:href></D:response><responses/></d:multistatus>';
	assert.deepStrictEqual(xml.elements(doc, 'response').map((r) => xml.childText(r.body, 'href')), ['/a', '/b']);
	assert.strictEqual(xml.elements('<res protocolInfo="x">u</res><resolution>1</resolution>', 'res').length, 1);
});

test('entities, numeric references and CDATA are decoded', () => {
	assert.strictEqual(xml.decodeEntities('a &amp; b &lt;c&gt; &#233;t&#xE9; &quot;q&quot; &apos;'), 'a & b <c> été "q" \'');
	assert.strictEqual(xml.childText('<t><![CDATA[a < b & c]]></t>', 't'), 'a < b & c');
	assert.strictEqual(xml.decodeEntities('&#0; &bogus;'), '&#0; &bogus;');
});

test('attributes are read with either quote and decoded', () => {
	assert.strictEqual(xml.attribute(' id="64$1" parentID=\'0\' title="a &amp; b"', 'id'), '64$1');
	assert.strictEqual(xml.attribute(' id="64$1" parentID=\'0\'', 'parentID'), '0');
	assert.strictEqual(xml.attribute(' title="a &amp; b"', 'title'), 'a & b');
	assert.strictEqual(xml.attribute(' title="x"', 'id'), null);
});

test('escapeXml makes text safe in a body', () => {
	assert.strictEqual(xml.escapeXml('64$1&<"\'>'), '64$1&amp;&lt;&quot;&apos;&gt;');
});
