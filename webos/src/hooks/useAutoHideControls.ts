import {useCallback, useEffect, useRef, useState} from 'react';
import type {RefObject} from 'react';
import {CONTROLS_HIDE_AFTER_MS} from '../immuch360/keys';

interface UseAutoHideControlsOptions {
	enabled: boolean;
	// The controls' container: input aimed at it (focus inside, pointer over it) is activity.
	controlsRef: RefObject<HTMLElement | null>;
	hideDelayMs?: number;
	// Immuch360: the keys that bring hidden controls back; the 360° viewer keeps the arrows for turning the view
	revealKeys?: readonly string[];
}

interface AutoHideControls {
	visible: boolean;
	show: () => void;
	hide: () => void;
}

// Immuch360: 5 s, as the controls of the Flutter app on a TV (CONTROLS_HIDE_AFTER_MS)
const DEFAULT_HIDE_DELAY_MS = CONTROLS_HIDE_AFTER_MS;

// D-pad keys that summon the controls back. Left/Right are deliberately excluded so paging
// through photos stays "silent" (the chrome doesn't flash on every move). OK/Select maps to
// 'Enter' on our target webOS firmwares.
const DEFAULT_REVEAL_KEYS: readonly string[] = ['Enter', 'ArrowUp', 'ArrowDown'];

/**
 * Controls that fade out after `hideDelayMs` of inactivity. While they are shown, any key
 * pressed on them (moving between buttons included) and any pointer movement over them
 * restarts the countdown, so they never vanish under a user who is still using them.
 */
export const useAutoHideControls = ({enabled, controlsRef, hideDelayMs = DEFAULT_HIDE_DELAY_MS, revealKeys = DEFAULT_REVEAL_KEYS}: UseAutoHideControlsOptions): AutoHideControls => {
	const [visible, setVisible] = useState(true);
	const [wasEnabled, setWasEnabled] = useState(enabled);
	const timerRef = useRef<number | null>(null);
	const visibleRef = useRef(visible);

	// Reset to visible when auto-hide (re)enables (e.g. moving from a video back to a photo).
	// This adjusts state on a prop change during render — not in an effect — which is the
	// pattern react.dev/learn/you-might-not-need-an-effect prescribes and what satisfies the
	// `react-hooks/set-state-in-effect` rule (Enact CI strict). The disabled case needs no
	// state at all: it's derived in the returned value below.
	if (enabled !== wasEnabled) {
		setWasEnabled(enabled);
		if (enabled) setVisible(true);
	}

	// Mirror `visible` into a ref so the once-installed window listeners always read the
	// current value without re-subscribing. Synced in an effect — never written during render
	// (Enact CI strict forbids ref.current writes in render).
	useEffect(() => {
		visibleRef.current = visible;
	}, [visible]);

	const clearTimer = useCallback(() => {
		if (timerRef.current !== null) {
			window.clearTimeout(timerRef.current);
			timerRef.current = null;
		}
	}, []);

	const startTimer = useCallback(() => {
		clearTimer();
		timerRef.current = window.setTimeout(() => {
			setVisible(false);
		}, hideDelayMs);
	}, [clearTimer, hideDelayMs]);

	useEffect(() => {
		if (!enabled) {
			clearTimer();
			return undefined;
		}

		startTimer();

		const isOnControls = (target: EventTarget | null) => target instanceof Node && !!controlsRef.current?.contains(target);
		const REVEAL_KEYS = new Set(revealKeys);

		const handleKeyDown = (event: KeyboardEvent) => {
			if (visibleRef.current) {
				// Shown: keep them alive and let Spotlight handle the key (move focus / activate).
				if (REVEAL_KEYS.has(event.key) || isOnControls(event.target)) startTimer();
				return;
			}
			if (!REVEAL_KEYS.has(event.key)) return;
			// Hidden: summon controls and swallow the press so Spotlight doesn't act on a
			// control that is still visually hidden underneath.
			setVisible(true);
			startTimer();
			event.preventDefault();
			event.stopImmediatePropagation();
		};

		const handlePointerMove = (event: MouseEvent) => {
			if (visibleRef.current && isOnControls(event.target)) startTimer();
		};

		// Capture phase + the stopImmediatePropagation above are load-bearing: Spotlight listens
		// for keydown on window in the BUBBLE phase, so swallowing in the capture phase is what
		// stops it from activating the (hidden) focused control on a reveal press. Do not switch
		// this to the bubble phase or to stopPropagation.
		window.addEventListener('keydown', handleKeyDown, {capture: true});
		window.addEventListener('mousemove', handlePointerMove);
		return () => {
			window.removeEventListener('keydown', handleKeyDown, {capture: true});
			window.removeEventListener('mousemove', handlePointerMove);
			clearTimer();
		};
	}, [enabled, controlsRef, startTimer, clearTimer, revealKeys]);

	const show = useCallback(() => {
		setVisible(true);
		startTimer();
	}, [startTimer]);

	const hide = useCallback(() => {
		clearTimer();
		setVisible(false);
	}, [clearTimer]);

	// Derive the disabled case instead of storing it: while auto-hide is off the controls are
	// always shown, whatever internal `visible` state was left over from a previous photo.
	return {visible: enabled ? visible : true, show, hide};
};
