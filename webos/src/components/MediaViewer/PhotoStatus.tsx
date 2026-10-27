// Immuch360: the two pills the viewer shows over a flat photo, in the look of the pill of a turn (RotationIndicator),
// never focusable and never in the way of the keys or of the Magic Remote's pointer. PhotoLoading, in the middle of the
// screen, while the picture is fetched and decoded past 300 ms (viewerStatus.ts), so a dark photo is told from one that
// is still on its way. ZoomLevel, at the top, the zoom level for a moment after each zoom key or button.

import React, {useEffect, useState} from 'react';
import {currentLocaleTag, t} from '../../immuch360/i18n';
import {ZOOM_LEVEL_SHOWN_MS, zoomLevelText} from '../../immuch360/viewerStatus';
import css from './PhotoStatus.module.less';

export const PhotoLoading: React.FC<{active: boolean}> = ({active}) =>
	active ? (
		<div className={css.loading} role="status" aria-live="polite">
			<span className={css.spinner} aria-hidden="true" />
			<span>{t('webos_loading')}</span>
		</div>
	) : null;

/**
 * The zoom level after a zoom key or button: pulse counts the presses on the photo (usePhotoZoom); each one shows the
 * level for ZOOM_LEVEL_SHOWN_MS from that press. Mounted once per photo (keyed by its id), so its count starts at 0.
 * hidden: the pill of a turn has the place; the time still runs, so the level does not come back after the turn.
 */
export const ZoomLevel: React.FC<{pulse: number; scale: number; hidden?: boolean}> = ({pulse, scale, hidden = false}) => {
	const [endedPulse, setEndedPulse] = useState(0);
	useEffect(() => {
		if (pulse === 0) return undefined;
		const timer = window.setTimeout(() => setEndedPulse(pulse), ZOOM_LEVEL_SHOWN_MS);
		return () => window.clearTimeout(timer);
	}, [pulse]);
	if (hidden || pulse === 0 || endedPulse === pulse) return null;
	return (
		<div className={css.zoomLevel} role="status" aria-live="polite">
			{zoomLevelText(scale, currentLocaleTag())}
		</div>
	);
};
