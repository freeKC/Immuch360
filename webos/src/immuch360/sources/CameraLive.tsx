// Immuch360: the live view of a Tapo camera on the TV. The bridge pulls the camera's RTSP stream and sends it as
// fragmented MP4 (a remux, the TV's hardware decodes); the page appends it to a Media Source. Where MSE refuses the
// stream, the TV's own player reads the bridge's HLS playlist instead, a few seconds behind. Video only for now: the
// cameras' G.711 sound does not play in MSE.

import React, {useCallback, useEffect, useRef, useState} from 'react';
import Button from '@enact/sandstone/Button';
import Spotlight from '@enact/spotlight';
import {useWebOSKeys} from '../../hooks/useWebOSKeys';
import {createSpotlightContainer} from '../../utils/spotlight';
import {t} from '../i18n';
import {bridgeUrl} from './bridgeClient';
import {catchUpTo, concat, mseType, trimRange} from './liveMse';
import {sourceErrorText} from './messages';
import {ChoiceButton} from './SourceTile';
import type {BridgeInfo, SourceConfig} from './types';
import css from './sources.module.less';

const LIVE_ID = 'camera-live';
const Container = createSpotlightContainer({enterTo: 'last-focused'});

type Quality = 'hd' | 'sd';
type State = {kind: 'connecting'} | {kind: 'playing'; via: 'mse' | 'hls'} | {kind: 'failed'; text: string};

interface CameraLiveProps {
	info: BridgeInfo;
	source: SourceConfig;
	onClose: () => void;
}

async function readError(response: Response, source: SourceConfig): Promise<string> {
	try {
		const body = (await response.json()) as {error?: string; code?: string};
		return sourceErrorText({message: body.error || `HTTP ${response.status}`, code: body.code || null}, 'tapo', source.host);
	} catch {
		return sourceErrorText({message: `HTTP ${response.status}`}, 'tapo', source.host);
	}
}

export const CameraLive: React.FC<CameraLiveProps> = ({info, source, onClose}) => {
	const videoRef = useRef<HTMLVideoElement>(null);
	const [quality, setQuality] = useState<Quality>('hd');
	const [attempt, setAttempt] = useState(0);
	// The state of one run (a quality, an attempt); a run that has said nothing yet is connecting
	const run = `${quality}:${attempt}`;
	const [reported, setReported] = useState<{run: string; state: State} | null>(null);
	const state: State = reported && reported.run === run ? reported.state : {kind: 'connecting'};
	useWebOSKeys({onBack: onClose});

	useEffect(() => {
		const raf = requestAnimationFrame(() => Spotlight.focus(LIVE_ID));
		return () => cancelAnimationFrame(raf);
	}, []);

	useEffect(() => {
		const video = videoRef.current;
		if (!video) return undefined;
		let stopped = false;
		const controller = typeof AbortController === 'undefined' ? null : new AbortController();
		const base = `live/${encodeURIComponent(source.id)}/${quality}`;
		const setState = (next: State) => setReported({run, state: next});

		const playHls = () => {
			if (stopped) return;
			video.src = bridgeUrl(info, `${base}/index.m3u8`);
			video.play().catch(() => undefined);
			setState({kind: 'playing', via: 'hls'});
		};

		const playMse = async () => {
			const MediaSourceClass = (window as {MediaSource?: typeof MediaSource}).MediaSource;
			const response = await fetch(bridgeUrl(info, `${base}/stream.mp4`), controller ? {signal: controller.signal} : undefined);
			if (!response.ok) {
				const text = await readError(response, source);
				if (!stopped) setState({kind: 'failed', text});
				return;
			}
			const type = mseType(response.headers.get('X-Immuch-Codec'));
			if (!MediaSourceClass || !MediaSourceClass.isTypeSupported(type) || !response.body) {
				controller?.abort();
				playHls();
				return;
			}
			const mediaSource = new MediaSourceClass();
			video.src = URL.createObjectURL(mediaSource);
			await new Promise<void>((resolve) => mediaSource.addEventListener('sourceopen', () => resolve(), {once: true}));
			if (stopped) return;
			const buffer = mediaSource.addSourceBuffer(type);
			const queue: Uint8Array[] = [];
			const pump = () => {
				if (stopped || buffer.updating || !queue.length || mediaSource.readyState !== 'open') return;
				const chunk = concat(queue.splice(0, queue.length));
				try {
					buffer.appendBuffer(chunk as BufferSource);
				} catch {
					// The buffer is full: drop what is behind the picture and try again
					if (buffer.buffered.length) buffer.remove(0, Math.max(0, video.currentTime - 2));
					queue.unshift(chunk);
				}
			};
			buffer.addEventListener('updateend', () => {
				if (stopped) return;
				if (buffer.buffered.length) {
					const end = buffer.buffered.end(buffer.buffered.length - 1);
					const seek = catchUpTo(end, video.currentTime);
					if (seek !== null) video.currentTime = seek;
					const drop = trimRange(buffer.buffered.start(0), video.currentTime);
					if (drop && !buffer.updating) {
						buffer.remove(drop[0], drop[1]);
						return;
					}
					if (video.paused) video.play().catch(() => undefined);
				}
				pump();
			});
			setState({kind: 'playing', via: 'mse'});
			const reader = response.body.getReader();
			for (;;) {
				const {done, value} = await reader.read();
				if (done || stopped) break;
				if (value) queue.push(value);
				pump();
			}
			if (!stopped) setState({kind: 'failed', text: t('camera_live_failed', {error: t('camera_error_unreachable', {host: source.host || ''})})});
		};

		playMse().catch((error: unknown) => {
			if (stopped) return;
			if (error instanceof Error && error.name === 'AbortError') return;
			// MSE did not take the stream: the TV's own player reads the HLS playlist
			playHls();
		});
		const onVideoError = () => {
			if (!stopped && video.error) setState({kind: 'failed', text: t('camera_live_failed', {error: `media error ${video.error.code}`})});
		};
		video.addEventListener('error', onVideoError);
		return () => {
			stopped = true;
			controller?.abort();
			video.removeEventListener('error', onVideoError);
			const src = video.src;
			video.removeAttribute('src');
			video.load();
			if (src.startsWith('blob:')) URL.revokeObjectURL(src);
		};
	}, [info, source, quality, run]);

	const retry = useCallback(() => setAttempt((n) => n + 1), []);
	const chooseQuality = useCallback((value: string) => setQuality(value === 'sd' ? 'sd' : 'hd'), []);

	let statusText = '';
	if (state.kind === 'connecting') statusText = t('camera_live_connecting');
	else if (state.kind === 'failed') statusText = state.text;
	else statusText = t('camera_live_no_sound');

	return (
		<Container spotlightId={LIVE_ID} spotlightRestrict="self-only" className={css.live}>
			<video ref={videoRef} className={css.liveVideo} muted autoPlay playsInline />
			<div className={css.liveBar}>
				<div className={css.liveTitle}>{source.name}</div>
				<div className={css.liveStatus}>{statusText}</div>
				<div className={css.row}>
					<ChoiceButton value="hd" selected={quality === 'hd'} onSelect={chooseQuality}>
						{t('camera_live_hd')}
					</ChoiceButton>
					<ChoiceButton value="sd" selected={quality === 'sd'} onSelect={chooseQuality}>
						{t('camera_live_sd')}
					</ChoiceButton>
					{state.kind === 'failed' && (
						<Button size="small" onClick={retry}>
							{t('retry')}
						</Button>
					)}
					<Button size="small" icon="closex" onClick={onClose}>
						{t('close')}
					</Button>
				</div>
			</div>
		</Container>
	);
};
