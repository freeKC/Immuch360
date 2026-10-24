// Immuch360: what the diagnostics page reports about the TV, the app and the server, to paste into a bug report.
// The first checks of a real LG TV listed in the webOS analysis of 21 October 2026: the model and webOS version, the
// Chromium engine, WebGL 1 and 2 and MAX_TEXTURE_SIZE, whether video frames reach WebGL (the 360° videos), and what
// the video decoders take. On a Samsung TV the same page reads the TV through tizen and webapis (src/platform/tizen.ts)
// and adds what a real TV must answer first (Tizen design notes of 23 October 2026, section 7). On both: the JS memory
// and the last errors and policy blocks (errorLog.ts).

import LS2Request from '@enact/webos/LS2Request';
import type {PhotoRepository} from '../../domain/PhotoRepository';
import {currentLocale, localeLoadError, t} from '../i18n';
import {SphereRenderer, getWebGL, webglInfo} from '../sphere/SphereRenderer';
import {platform} from '../../platform/detect';
import {features} from '../../platform/features';
import {probeSmartView, tizenAppInfo, tizenInfo, type TizenInfo} from '../../platform/tizen';
import {decoderCeiling, decoderVerdict, largestDecoded, type DecoderRecord} from '../video/decoders';
import {knownVideoFrames, recordVideoFrames, sessionDecoders, type VideoFramesVerdict} from '../video/session';
import {lastErrors} from './errorLog';
// The clip of the video test goes through the bundler, which copies it into the package: enact pack copies from
// webos-meta/ only the files appinfo.json names (the icons, the splash), so the clip that sat there never reached the
// TV, and the test said "video error 4" (MEDIA_ERR_SRC_NOT_SUPPORTED, the answer to a file that is not there) on every
// TV, those that play 360° videos included. tools/check-package.mjs now checks that it is in the .ipk.
import probeClip from './probe.mp4';

export interface DiagnosticsLine {
	label: string;
	value: string;
}

/** The base this app was built on, kept in webos/UPSTREAM.md */
export const BASE_VERSION = '1.7.0';

function readLocalJson(path: string): Promise<Record<string, unknown> | null> {
	return new Promise((resolve) => {
		try {
			const request = new XMLHttpRequest();
			request.open('GET', path, true);
			request.timeout = 2000;
			request.onload = () => {
				try {
					resolve(JSON.parse(request.responseText) as Record<string, unknown>);
				} catch {
					resolve(null);
				}
			};
			request.onerror = () => resolve(null);
			request.ontimeout = () => resolve(null);
			request.send();
		} catch {
			resolve(null);
		}
	});
}

const hasLuna = () => typeof (window as {WebOSServiceBridge?: unknown}).WebOSServiceBridge === 'function';

function systemInfo(): Promise<Record<string, unknown> | null> {
	if (!hasLuna()) return Promise.resolve(null);
	return new Promise((resolve) => {
		new LS2Request().send({
			service: 'luna://com.webos.service.tv.systemproperty',
			method: 'getSystemInfo',
			parameters: {keys: ['modelName', 'firmwareVersion', 'UHD', 'sdkVersion', 'boardType']},
			timeout: 3000,
			onSuccess: (response: Record<string, unknown>) => resolve(response),
			onFailure: () => resolve(null),
			onTimeout: () => resolve(null),
		});
	});
}

// What webOS tells the page itself (PalmSystem on older engines, webOSSystem on newer ones)
function deviceInfo(): Record<string, unknown> | null {
	const w = window as {webOSSystem?: {deviceInfo?: string}; PalmSystem?: {deviceInfo?: string}};
	const raw = w.webOSSystem?.deviceInfo ?? w.PalmSystem?.deviceInfo;
	if (!raw) return null;
	try {
		return JSON.parse(raw) as Record<string, unknown>;
	} catch {
		return null;
	}
}

