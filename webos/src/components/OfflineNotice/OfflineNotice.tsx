// Immuch360: a notice over every page while the TV has no network connection, so that a page, the viewer or a video
// that stops loading does not read as empty or broken (LG's self assessment of 23 October 2026, item 6.5)
import React from 'react';
import Icon from '@enact/sandstone/Icon';
import {useOnline} from '../../hooks/useOnline';
import {t} from '../../immuch360/i18n';
import css from './OfflineNotice.module.less';

export const OfflineNotice: React.FC = () => {
	const online = useOnline();
	if (online) return null;
	return (
		<div className={css.notice} role="status" data-offline-notice>
			<Icon size="small" className={css.icon}>
				alert02
			</Icon>
			<span>{t('webos_offline_notice')}</span>
		</div>
	);
};

OfflineNotice.displayName = 'OfflineNotice';
