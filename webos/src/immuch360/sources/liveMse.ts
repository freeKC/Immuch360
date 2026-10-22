// Immuch360: the rules of the live view in Media Source Extensions: what to ask MSE for, how far behind the live edge
// the picture may fall before it jumps forward, and what part of the buffer to drop so that a TV's memory holds an
// hour of live view.

/** The MSE type of the fragmented MP4 the bridge sends, from the codec string it gives (X-Immuch-Codec) */
export function mseType(codec: string | null): string {
	return `video/mp4; codecs="${codec && /^avc1\.[0-9a-f]{6}$/i.test(codec) ? codec : 'avc1.640028'}"`;
}

/** Most seconds the picture may lag behind the last frame received before it jumps to it */
export const MAX_LAG_S = 3;
/** Seconds of picture kept behind the one shown */
export const KEEP_BEHIND_S = 20;

/** Where to seek to catch up with the live edge, null when the lag is small enough */
export function catchUpTo(bufferedEnd: number, currentTime: number, maxLag = MAX_LAG_S): number | null {
	if (!(bufferedEnd > 0)) return null;
	return bufferedEnd - currentTime > maxLag ? Math.max(0, bufferedEnd - 0.5) : null;
}

/** The range of the buffer to drop, null when there is little behind the picture */
export function trimRange(bufferedStart: number, currentTime: number, keep = KEEP_BEHIND_S): [number, number] | null {
	if (currentTime - bufferedStart <= keep * 1.5) return null;
	return [bufferedStart, currentTime - keep];
}

/** Concatenates chunks for one appendBuffer */
export function concat(chunks: Uint8Array[]): Uint8Array {
	if (chunks.length === 1) return chunks[0]!;
	let size = 0;
	chunks.forEach((c) => (size += c.length));
	const out = new Uint8Array(size);
	let at = 0;
	chunks.forEach((c) => {
		out.set(c, at);
		at += c.length;
	});
	return out;
}
