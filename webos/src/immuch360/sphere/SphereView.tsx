// Immuch360: the 360° photo viewer of the TV. The remote turns the view as the Flutter photo sphere does on Android
// TV: the arrows turn it while they are held (faster the longer, slower once zoomed in, up and down at three quarters
// of the speed), the channel keys zoom by 1.25, the Magic Remote drags it and its wheel zooms. OK and Back belong to
// the viewer around it (MediaViewer).

import React, {forwardRef, useCallback, useEffect, useImperativeHandle, useRef, useState} from 'react';
import {useRepository} from '../../domain/RepositoryContext';
import type {AssetDetails} from '../../domain/types';
import {t} from '../i18n';
import {remoteAction} from '../keys';
import {decodeFrame, sniffImageType} from './frame';
import {
	DEFAULT_FIELD_OF_VIEW,
	REMOTE_PITCH_FACTOR,
	initialViewDirection,
	leftEyeRect,
	readGPanoTags,
	remoteTurnSpeed,
	resolveSphereView,
	sphereCrop,
	zoomFieldOfView,
	type GPanoTags,
	type SphereCoverage,
	type SphereView as SphereViewChoice,
	type StereoLayout,
} from './rules';
import {SphereRenderer, TEXTURE_CAP, getWebGL} from './SphereRenderer';
import css from './SphereView.module.less';

export interface SphereViewHandle {
	zoomIn: () => void;
	zoomOut: () => void;
	/** The Magic Remote, through the stage of the viewer that lies over the canvas: drag with OK held, wheel zooms */
	dragStart: (x: number, y: number) => void;
	dragMove: (x: number, y: number) => void;
	dragEnd: () => void;
	wheel: (deltaY: number) => void;
}

interface SphereViewProps {
	assetId: string;
	/** null while it loads: the name and the size refine the guesses of the coverage and of the 3D layout */
	details: AssetDetails | null;
	chosenLayout?: StereoLayout;
	chosenCoverage?: SphereCoverage;
	/** False while the focus is on the controls: the arrows move between the buttons then */
	keysEnabled: boolean;
	/** The sphere cannot be drawn (no WebGL, a picture that does not decode): the viewer shows the photo flat */
	onFailed: (reason: string) => void;
	/** What the viewer resolved, for the 3D and coverage buttons */
	onResolved?: (view: SphereViewChoice) => void;
}

type Direction = 'left' | 'right' | 'up' | 'down';

// A held arrow whose key has not been seen for this long is let go, in case its keyup never comes
const HELD_KEY_TIMEOUT_MS = 1500;

interface Motion {
	yaw: number;
	pitch: number;
	fov: number;
	fovTarget: number;
	held: Partial<Record<Direction, {since: number; seen: number}>>;
	drag: {x: number; y: number} | null;
	last: number;
	raf: number;
}

const wrapYaw = (yaw: number) => ((((yaw + 180) % 360) + 360) % 360) - 180;

