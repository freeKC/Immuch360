// Immuch360: the About page of the TV app, with what a bug report needs and a QR code of it
import React, {useCallback, useEffect, useState} from 'react';
import Scroller from '@enact/sandstone/Scroller';
import Button from '@enact/sandstone/Button';
import {QrCode} from '../../components/QrCode/QrCode';
import {useRepository} from '../../domain/RepositoryContext';
import {SpottableDiv} from '../../utils/spotlight';
import {t} from '../i18n';
import {BASE_VERSION, collectDiagnostics, diagnosticsText, probeVideoTexture, type DiagnosticsLine} from './collect';
import css from './DiagnosticsPanel.module.less';

const DiagnosticsPanel: React.FC = () => {
	const repository = useRepository();
	const [lines, setLines] = useState<DiagnosticsLine[]>([]);
	const [videoTexture, setVideoTexture] = useState<string>(t('webos_diagnostics_testing'));

	const runVideoTest = useCallback(() => {
		setVideoTexture(t('webos_diagnostics_testing'));
		void probeVideoTexture().then(setVideoTexture);
	}, []);

	useEffect(() => {
		let cancelled = false;
		void collectDiagnostics(repository).then((found) => {
			if (!cancelled) setLines(found);
		});
		runVideoTest();
		return () => {
			cancelled = true;
		};
	}, [repository, runVideoTest]);

	const all = lines.concat([{label: t('webos_diagnostics_video_texture'), value: videoTexture}]);

	return (
		<Scroller direction="vertical" scrollMode="native" verticalScrollbar="hidden" className={css.scroller}>
			<div className={css.page}>
				<div className={css.header}>
					<span className={css.title}>{t('about')}</span>
					<span className={css.subtitle}>{t('webos_diagnostics_subtitle')}</span>
				</div>
				<div className={css.columns}>
					<div className={css.table}>
						{all.map((line) => (
							<SpottableDiv key={line.label} className={css.row}>
								<span className={css.label}>{line.label}</span>
								<span className={css.value}>{line.value}</span>
							</SpottableDiv>
						))}
						<div className={css.actions}>
							<Button size="small" onClick={runVideoTest}>
								{t('retry')}
							</Button>
						</div>
						<p className={css.credit}>{t('webos_about_base', {version: BASE_VERSION})}</p>
						<p className={css.credit}>{t('webos_about_unofficial')}</p>
						<p className={css.credit}>https://github.com/freeKC/Immuch360</p>
					</div>
					{lines.length > 0 && (
						<div className={css.qrColumn}>
							<QrCode value={diagnosticsText(all)} className={css.qr} />
							<p className={css.qrHint}>{t('webos_diagnostics_qr')}</p>
						</div>
					)}
				</div>
			</div>
		</Scroller>
	);
};

export default DiagnosticsPanel;
