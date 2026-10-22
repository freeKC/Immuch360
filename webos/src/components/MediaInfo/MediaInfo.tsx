import React from 'react';
import Icon from '@enact/sandstone/Icon';
import {formatAssetDateTime} from '../../utils/FormattingService';
import type {TimelineAsset} from '../../domain/types';
import css from './MediaInfo.module.less';

export const MediaInfo: React.FC<{asset: TimelineAsset}> = React.memo(({asset}) => {
	const {date, time} = formatAssetDateTime(asset.localDateTime);
	const place = [asset.city, asset.country].filter(Boolean).join(', ');
	// Immuch360: a file of a network share shows its name, then its date when the server gave one
	const dated = !asset.fileName || Date.parse(asset.localDateTime) > 0;
	return (
		<div className={css.info}>
			<div className={css.date}>{asset.fileName || date}</div>
			<div className={css.meta}>
				{asset.fileName ? (dated ? `${date} ${time}` : '') : time}
				{place && (
					<>
						<span className={css.separator}>•</span>
						<Icon size="tiny" className={css.pin}>
							location
						</Icon>
						{place}
					</>
				)}
			</div>
		</div>
	);
});

MediaInfo.displayName = 'MediaInfo';
