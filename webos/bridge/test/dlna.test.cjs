'use strict';
/* global Buffer */
const test = require('node:test');
const assert = require('node:assert');
const dgram = require('node:dgram');
const dlna = require('../src/dlna');
const udp = require('../src/udp');
const xml = require('../src/xml');
const {startServer, fetchRaw, fetchJson, startBridge} = require('./helpers');

function description(base) {
	return (
		'<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device><deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>' +
		'<friendlyName>Salon &amp; NAS</friendlyName><UDN>uuid:1234</UDN><serviceList>' +
		'<service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><controlURL>/cm</controlURL></service>' +
		'<service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><controlURL>/ctl/ContentDir</controlURL></service>' +
		'</serviceList></device></root>'
	);
}

function didl(base, start, count) {
	const items = [];
	for (let i = start; i < start + count; i++) {
		items.push(
			`<item id="64$${i}" parentID="64" restricted="1"><dc:title>photo ${i}.jpg</dc:title><upnp:class>object.item.imageItem.photo</upnp:class>` +
				`<res size="1000" resolution="4000x3000" protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG">${base}/MediaItems/${i}.jpg?a=1&amp;b=2</res>` +
				`<res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_TN">${base}/Thumbnails/${i}.jpg</res></item>`
		);
	}
	const containers = start === 0 ? '<container id="64$C" parentID="64" childCount="2"><dc:title>2026 &lt;été&gt;</dc:title><upnp:class>object.container.storageFolder</upnp:class></container>' : '';
	const video =
		start === 0
			? `<item id="64$V"><dc:title>film</dc:title><upnp:class>object.item.videoItem</upnp:class><res size="5000" duration="0:01:02.500" protocolInfo="http-get:*:video/mp4:*">${base}/MediaItems/v.mp4</res></item>`
			: '';
	return (
		'<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">' +
		containers +
		video +
		items.join('') +
		'</DIDL-Lite>'
	);
}

const TOTAL = 650;

function dlnaServer() {
	const holder = {};
	return startServer((req, res) => {
		const base = holder.server.url;
		if (req.url === '/desc.xml') {
			res.writeHead(200, {'Content-Type': 'text/xml'});
			res.end(description(base));
			return;
		}
		if (req.url === '/ctl/ContentDir' && req.method === 'POST') {
			assert.strictEqual(req.headers.soapaction, '"urn:schemas-upnp-org:service:ContentDirectory:1#Browse"');
			const start = Number(/<StartingIndex>(\d+)/.exec(req.body)[1]);
			const id = xml.decodeEntities(/<ObjectID>([^<]*)/.exec(req.body)[1]);
			holder.ids = (holder.ids || []).concat([id]);
			// The container and the video take the first two places of the first page
			const itemStart = start === 0 ? 0 : start - 2;
			const count = Math.min(start === 0 ? 498 : 500, TOTAL - itemStart);
			const result = didl(base, itemStart, count);
			const returned = count + (start === 0 ? 2 : 0);
			res.writeHead(200, {'Content-Type': 'text/xml'});
			res.end(
				'<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">' +
					`<Result>${xml.escapeXml(result)}</Result><NumberReturned>${returned}</NumberReturned><TotalMatches>${TOTAL + 2}</TotalMatches><UpdateID>1</UpdateID></u:BrowseResponse></s:Body></s:Envelope>`
			);
			return;
		}
		if (req.url.indexOf('/MediaItems/') === 0) {
			res.writeHead(206, {'Content-Type': 'image/jpeg', 'Content-Range': 'bytes 0-3/10', 'Content-Length': 4});
			res.end('abcd');
			return;
		}
		res.writeHead(404);
		res.end();
	}).then((server) => {
		holder.server = server;
		server.holder = holder;
		return server;
	});
}

test('the description gives the name and the ContentDirectory control URL', () => {
	const parsed = dlna.parseDescription(description('http://x'), 'http://10.0.0.5:8200/rootDesc.xml');
	assert.deepStrictEqual(parsed, {name: 'Salon & NAS', udn: 'uuid:1234', control: 'http://10.0.0.5:8200/ctl/ContentDir'});
	assert.strictEqual(dlna.parseDescription('<root><device/></root>', 'http://x/'), null);
});

test('DIDL-Lite gives containers, items, the original and the thumbnail', () => {
	const parsed = dlna.parseDidl(didl('http://h', 0, 1));
	assert.deepStrictEqual(parsed.folders, [{ref: '64$C', name: '2026 <été>'}]);
	assert.strictEqual(parsed.files.length, 2);
	const [video, photo] = parsed.files;
	assert.strictEqual(video.kind, 'video');
	assert.strictEqual(video.duration, 62.5);
	assert.strictEqual(photo.kind, 'image');
	assert.strictEqual(photo.ref, 'http://h/MediaItems/0.jpg?a=1&b=2');
	assert.strictEqual(photo.thumb, 'http://h/Thumbnails/0.jpg');
	assert.strictEqual(photo.width, 4000);
	assert.strictEqual(dlna.parseDuration('1:00:00'), 3600);
});

test('the bridge browses every page of a container and only reads media of that server', async (t) => {
	const server = await dlnaServer();
	const b = await startBridge([{id: 'tv', kind: 'dlna', location: server.url + '/desc.xml'}]);
	t.after(() => {
		b.stop();
		return server.close();
	});
	const listing = await fetchJson(`${b.base}/list?s=tv&r=${encodeURIComponent('64$1&<x>')}`);
	assert.strictEqual(listing.status, 200);
	assert.strictEqual(listing.json.folders.length, 1);
	assert.strictEqual(listing.json.files.length, TOTAL + 1);
	assert.deepStrictEqual(server.holder.ids, ['64$1&<x>', '64$1&<x>']);
	const media = await fetchRaw(`${b.base}/file?s=tv&r=${encodeURIComponent(server.url + '/MediaItems/1.jpg')}`, {headers: {Range: 'bytes=0-3'}});
	assert.strictEqual(media.status, 206);
	assert.strictEqual(media.body.toString(), 'abcd');
	const elsewhere = await fetchJson(`${b.base}/file?s=tv&r=${encodeURIComponent('http://192.0.2.1/secret')}`);
	assert.strictEqual(elsewhere.status, 403);
});

test('a UDP search gathers the answers of the group sends', async (t) => {
	const responder = dgram.createSocket('udp4');
	await new Promise((resolve) => responder.bind(0, '127.0.0.1', resolve));
	const port = responder.address().port;
	responder.on('message', (msg, rinfo) => {
		assert.match(msg.toString(), /^M-SEARCH \* HTTP\/1.1/);
		const answer = Buffer.from('HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.1:1/desc.xml\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n');
		responder.send(answer, 0, answer.length, rinfo.port, rinfo.address);
	});
	t.after(() => responder.close());
	const answers = await udp.search('M-SEARCH * HTTP/1.1\r\n\r\n', port, 300, {groups: ['127.0.0.1'], sweep: false, repeatAt: []});
	assert.strictEqual(answers.length, 1);
	assert.strictEqual(udp.parseHeaders(answers[0].text).headers.location, 'http://127.0.0.1:1/desc.xml');
	assert.strictEqual(udp.sweepTargets(['192.168.1.20']).length, 253);
});