/**
 * The line of the largest video the TV decodes: "up to 4K on this TV" where a larger size was refused (the viewer holds
 * such videos back, src/immuch360/video/limits.ts), "at least" the largest size tested where none was, "not known"
 * without decodingInfo
 */
export function videoReachLine(record: DecoderRecord | null): DiagnosticsLine {
	const ceiling = decoderCeiling(record);
	const largest = largestDecoded(record);
	let value: string;
	if (ceiling) value = t('webos_diagnostics_videos_up_to', {size: ceiling.size});
	else if (largest) value = t('webos_diagnostics_videos_at_least', {size: largest});
	else value = t('webos_diagnostics_videos_unknown');
	return {label: t('webos_diagnostics_videos'), value};
}

// The decoder record of the session (src/immuch360/video/session.ts), asked at the start of the app: the page shows the
// answers the viewer decides with
async function decoderLines(): Promise<DiagnosticsLine[]> {
	let record: DecoderRecord = [];
	try {
		record = await sessionDecoders();
	} catch {
		// no lines but the reach, "not known"
	}
	return [videoReachLine(record)].concat(record.map((answer) => ({label: answer.probe.name, value: decoderVerdict(answer)})));
}

const yesNo = (flag: boolean | null): string => (flag === null ? '?' : flag ? 'yes' : 'no');

/** The lines of a Samsung TV that stand where webOS has its TV, webOS and Firmware lines */
export function tizenDeviceLines(info: TizenInfo, smartView: boolean | null): DiagnosticsLine[] {
	const panel = info.panel8k ? '8K' : info.uhdPanel ? 'UHD' : info.uhdPanel === false ? 'HD' : '?';
	const secure = typeof window !== 'undefined' && (window as {isSecureContext?: boolean}).isSecureContext === true;
	const subtle = typeof crypto !== 'undefined' && !!(crypto as {subtle?: unknown}).subtle;
	return [
		{label: 'TV', value: info.model ?? '?'},
		{label: t('webos_diagnostics_tizen'), value: info.tizenVersion ?? '?'},
		{label: 'Firmware', value: info.firmware ?? '?'},
		{label: 'Panel', value: `${panel}, HDR ${yesNo(info.hdr)}`},
		{label: 'AVPlay', value: info.avplay ? 'yes' : 'no'},
		{label: 'Secure context', value: `${secure ? 'yes' : 'no'}, crypto.subtle ${subtle ? 'yes' : 'no'}`},
		{label: 'Smart View', value: smartView === null ? '?' : smartView ? 'answers on port 8001' : 'no answer on port 8001'},
	];
}

/** The JS memory of the page, where the engine tells it (Chromium's performance.memory) */
export function heapLine(memory: {usedJSHeapSize?: number; jsHeapSizeLimit?: number} | undefined): string {
	if (!memory || !memory.jsHeapSizeLimit) return '?';
	const mb = (bytes: number) => Math.round(bytes / 1048576);
	return `${mb(memory.usedJSHeapSize ?? 0)} MB used of ${mb(memory.jsHeapSizeLimit)} MB`;
}

