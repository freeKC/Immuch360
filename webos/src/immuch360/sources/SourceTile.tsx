// Immuch360: a tile of the source screens: a saved source, a server found on the network, a folder, an action
import React from 'react';
import Icon from '@enact/sandstone/Icon';
import {SpottableDiv} from '../../utils/spotlight';
import css from './sources.module.less';

interface SourceTileProps {
	icon: string;
	title: string;
	secondary?: string;
	onClick: () => void;
	spotlightId?: string;
}

export const SourceTile: React.FC<SourceTileProps> = React.memo(({icon, title, secondary, onClick, spotlightId}) => (
	<SpottableDiv className={css.tile} onClick={onClick} spotlightId={spotlightId}>
		<div className={css.tileCover}>
			<Icon size="large" className={css.tileIcon}>
				{icon}
			</Icon>
		</div>
		<div className={css.tileTitle}>{title}</div>
		{secondary && <div className={css.tileSecondary}>{secondary}</div>}
	</SpottableDiv>
));

SourceTile.displayName = 'SourceTile';

/** The icon of a kind of source */
export function kindIcon(kind: string): string {
	if (kind === 'plex') return 'movies';
	if (kind === 'tapo') return 'camera';
	if (kind === 'dlna') return 'dlna';
	return 'files';
}
