// Immuch360: what the viewer shows while a turn of the yellow or blue key is saved on the server, from the press until
// the turned picture takes the place of the photo (RotationController.phase is 'turning'). The photo turns on screen at
// once; the server then makes the turned picture, which can take a few seconds or more on a busy server. A small pill
// at the top of the screen, never focusable and never in the way of the keys: more presses still gather, Back still
// leaves. After a few seconds it says how long it has been waiting.
// The Flutter app shows a thin progress bar for the same wait, labelled with the same text (RotationProgressBar).

import React, {useEffect, useState} from 'react';
import {t} from '../i18n';
import css from './RotationIndicator.module.less';

/** From this many seconds the pill says how long the turn has been waiting */
export const ROTATION_WAIT_SHOWN_FROM_S = 3;

// Mounted for one wait only, so that its count starts at the press
const Working: React.FC = () => {
	const [seconds, setSeconds] = useState(0);
	useEffect(() => {
		const timer = window.setInterval(() => setSeconds((count) => count + 1), 1000);
		return () => window.clearInterval(timer);
	}, []);
	const counting = seconds >= ROTATION_WAIT_SHOWN_FROM_S;
	const text = counting ? t('rotate_saving_wait', {seconds}) : t('rotate_saving');
	// Audio Guidance reads "Saving the rotation" once; the count that follows each second is for the eyes only
	return (
		<div className={css.indicator} role="status" aria-live="polite">
			<span className={css.spinner} aria-hidden="true" />
			<span className={css.text} aria-hidden={counting ? 'true' : undefined}>
				{text}
			</span>
		</div>
	);
};

export const RotationIndicator: React.FC<{active: boolean}> = ({active}) => (active ? <Working /> : null);