export const SphereView = forwardRef<SphereViewHandle, SphereViewProps>(
	({assetId, details, chosenLayout, chosenCoverage, keysEnabled, onFailed, onResolved}, ref) => {
		const repository = useRepository();
		const canvasRef = useRef<HTMLCanvasElement>(null);
		const rendererRef = useRef<SphereRenderer | null>(null);
		const frameRef = useRef<{width: number; height: number; gpano: GPanoTags | null} | null>(null);
		const motion = useRef<Motion>({yaw: 0, pitch: 0, fov: DEFAULT_FIELD_OF_VIEW, fovTarget: DEFAULT_FIELD_OF_VIEW, held: {}, drag: null, last: 0, raf: 0});
		const [status, setStatus] = useState<'loading' | 'ready'>('loading');
		const failedRef = useRef(onFailed);
		const resolvedRef = useRef(onResolved);
		useEffect(() => {
			failedRef.current = onFailed;
			resolvedRef.current = onResolved;
		}, [onFailed, onResolved]);

		const draw = useCallback((sharp: boolean) => {
			const renderer = rendererRef.current;
			const m = motion.current;
			if (renderer?.hasFrame()) renderer.draw({yaw: m.yaw, pitch: m.pitch, fov: m.fov, sharp});
		}, []);

		// A named function, so that the frame loop asks for its next frame without reading tick before it is declared
		const tick = useCallback(
			function step(now: number) {
				const m = motion.current;
				const dt = m.last ? Math.min(0.1, (now - m.last) / 1000) : 0;
				m.last = now;
				let moving = false;
				const clock = performance.now();
				(Object.keys(m.held) as Direction[]).forEach((direction) => {
					const key = m.held[direction];
					if (!key) return;
					if (clock - key.seen > HELD_KEY_TIMEOUT_MS) {
						delete m.held[direction];
						return;
					}
					const speed = remoteTurnSpeed((clock - key.since) / 1000, m.fov) * dt;
					if (direction === 'left') m.yaw -= speed;
					else if (direction === 'right') m.yaw += speed;
					else if (direction === 'up') m.pitch += speed * REMOTE_PITCH_FACTOR;
					else m.pitch -= speed * REMOTE_PITCH_FACTOR;
					moving = true;
				});
				if (Math.abs(m.fovTarget - m.fov) > 0.05) {
					m.fov += (m.fovTarget - m.fov) * Math.min(1, dt * 12);
					moving = true;
				} else {
					m.fov = m.fovTarget;
				}
				m.yaw = wrapYaw(m.yaw);
				m.pitch = Math.max(-90, Math.min(90, m.pitch));
				const active = moving || !!m.drag;
				draw(!active);
				if (active) {
					m.raf = requestAnimationFrame(step);
				} else {
					m.raf = 0;
					m.last = 0;
				}
			},
			[draw]
		);

		const kick = useCallback(() => {
			const m = motion.current;
			if (!m.raf) m.raf = requestAnimationFrame(tick);
		}, [tick]);

		const zoom = useCallback(
			(zoomIn: boolean) => {
				const m = motion.current;
				m.fovTarget = zoomFieldOfView(m.fovTarget, zoomIn);
				kick();
			},
			[kick]
		);

		// The canvas follows the size of the viewer, at most 1.5 device pixels per CSS pixel
		const fitCanvas = useCallback(() => {
			const canvas = canvasRef.current;
			if (!canvas) return;
			const ratio = Math.min(window.devicePixelRatio || 1, 1.5);
			const width = Math.max(1, Math.round(canvas.clientWidth * ratio));
			const height = Math.max(1, Math.round(canvas.clientHeight * ratio));
			if (canvas.width !== width || canvas.height !== height) {
				canvas.width = width;
				canvas.height = height;
			}
			draw(true);
		}, [draw]);

		useEffect(() => {
			window.addEventListener('resize', fitCanvas);
			return () => window.removeEventListener('resize', fitCanvas);
		}, [fitCanvas]);

		// The renderer lives as long as the canvas
		useEffect(() => {
			const canvas = canvasRef.current;
			if (!canvas) return undefined;
			const gl = getWebGL(canvas);
			if (!gl) {
				failedRef.current(t('webos_360_no_webgl'));
				return undefined;
			}
			try {
				rendererRef.current = new SphereRenderer(canvas, gl);
			} catch (error) {
				failedRef.current(t('webos_360_error', {reason: error instanceof Error ? error.message : String(error)}));
				return undefined;
			}
			const lost = (event: Event) => {
				event.preventDefault();
				failedRef.current(t('webos_360_error', {reason: 'WebGL context lost'}));
			};
			canvas.addEventListener('webglcontextlost', lost);
			const m = motion.current;
			return () => {
				canvas.removeEventListener('webglcontextlost', lost);
				if (m.raf) cancelAnimationFrame(m.raf);
				m.raf = 0;
				rendererRef.current?.dispose();
				rendererRef.current = null;
			};
		}, []);

		// The frame of the asset: its preview, read once for the pixels and the GPano tags
		useEffect(() => {
			const controller = typeof AbortController === 'undefined' ? null : new AbortController();
			let cancelled = false;
			setStatus('loading');
			frameRef.current = null;
			const m = motion.current;
			m.held = {};
			m.fov = m.fovTarget = DEFAULT_FIELD_OF_VIEW;
			(async () => {
				const bytes = await repository.fetchPreviewBytes(assetId, controller?.signal);
				if (cancelled) return;
				const gpano = readGPanoTags(new Uint8Array(bytes));
				const renderer = rendererRef.current;
				if (!renderer) return;
				const decoded = await decodeFrame(bytes, sniffImageType(bytes), Math.min(TEXTURE_CAP, renderer.maxTextureSize()));
				if (cancelled) {
					decoded.release();
					return;
				}
				renderer.setFrame(decoded.source, decoded.width, decoded.height);
				decoded.release();
				frameRef.current = {width: decoded.naturalWidth, height: decoded.naturalHeight, gpano};
				const initial = gpano?.initialView ? initialViewDirection(gpano.initialView) : {longitude: 0, latitude: 0};
				m.yaw = initial.longitude;
				m.pitch = initial.latitude;
				setStatus('ready');
			})().catch((error: unknown) => {
				if (!cancelled) failedRef.current(t('webos_360_error', {reason: error instanceof Error ? error.message : String(error)}));
			});
			return () => {
				cancelled = true;
				controller?.abort();
			};
		}, [assetId, repository]);

		// How the frame maps on the sphere: the name and size of the original, the GPano crop of the preview, the
		// choices of the user
		useEffect(() => {
			const frame = frameRef.current;
			const renderer = rendererRef.current;
			if (status !== 'ready' || !frame || !renderer) return;
			const crop = frame.gpano?.crop ?? null;
			const view = resolveSphereView({
				fileName: details?.originalFileName ?? null,
				width: details?.width ?? frame.width,
				height: details?.height ?? frame.height,
				gpanoCrop: crop,
				chosenLayout,
				chosenCoverage,
			});
			const eye = leftEyeRect(view.layout);
			renderer.setSetup({eye, crop: sphereCrop(view.coverage, crop)});
			resolvedRef.current?.(view);
			fitCanvas();
		}, [status, details, chosenLayout, chosenCoverage, fitCanvas]);

		// The remote: arrows held turn, channel keys zoom; in the capture phase, ahead of Spotlight
		useEffect(() => {
			if (!keysEnabled) return undefined;
			const m = motion.current;
			const onKeyDown = (event: KeyboardEvent) => {
				const action = remoteAction(event);
				if (action === 'left' || action === 'right' || action === 'up' || action === 'down') {
					const now = performance.now();
					const held = m.held[action];
					if (held) held.seen = now;
					else m.held[action] = {since: now, seen: now};
					kick();
				} else if (action === 'channelUp' || action === 'channelDown') {
					zoom(action === 'channelUp');
				} else {
					return;
				}
				event.preventDefault();
				event.stopImmediatePropagation();
			};
			const onKeyUp = (event: KeyboardEvent) => {
				const action = remoteAction(event);
				if (action === 'left' || action === 'right' || action === 'up' || action === 'down') delete m.held[action];
			};
			const release = () => {
				m.held = {};
			};
			window.addEventListener('keydown', onKeyDown, {capture: true});
			window.addEventListener('keyup', onKeyUp, {capture: true});
			window.addEventListener('blur', release);
			return () => {
				window.removeEventListener('keydown', onKeyDown, {capture: true});
				window.removeEventListener('keyup', onKeyUp, {capture: true});
				window.removeEventListener('blur', release);
				m.held = {};
			};
		}, [keysEnabled, kick, zoom]);

		// The Magic Remote: drag with OK held, the wheel zooms
		useImperativeHandle(
			ref,
			() => ({
				zoomIn: () => zoom(true),
				zoomOut: () => zoom(false),
				dragStart: (x: number, y: number) => {
					motion.current.drag = {x, y};
					kick();
				},
				dragMove: (x: number, y: number) => {
					const m = motion.current;
					const canvas = canvasRef.current;
					if (!m.drag || !canvas) return;
					const degreesPerPixel = m.fov / Math.max(1, canvas.clientHeight);
					m.yaw -= (x - m.drag.x) * degreesPerPixel;
					m.pitch += (y - m.drag.y) * degreesPerPixel;
					m.drag = {x, y};
					kick();
				},
				dragEnd: () => {
					motion.current.drag = null;
					kick();
				},
				wheel: (deltaY: number) => {
					if (deltaY) zoom(deltaY < 0);
				},
			}),
			[zoom, kick]
		);

		return (
			<div className={css.sphere}>
				<canvas ref={canvasRef} className={css.canvas} />
				{status === 'loading' && <div className={css.status}>{t('webos_360_loading')}</div>}
			</div>
		);
	}
);

SphereView.displayName = 'SphereView';
