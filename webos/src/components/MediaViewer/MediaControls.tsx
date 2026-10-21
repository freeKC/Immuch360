import React, {useCallback} from 'react';
import Button from '@enact/sandstone/Button';
import {MediaInfo} from '../MediaInfo/MediaInfo';
import {RoundButton} from '../RoundButton';
import {createSpotlightContainer} from '../../utils/spotlight';
import type {TimelineAsset} from '../../domain/types';
import chrome from '../MediaChrome.module.less';
import css from './MediaViewer.module.less';

export const CLOSE_BUTTON_SPOTLIGHT_ID = 'media-viewer-close';
export const ACTION_BAR_SPOTLIGHT_ID = 'media-viewer-actions';

const ActionBar = createSpotlightContainer({enterTo: 'last-focused'});

// Immuch360: the buttons of the action bar of a photo are given by the viewer (zoom, 360°, 3D...), in their order
export interface ViewerAction {
	key: string;
	icon?: string;
	text?: string;
	label: string;
	onClick: () => void;
	spotlightId?: string;
}

interface MediaControlsProps {
	rootRef: React.Ref<HTMLDivElement>;
	asset: TimelineAsset;
	position: string;
	isVideo: boolean;
	controlsVisible: boolean;
	canGoPrev: boolean;
	canGoNext: boolean;
	onPrev: () => void;
	onNext: () => void;
	onClose: () => void;
	actions: ViewerAction[];
	/** A line under the date, such as the hint of the 360° viewer or why it shows a photo flat */
	notice?: string;
	onActionBarFocusChange: (focused: boolean) => void;
}

export const MediaControls: React.FC<MediaControlsProps> = React.memo(
	({rootRef, asset, position, isVideo, controlsVisible, canGoPrev, canGoNext, onPrev, onNext, onClose, actions, notice, onActionBarFocusChange}) => {
		const handleBarFocus = useCallback(() => onActionBarFocusChange(true), [onActionBarFocusChange]);
		const handleBarBlur = useCallback(
			(event: React.FocusEvent<HTMLDivElement>) => {
				if (!event.currentTarget.contains(event.relatedTarget as Node | null)) onActionBarFocusChange(false);
			},
			[onActionBarFocusChange]
		);

		return (
			<div ref={rootRef} className={controlsVisible ? chrome.chrome : `${chrome.chrome} ${chrome.hidden}`}>
				<div className={chrome.topBar}>
					{/* Video has no action bar (Down opens the transport bar), so it keeps a close button here. */}
					{isVideo && (
						<Button icon="closex" size="small" backgroundOpacity="transparent" onClick={onClose} spotlightId={CLOSE_BUTTON_SPOTLIGHT_ID} />
					)}
					<div className={css.infoColumn}>
						<MediaInfo asset={asset} />
						{notice ? <div className={css.notice}>{notice}</div> : null}
					</div>
					<span className={chrome.pill}>{position}</span>
				</div>

				{/* Pointer-only: the D-pad pages with left/right directly. */}
				{canGoPrev && (
					<Button icon="arrowlargeleft" backgroundOpacity="transparent" spotlightDisabled onClick={onPrev} className={`${css.navButton} ${css.navButtonLeft}`} />
				)}
				{canGoNext && (
					<Button icon="arrowlargeright" backgroundOpacity="transparent" spotlightDisabled onClick={onNext} className={`${css.navButton} ${css.navButtonRight}`} />
				)}

				{!isVideo && (
					<div className={chrome.bottomBar}>
						<ActionBar spotlightId={ACTION_BAR_SPOTLIGHT_ID} className={chrome.actionBar} onFocus={handleBarFocus} onBlur={handleBarBlur}>
							{actions.map((action) => (
								<RoundButton key={action.key} icon={action.icon} tooltipText={action.label} onClick={action.onClick} spotlightId={action.spotlightId}>
									{action.text}
								</RoundButton>
							))}
						</ActionBar>
					</div>
				)}
			</div>
		);
	}
);

MediaControls.displayName = 'MediaControls';
