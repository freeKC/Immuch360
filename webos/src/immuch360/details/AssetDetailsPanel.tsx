// Immuch360: the details of the photo or video shown, over the right of the viewer. It takes no focus: Info (or I, or
// the details button) shows and hides it, Back closes it, and it follows the item when Left and Right change it.

import React from 'react';
import type {AssetDetails, TimelineAsset} from '../../domain/types';
import {t} from '../i18n';
import {detailsRows} from './rows';
import css from './AssetDetailsPanel.module.less';

interface AssetDetailsPanelProps {
	asset: TimelineAsset;
	/** null while GET /api/assets/{id} has not answered: the date and the place show first */
	details: AssetDetails | null;
}

export const AssetDetailsPanel: React.FC<AssetDetailsPanelProps> = ({asset, details}) => (
	<div className={css.panel} dir="auto">
		<div className={css.title}>{t('details')}</div>
		{detailsRows(asset, details).map((row) => (
			<div key={row.label} className={css.row}>
				<div className={css.label}>{row.label}</div>
				<div className={css.value}>{row.value}</div>
			</div>
		))}
	</div>
);

AssetDetailsPanel.displayName = 'AssetDetailsPanel';
