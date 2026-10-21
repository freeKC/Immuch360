import React, {useEffect, useRef} from 'react';
import Button from '@enact/sandstone/Button';
import {ErrorMessage} from '../ErrorMessage';
import {QrCode} from '../QrCode/QrCode';
import {usePhonePairing} from '../../hooks/usePhonePairing';
import type {AuthSubmitResult} from '../../api/types';
import type {PairingDriver, PairedAccountResult} from '../../pairing/types';
import css from './PairingTab.module.less';
import {t} from '../../immuch360/i18n';

// Stands for the address in the sentence of step 2, then split on
const URL_MARK = '\u0001';

interface PairingTabProps {
	driver: PairingDriver;
	suggestedUrl: string;
	onPaired: (result: PairedAccountResult) => Promise<AuthSubmitResult>;
	// Fired when the pairing service can't even start (e.g. broken install):
	// lets AuthForm fall back to the Email tab.
	onStartFailed?: () => void;
}

export const PairingTab: React.FC<PairingTabProps> = ({driver, suggestedUrl, onPaired, onStartFailed}) => {
	const {state, restart} = usePhonePairing(driver, suggestedUrl, onPaired);

	const startFailedRef = useRef(onStartFailed);
	useEffect(() => {
		startFailedRef.current = onStartFailed;
	}, [onStartFailed]);
	const failedAtStart = state.phase === 'error' && state.atStart;
	useEffect(() => {
		if (failedAtStart && startFailedRef.current) startFailedRef.current();
	}, [failedAtStart]);

	if (state.phase === 'waiting') {
		const manualUrl = state.url.replace(/\?.*$/, '');
		// One sentence for the translators, {url} where the address goes; the address is drawn in its own style
		const [scanBefore, scanAfter = ''] = t('webos_pairing_step_scan', {url: URL_MARK}).split(URL_MARK);
		return (
			<div className={css.pairing}>
				<QrCode value={state.url} className={css.qr} />
				<div className={css.details}>
					<p className={css.step}>{t('webos_pairing_step_wifi')}</p>
					<p className={css.step}>
						{scanBefore}
						<span className={css.url}>{manualUrl}</span>
						{scanAfter}
					</p>
					<p className={css.step}>{t('webos_pairing_step_sign_in')}</p>
					<div className={css.codeRow}>
						<span className={css.codeLabel}>{t('webos_pairing_code')}</span>
						<span className={css.code}>{state.code}</span>
					</div>
					<p className={css.status}>{t('webos_pairing_waiting')}</p>
				</div>
			</div>
		);
	}

	if (state.phase === 'error') {
		return (
			<div className={css.message}>
				<ErrorMessage message={state.message} />
				<div className={css.retry}>
					<Button size="small" onClick={restart} backgroundOpacity="opaque">
						{t('retry')}
					</Button>
				</div>
			</div>
		);
	}

	return (
		<div className={css.message}>
			<p className={css.status}>{state.phase === 'finalizing' ? t('webos_pairing_signing_in') : t('webos_pairing_preparing')}</p>
		</div>
	);
};