/** Everything but the video test, which takes a few seconds (probeVideoTexture) */
export async function collectDiagnostics(repository: PhotoRepository | null): Promise<DiagnosticsLine[]> {
	const onTizen = platform() === 'tizen';
	const [appinfo, system, serverVersion, smartView] = await Promise.all([
		onTizen ? Promise.resolve<Record<string, unknown> | null>(tizenAppInfo()) : readLocalJson('appinfo.json'),
		systemInfo(),
		repository ? repository.getServerVersion() : Promise.resolve(null),
		onTizen ? probeSmartView() : Promise.resolve(null),
	]);
	const device = deviceInfo();
	const gl = webglInfo();
	const engine = /Chrome\/([\d.]+)/.exec(navigator.userAgent);
	const tvLines: DiagnosticsLine[] = onTizen
		? tizenDeviceLines(tizenInfo(), smartView)
		: [
				{label: 'TV', value: [system?.modelName ?? device?.modelName, system?.UHD === 'true' || system?.UHD === true ? 'UHD' : null].filter(Boolean).join(', ') || '?'},
				{label: 'webOS', value: String(system?.sdkVersion ?? device?.platformVersion ?? '?')},
				{label: 'Firmware', value: String(system?.firmwareVersion ?? '?')},
			];
	const lines: DiagnosticsLine[] = [
		{label: 'Immuch360', value: `${String(appinfo?.version ?? '?')} (${String(appinfo?.id ?? '?')})`},
		{label: 'immich-tv-webos', value: BASE_VERSION},
		...tvLines,
		{label: 'Chromium', value: engine ? engine[1]! : '?'},
		{label: 'User agent', value: navigator.userAgent},
		{label: 'Screen', value: `${window.innerWidth} x ${window.innerHeight}, ${window.devicePixelRatio || 1} px/px, screen ${window.screen.width} x ${window.screen.height}`},
		{label: 'Language', value: `${navigator.language} → ${currentLocale()}${localeLoadError() ? ` (${localeLoadError()})` : ''}`},
		{label: 'WebGL', value: `1: ${gl.webgl1 ? 'yes' : 'no'}, 2: ${gl.webgl2 ? 'yes' : 'no'}, MAX_TEXTURE_SIZE ${gl.maxTextureSize ?? '?'}`},
		{label: 'GPU', value: gl.renderer ?? '?'},
		{label: 'WebAssembly', value: typeof WebAssembly === 'object' ? 'yes' : 'no'},
		{label: t('webos_diagnostics_heap'), value: heapLine((performance as {memory?: {usedJSHeapSize?: number; jsHeapSizeLimit?: number}}).memory)},
		{label: 'Server', value: repository ? `${repository.serverUrl()}, ${serverVersion ?? '?'}` : '?'},
	];
	const errors = lastErrors();
	const closing: DiagnosticsLine[] = [{label: t('webos_diagnostics_last_errors'), value: errors.length > 0 ? errors.join(' | ') : 'none'}];
	if (onTizen) closing.push({label: t('webos_not_on_samsung_title'), value: t('webos_not_on_samsung_body')});
	return lines.concat(await decoderLines(), closing);
}

// The names of the codes of MediaError, for the line of a clip that did not play
const MEDIA_ERRORS: Record<number, string> = {
	1: 'MEDIA_ERR_ABORTED',
	2: 'MEDIA_ERR_NETWORK',
	3: 'MEDIA_ERR_DECODE',
	4: 'MEDIA_ERR_SRC_NOT_SUPPORTED',
};

/** Why the clip did not play, as the video element says it: "video error 4 MEDIA_ERR_SRC_NOT_SUPPORTED: <message>" */
export function videoErrorReason(error: {code?: number; message?: string} | null | undefined): string {
	const code = error?.code;
	const name = code !== undefined ? MEDIA_ERRORS[code] : undefined;
	return `video error ${code ?? '?'}${name ? ` ${name}` : ''}${error?.message ? `: ${error.message}` : ''}`;
}

/**
 * Plays the app's tiny magenta video (H.264 Constrained Baseline, 256 x 128, 2 s), draws a frame of it into WebGL and
 * reads the pixel back: on TVs that show videos on a hardware plane under the page, the frame comes back black and 360°
 * videos can only play flat. A clip that does not play tests nothing: the line says so, with the reason. The verdict is
 * kept for the session (src/immuch360/video/session.ts), where the viewer reads it.
 */
