// Immuch360: the tiles and choice buttons of the source screens. Each takes its value and hands it back on a click,
// so that the screens give one stable handler to a whole list (no arrow function per item).
import React, {useCallback} from 'react';
import Button from '@enact/sandstone/Button';
import Icon from '@enact/sandstone/Icon';
import {SpottableDiv} from '../../utils/spotlight';
import css from './sources.module.less';

interface SourceTileProps {
	icon: string;
	title: string;
	secondary?: string;
	value: string;
	onSelect: (value: string) => void;
	spotlightId?: string;
}

/** A saved source, a server found on the network, a folder, an action */
export const SourceTile: React.FC<SourceTileProps> = React.memo(({icon, title, secondary, value, onSelect, spotlightId}) => {
	const handleClick = useCallback(() => onSelect(value), [onSelect, value]);
	return (
		<SpottableDiv className={css.tile} onClick={handleClick} spotlightId={spotlightId}>
			<div className={css.tileCover}>
				<Icon size="large" className={css.tileIcon}>
					{icon}
				</Icon>
			</div>
			<div className={css.tileTitle}>{title}</div>
			{secondary && <div className={css.tileSecondary}>{secondary}</div>}
		</SpottableDiv>
	);
});

SourceTile.displayName = 'SourceTile';

interface ChoiceButtonProps {
	value: string;
	selected?: boolean;
	onSelect: (value: string) => void;
	children: React.ReactNode;
}

/** A small button of a choice (a share of a server, HD or SD) */
export const ChoiceButton: React.FC<ChoiceButtonProps> = React.memo(({value, selected, onSelect, children}) => {
	const handleClick = useCallback(() => onSelect(value), [onSelect, value]);
	return (
		<Button size="small" selected={selected} onClick={handleClick}>
			{children}
		</Button>
	);
});

ChoiceButton.displayName = 'ChoiceButton';

/** The icon of a kind of source */
export function kindIcon(kind: string): string {
	if (kind === 'plex') return 'movies';
	if (kind === 'tapo') return 'camera';
	if (kind === 'dlna') return 'dlna';
	return 'files';
}
