// Immuch360: the privacy policy, reachable inside the app as LG asks (Privacy Guideline: "Provide Privacy Policy within
// your app"): a button on the welcome page, on the sign in page and on About opens a layer with the address of the
// policy's LG TVs section and a QR code of it, to read on a phone. A TV app cannot open a web page by itself without
// another Luna permission, so the code is the way to read it.
//
// Its own full screen layer rather than Sandstone's Popup, whose centring fails on webOS 6 (see AccountPanel.module.less).
import React, {useCallback, useEffect, useState} from 'react';
import Button from '@enact/sandstone/Button';
import Spotlight from '@enact/spotlight';
import {QrCode} from '../../components/QrCode/QrCode';
import {useWebOSKeys} from '../../hooks/useWebOSKeys';
import {createSpotlightContainer, forceFocus} from '../../utils/spotlight';
import {t} from '../i18n';
import css from './PrivacyPolicy.module.less';

/** The LG TVs section of the policy, in the repository (its anchor is the heading "LG TVs (webOS)") */
export const PRIVACY_POLICY_URL = 'https://github.com/freeKC/Immuch360/blob/immuch360/PRIVACY.md#lg-tvs-webos';

const LAYER_ID = 'privacy-policy';
const Layer = createSpotlightContainer();
let buttons = 0;

interface PrivacyPolicyLayerProps {
	onClose: () => void;
}

export const PrivacyPolicyLayer: React.FC<PrivacyPolicyLayerProps> = ({onClose}) => {
	// Back closes the layer first, whatever page is under it
	useWebOSKeys({onBack: onClose});

	useEffect(() => {
		const raf = requestAnimationFrame(() => forceFocus(LAYER_ID));
		return () => cancelAnimationFrame(raf);
	}, []);

	return (
		<Layer spotlightId={LAYER_ID} spotlightRestrict="self-only" className={css.layer} role="dialog" aria-modal="true" aria-labelledby="privacy-policy-title">
			<div className={css.box}>
				<div className={css.text}>
					<h2 id="privacy-policy-title" className={css.title}>
						{t('webos_privacy_policy')}
					</h2>
					<p className={css.summary}>{t('webos_privacy_summary')}</p>
					<p className={css.url} data-privacy-url>
						{PRIVACY_POLICY_URL}
					</p>
					<p className={css.hint}>{t('webos_privacy_scan')}</p>
					<Button size="small" onClick={onClose} backgroundOpacity="opaque">
						{t('close')}
					</Button>
				</div>
				<QrCode value={PRIVACY_POLICY_URL} className={css.qr} />
			</div>
		</Layer>
	);
};

interface PrivacyPolicyButtonProps {
	className?: string;
}

/** The button that opens the layer; the focus comes back to it when the layer closes */
export const PrivacyPolicyButton: React.FC<PrivacyPolicyButtonProps> = ({className}) => {
	const [open, setOpen] = useState(false);
	const [buttonId] = useState(() => `privacy-policy-button-${++buttons}`);
	const show = useCallback(() => setOpen(true), []);
	const close = useCallback(() => {
		setOpen(false);
		requestAnimationFrame(() => {
			if (!Spotlight.getPointerMode()) Spotlight.focus(buttonId);
		});
	}, [buttonId]);

	return (
		<>
			<Button className={className} spotlightId={buttonId} size="small" icon="lock" backgroundOpacity="transparent" onClick={show} data-privacy-button>
				{t('webos_privacy_policy')}
			</Button>
			{open && <PrivacyPolicyLayer onClose={close} />}
		</>
	);
};