export function probeVideoTexture(timeoutMs = 8000): Promise<string> {
	return new Promise((resolve) => {
		const video = document.createElement('video');
		const canvas = document.createElement('canvas');
		canvas.width = 64;
		canvas.height = 32;
		let renderer: SphereRenderer | null = null;
		let done = false;
		const finish = (result: string, verdict?: VideoFramesVerdict) => {
			if (done) return;
			done = true;
			window.clearTimeout(timer);
			video.pause();
			video.removeAttribute('src');
			video.load();
			if (video.parentNode) video.parentNode.removeChild(video);
			renderer?.dispose();
			if (verdict) recordVideoFrames(verdict);
			resolve(result);
		};
		const untested = (reason: string) => finish(t('webos_diagnostics_video_texture_untested', {reason}), 'untested');
		const timer = window.setTimeout(() => untested(`timeout, readyState ${video.readyState}`), timeoutMs);
		try {
			const gl = getWebGL(canvas);
			if (!gl) {
				finish('no WebGL');
				return;
			}
			renderer = new SphereRenderer(canvas, gl);
		} catch (error) {
			finish(error instanceof Error ? error.message : String(error));
			return;
		}
		video.muted = true;
		video.loop = true;
		video.setAttribute('playsinline', '');
		video.style.cssText = 'position:fixed;right:0;bottom:0;width:2px;height:2px;opacity:0.01;pointer-events:none';
		video.addEventListener('error', () => untested(videoErrorReason(video.error)));
		video.addEventListener('playing', () => {
			window.setTimeout(() => {
				try {
					renderer!.setFrame(video, video.videoWidth || 256, video.videoHeight || 128);
					renderer!.setSetup({eye: {left: 0, top: 0, width: 1, height: 1}, crop: {left: 0, top: 0, width: 1, height: 1}});
					renderer!.draw({yaw: 0, pitch: 0, fov: 60, sharp: false});
					const [r, g, b] = renderer!.centrePixel();
					if (r + g + b > 60) finish(`${t('webos_diagnostics_video_texture_ok')} (${r}, ${g}, ${b})`, 'yes');
					else finish(t('webos_diagnostics_video_texture_black'), 'black');
				} catch (error) {
					finish(error instanceof Error ? error.message : String(error));
				}
			}, 500);
		});
		video.src = probeClip;
		document.body.appendChild(video);
		const played = video.play() as Promise<void> | undefined;
		if (played && typeof played.catch === 'function') played.catch((error: unknown) => untested(`play: ${error instanceof Error ? error.message : String(error)}`));
	});
}

/** How long after the start of the app a Samsung TV runs the WebGL video test, once the first pages are in */
export const VIDEO_FRAMES_TEST_DELAY_MS = 4000;

/** How many times the test at the start waits for a video of the app to close before it gives up for the session */
export const VIDEO_FRAMES_TEST_TRIES = 30;

/**
 * Called once at the start of the app: asks the decoder record of the session (a few calls, no video), and on a TV whose
 * features say so (Samsung) runs the WebGL video test a few seconds later, so that the viewer knows its verdict before
 * a 360° video opens. The test plays a clip of its own: it waits while a video of the app is on screen (a TV may have
 * a single decoder for the page), and does not run when the About page already did.
 */
export function startVideoChecks(delayMs = VIDEO_FRAMES_TEST_DELAY_MS, tries = VIDEO_FRAMES_TEST_TRIES): void {
	sessionDecoders().catch(() => undefined);
	if (!features().probeVideoFramesAtStart) return;
	const attempt = (left: number) => {
		if (knownVideoFrames() !== null) return;
		if (document.querySelector('video')) {
			if (left > 1) window.setTimeout(() => attempt(left - 1), delayMs);
			return;
		}
		void probeVideoTexture();
	};
	window.setTimeout(() => attempt(tries), delayMs);
}

/** The page as text for the QR code, without the user agent (the Chromium line says the same in less room) */
export function diagnosticsText(lines: DiagnosticsLine[]): string {
	return lines
		.filter((line) => line.label !== 'User agent')
		.map((line) => `${line.label}: ${line.value}`)
		.join('\n');
}
