// Immuch360: the About page of the TV app, with what a bug report needs and a QR code of it
import React, {useCallback, useEffect, useState} from 'react';
import Scroller from '@enact/sandstone/Scroller';
import Button from '@enact/sandstone/Button';
import Dropdown from '@enact/sandstone/Dropdown';
import {QrCode} from '../../components/QrCode/QrCode';
import {privacyPolicyUrl, PrivacyPolicyButton} from '../privacy/PrivacyPolicy';
import {isTizen} from '../../platform/detect';
import {useRepository} from '../../domain/RepositoryContext';
import {SpottableDiv} from '../../utils/spotlight';
import {availableLocales, chosenLocale, localeName, setChosenLocale, t} from '../i18n';
import {BASE_VERSION, collectDiagnostics, diagnosticsText, probeVideoTexture, type DiagnosticsLine} from './collect';
import css from './DiagnosticsPanel.module.less';

// The Language choice: the TV's language first, then each locale by its own name. A choice restarts the page, so that
// every text, date and number is read again in it.
const LOCALES = availableLocales();

const handleLanguage = ({selected}: {selected: number}) => {
	const locale = selected > 0 ? LOCALES[selected - 1] ?? null : null;
	if (locale === chosenLocale()) return;
	setChosenLocale(locale);
	window.location.reload();
};

const DiagnosticsPanel: React.FC = () => {
	const repository = useRepository();
	const [lines, setLines] = useState<DiagnosticsLine[]>([]);
	const [videoTexture, setVideoTexture] = useState<string>(t('webos_diagnostics_testing'));

	const runVideoTest = useCallback(() => {
		setVideoTexture(t('webos_diagnostics_testing'));
		void probeVideoTexture().then(setVideoTexture);
	}, []);

	// The first test starts with the page, its state already "testing"; Retry runs it again
	useEffect(() => {
		let cancelled = false;
		void collectDiagnostics(repository).then((found) => {
			if (!cancelled) setLines(found);
		});
		void probeVideoTexture().then((result) => {
			if (!cancelled) setVideoTexture(result);
		});
		return () => {
			cancelled = true;
		};
	}, [repository]);

	const all = lines.concat([{label: t('webos_diagnostics_video_texture'), value: videoTexture}]);
	const chosen = chosenLocale();
	const languages = [t('tv_layout_auto')].concat(LOCALES.map(localeName));

	return (
		<Scroller direction="vertical" scrollMode="native" verticalScrollbar="hidden" className={css.scroller}>
			<div className={css.page}>
				<div className={css.header}>
					<span className={css.title}>{t('about')}</span>
					<span className={css.subtitle}>{t('webos_diagnostics_subtitle')}</span>
				</div>
				<div className={css.columns}>
					<div className={css.table}>
						<div className={css.language}>
							<span className={css.label}>{t('language')}</span>
							<Dropdown size="small" width="large" selected={chosen ? LOCALES.indexOf(chosen) + 1 : 0} onSelect={handleLanguage}>
								{languages}
							</Dropdown>
						</div>
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
						<p className={css.credit}>{isTizen() ? t('webos_about_unofficial_tizen') : t('webos_about_unofficial')}</p>
						<p className={css.credit}>https://github.com/freeKC/Immuch360</p>
						<p className={css.credit}>
							{t('webos_privacy_policy')}: {privacyPolicyUrl()}
						</p>
						<div className={css.actions}>
							<PrivacyPolicyButton />
						</div>
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
