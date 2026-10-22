'use strict';
/* global Buffer */
// UDP searches of the local network, for DLNA (SSDP) and Plex (GDM): the request goes to the multicast group and by
// broadcast from one socket, and to every host of the TV's /24 from another (a TV that refuses the multicast send, or
// a router that drops broadcasts between Wi-Fi clients, still finds the servers). The answers come back to the ports
// the requests left from. IPv4 only: the services of webOS cannot always bind IPv6 (the Jellyfin app found so).

const dgram = require('dgram');
const os = require('os');

/** The IPv4 addresses of the TV on its local networks */
function localAddresses() {
	const out = [];
	const interfaces = os.networkInterfaces();
	Object.keys(interfaces).forEach((name) => {
		(interfaces[name] || []).forEach((address) => {
			if ((address.family === 'IPv4' || address.family === 4) && !address.internal) out.push(address.address);
		});
	});
	return out;
}

/** Every other host of the /24 of each address */
function sweepTargets(addresses) {
	const out = [];
	addresses.forEach((address) => {
		const parts = address.split('.');
		if (parts.length !== 4) return;
		const prefix = parts.slice(0, 3).join('.');
		for (let host = 1; host < 255; host++) {
			const target = prefix + '.' + host;
			if (target !== address && out.indexOf(target) < 0) out.push(target);
		}
	});
	return out;
}

function openSocket(onMessage) {
	return new Promise((resolve) => {
		let socket;
		try {
			socket = dgram.createSocket({type: 'udp4', reuseAddr: true});
		} catch (e) {
			resolve(null);
			return;
		}
		socket.on('message', onMessage);
		socket.on('error', () => {
			// A refused send (a TV without multicast) must not close the search
		});
		socket.bind(0, () => {
			try {
				socket.setBroadcast(true);
				socket.setMulticastTTL(2);
			} catch (e) {
				// Some stacks refuse these options; the sends still go
			}
			resolve(socket);
		});
	});
}

function sendTo(socket, message, port, host) {
	try {
		socket.send(message, 0, message.length, port, host, () => {});
	} catch (e) {
		// One refused destination does not stop the others
	}
}

/**
 * Sends message to port at the group and broadcast addresses, then to every host of the /24 (sweep), and gathers the
 * answers for ms: resolves with [{from, text}]. options: groups (addresses for the first socket), sweep (boolean),
 * repeatAt (ms of the repeats of the group sends), addresses (the TV's, for tests).
 */
function search(message, port, ms, options) {
	const opts = options || {};
	const answers = [];
	const onMessage = (data, rinfo) => answers.push({from: rinfo.address, text: data.toString('utf8')});
	const buffer = Buffer.from(message);
	return Promise.all([openSocket(onMessage), opts.sweep === false ? Promise.resolve(null) : openSocket(onMessage)]).then((sockets) => {
		const group = sockets[0];
		const sweep = sockets[1];
		const timers = [];
		const sendGroups = () => {
			if (group) (opts.groups || []).forEach((host) => sendTo(group, buffer, port, host));
		};
		sendGroups();
		(opts.repeatAt || [400, 1200]).forEach((at) => timers.push(setTimeout(sendGroups, at)));
		if (sweep) {
			const targets = sweepTargets(opts.addresses || localAddresses());
			let index = 0;
			const batch = () => {
				for (let i = 0; i < 32 && index < targets.length; i++, index++) sendTo(sweep, buffer, port, targets[index]);
				if (index < targets.length) timers.push(setTimeout(batch, 20));
			};
			timers.push(setTimeout(batch, 100));
		}
		return new Promise((resolve) => {
			setTimeout(() => {
				timers.forEach(clearTimeout);
				[group, sweep].forEach((socket) => {
					if (!socket) return;
					try {
						socket.close();
					} catch (e) {
						// Already closed
					}
				});
				resolve(answers);
			}, ms);
		});
	});
}

/** The status line and the headers of an SSDP or GDM datagram, names in lower case; lines end with CRLF or LF */
function parseHeaders(text) {
	const lines = String(text).split(/\r?\n/);
	const headers = {};
	for (let i = 1; i < lines.length; i++) {
		const line = lines[i];
		if (!line.trim()) break;
		const colon = line.indexOf(':');
		if (colon <= 0) continue;
		const name = line.slice(0, colon).trim().toLowerCase();
		if (headers[name] === undefined) headers[name] = line.slice(colon + 1).trim();
	}
	return {status: (lines[0] || '').trim(), headers: headers};
}

module.exports = {search, parseHeaders, localAddresses, sweepTargets};
