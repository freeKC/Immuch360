'use strict';
/* global Buffer */
// H.264 over RTP (RFC 6184): single NAL units, STAP-A and FU-A, gathered into access units by RTP timestamp; and what
// the sequence parameter set tells (picture size, the codec string MSE asks for). Core JavaScript, no BigInt.

/** Gathers the RTP packets of one H.264 stream into access units: onAccessUnit({ts, nals}) */
class Depacketizer {
	constructor(onAccessUnit) {
		this.nals = [];
		this.ts = null;
		this.fu = null;
		this.lastSeq = null;
		this.lost = 0;
		this.onAccessUnit = onAccessUnit;
	}

	flush() {
		if (this.nals.length) this.onAccessUnit({ts: this.ts, nals: this.nals});
		this.nals = [];
	}

	push(packet) {
		if (packet.length < 12 || (packet[0] & 0xc0) !== 0x80) return;
		const cc = packet[0] & 0x0f;
		const extension = packet[0] & 0x10;
		const padding = packet[0] & 0x20;
		const marker = packet[1] & 0x80;
		const seq = packet.readUInt16BE(2);
		const ts = packet.readUInt32BE(4);
		if (this.lastSeq !== null && ((this.lastSeq + 1) & 0xffff) !== seq) {
			this.lost++;
			this.fu = null;
		}
		this.lastSeq = seq;
		let offset = 12 + cc * 4;
		if (extension) {
			if (offset + 4 > packet.length) return;
			offset += 4 + packet.readUInt16BE(offset + 2) * 4;
		}
		let end = packet.length;
		if (padding) end -= packet[end - 1];
		if (offset >= end) return;
		const payload = packet.slice(offset, end);
		if (this.ts !== null && ts !== this.ts) this.flush();
		this.ts = ts;
		const type = payload[0] & 0x1f;
		if (type >= 1 && type <= 23) {
			this.nals.push(payload);
		} else if (type === 24) {
			let i = 1;
			while (i + 2 <= payload.length) {
				const size = payload.readUInt16BE(i);
				if (size === 0 || i + 2 + size > payload.length) break;
				this.nals.push(payload.slice(i + 2, i + 2 + size));
				i += 2 + size;
			}
		} else if (type === 28 && payload.length > 2) {
			const start = payload[1] & 0x80;
			const stop = payload[1] & 0x40;
			if (start) this.fu = [Buffer.from([(payload[0] & 0xe0) | (payload[1] & 0x1f)]), payload.slice(2)];
			else if (this.fu) this.fu.push(payload.slice(2));
			if (stop && this.fu) {
				this.nals.push(Buffer.concat(this.fu));
				this.fu = null;
			}
		}
		if (marker) this.flush();
	}
}

function nalType(nal) {
	return nal[0] & 0x1f;
}

/** The bits of an SPS without its emulation prevention bytes */
function rbsp(nal) {
	const out = [];
	for (let i = 0; i < nal.length; i++) {
		if (i > 2 && nal[i] === 3 && nal[i - 1] === 0 && nal[i - 2] === 0) continue;
		out.push(nal[i]);
	}
	return out;
}

/** The picture size an SPS describes (ITU-T H.264 7.3.2.1.1): {width, height} */
function spsSize(sps) {
	const b = rbsp(sps);
	let bit = 8;
	const u = (n) => {
		let v = 0;
		for (let i = 0; i < n; i++, bit++) v = v * 2 + ((b[bit >> 3] >> (7 - (bit & 7))) & 1);
		return v;
	};
	const ue = () => {
		let zeros = 0;
		while (u(1) === 0 && zeros < 32) zeros++;
		return Math.pow(2, zeros) - 1 + u(zeros);
	};
	const se = () => {
		const v = ue();
		return v & 1 ? (v + 1) / 2 : -(v / 2);
	};
	const profile = u(8);
	u(16);
	ue();
	let chroma = 1;
	if ([100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].indexOf(profile) >= 0) {
		chroma = ue();
		if (chroma === 3) u(1);
		ue();
		ue();
		u(1);
		if (u(1)) {
			for (let i = 0; i < (chroma !== 3 ? 8 : 12); i++) {
				if (u(1)) {
					let last = 8;
					let next = 8;
					for (let j = 0; j < (i < 6 ? 16 : 64); j++) {
						if (next !== 0) next = (last + se() + 256) % 256;
						last = next === 0 ? last : next;
					}
				}
			}
		}
	}
	ue();
	const pocType = ue();
	if (pocType === 0) ue();
	else if (pocType === 1) {
		u(1);
		se();
		se();
		const n = ue();
		for (let i = 0; i < n; i++) se();
	}
	ue();
	u(1);
	const widthMbs = ue() + 1;
	const heightUnits = ue() + 1;
	const frameMbsOnly = u(1);
	if (!frameMbsOnly) u(1);
	u(1);
	let left = 0;
	let right = 0;
	let top = 0;
	let bottom = 0;
	if (u(1)) {
		left = ue();
		right = ue();
		top = ue();
		bottom = ue();
	}
	const cropX = chroma === 0 ? 1 : 2;
	const cropY = (chroma === 1 ? 2 : 1) * (2 - frameMbsOnly);
	return {width: widthMbs * 16 - (left + right) * cropX, height: (2 - frameMbsOnly) * heightUnits * 16 - (top + bottom) * cropY};
}

function hex2(n) {
	return (n < 16 ? '0' : '') + n.toString(16);
}

/** The codec string of an SPS for MediaSource.isTypeSupported and addSourceBuffer: avc1.PPCCLL */
function codecString(sps) {
	return 'avc1.' + hex2(sps[1]) + hex2(sps[2]) + hex2(sps[3]);
}

module.exports = {Depacketizer, nalType, spsSize, codecString};
