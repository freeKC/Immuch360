import React, {useCallback, useEffect, useMemo, useState} from 'react';
import Button from '@enact/sandstone/Button';
import Spotlight, {getDirection} from '@enact/spotlight';
import {AccountGrid} from './AccountGrid';
import {AuthForm, type AuthFormPayload, type AuthSubmitResult} from '../../components/AuthForm/AuthForm';
import {createSpotlightContainer} from '../../utils/spotlight';
import {PrivacyPolicyButton} from '../../immuch360/privacy/PrivacyPolicy';
import {useWebOSKeys} from '../../hooks/useWebOSKeys';
import type {Account} from '../../utils/accountsStore';
import type {PairingDriver, PairedAccountResult} from '../../pairing/types';
import bannerImage from '../../assets/immuch360-icon.png';
import css from './AccountPanel.module.less';
import {t} from '../../immuch360/i18n';

export type AccountPanelMode = 'first-launch' | 'overlay';

const OVERLAY_SPOTLIGHT_ID = 'account-overlay';
// Trap Spotlight inside the overlay so D-pad can't reach the rail/timeline behind it
// (same pattern as MediaViewer's ViewerContainer).
const OverlayContainer = createSpotlightContainer({enterTo: 'last-focused'});

interface AccountPanelProps {
	mode: AccountPanelMode;
	accounts: Account[];
	activeAccountId: string | null;
	defaultAccountId: string | null;
	onSwitch: (id: string) => void;
	onSetDefault: (id: string | null) => void;
	onRemove: (id: string) => void;
	onAddAccount: (payload: AuthFormPayload) => Promise<AuthSubmitResult>;
	onAddPairedAccount?: (result: PairedAccountResult) => Promise<AuthSubmitResult>;
	pairingDriver?: PairingDriver | null;
	onCloseOverlay?: () => void;
	// Immuch360: why the active account did not start, and how to start it again
	startError?: string;
	onRetry?: () => void;
}

export const AccountPanel: React.FC<AccountPanelProps> = ({
	mode,
	accounts,
	activeAccountId,
	defaultAccountId,
	onSwitch,
	onSetDefault,
	onRemove,
	onAddAccount,
	onAddPairedAccount,
	pairingDriver,
	onCloseOverlay,
	startError,
	onRetry,
}) => {
	// Both modes start on 'grid'. In first-launch mode 'grid' renders the welcome screen
	// (since accounts.length === 0 means no cards to draw); the user clicks the CTA
	// to transition into 'form'.
	const [subMode, setSubMode] = useState<'grid' | 'form'>('grid');

	const goForm = useCallback(() => setSubMode('form'), []);
	const goGrid = useCallback(() => setSubMode('grid'), []);
	const handleOverlayMouseMove = useCallback((event: React.MouseEvent<HTMLDivElement>) => {
		const target = event.target;
		// Moving the Magic Remote over dead overlay space makes Spotlight blur its current
		// target. Keep the existing focus there; movement over a spottable still reaches
		// Spotlight normally and transfers focus to the hovered control.
		if (!(target instanceof Element) || !target.closest('.spottable')) {
			event.stopPropagation();
		}
	}, []);

	const activeBaseUrl = accounts.find(a => a.id === activeAccountId)?.baseUrl ?? '';

	const handleSubmit = useCallback(
		async (payload: AuthFormPayload): Promise<AuthSubmitResult> => {
			const result = await onAddAccount(payload);
			if (result.success && mode === 'overlay') {
				setSubMode('grid');
			}
			return result;
		},
		[mode, onAddAccount],
	);

	const handlePairedLogin = useMemo(() => {
		if (!onAddPairedAccount) return undefined;
		return async (result: PairedAccountResult): Promise<AuthSubmitResult> => {
			const login = await onAddPairedAccount(result);
			if (login.success && mode === 'overlay') {
				setSubMode('grid');
			}
			return login;
		};
	}, [mode, onAddPairedAccount]);

	// Remote Back semantics: on form, peel back to grid; on grid in overlay mode, close
	// the overlay. First-launch grid has no back target (root of app): useWebOSKeys then hands
	// the key to the platform (webOS.platformBack), as on every entry page.
	const backHandler = useMemo<(() => void) | undefined>(() => {
		if (subMode === 'form') return goGrid;
		if (mode === 'overlay') return onCloseOverlay;
		return undefined;
	}, [mode, subMode, goGrid, onCloseOverlay]);

	useWebOSKeys({onBack: backHandler});

	// Pull 5-way focus into the overlay on open: last focus lives on the rail/timeline
	// behind it, and spotlightRestrict only applies once focus is inside the container.
	// Spotlight intentionally refuses programmatic focus while the Magic Remote cursor is
	// visible, so briefly enter 5-way mode for the focus call, then restore pointer mode.
	useEffect(() => {
		if (mode !== 'overlay') return;

		const wasPointerMode = Spotlight.getPointerMode();
		if (wasPointerMode) Spotlight.setPointerMode(false);
		Spotlight.focus(OVERLAY_SPOTLIGHT_ID);
		if (wasPointerMode) Spotlight.setPointerMode(true);
	}, [mode]);

	// Last-resort modal trap: a pointer event or a disappearing control can still leave DOM
	// focus outside the overlay. Recapture before Spotlight handles the same directional key,
	// so the first press both restores focus and performs the requested move.
	useEffect(() => {
		if (mode !== 'overlay') return;

		const recaptureFocus = (event: KeyboardEvent) => {
			if (!getDirection(event.keyCode)) return;

			const overlay = document.querySelector<HTMLElement>(`[data-spotlight-id="${OVERLAY_SPOTLIGHT_ID}"]`);
			if (!overlay || overlay.contains(document.activeElement)) return;

			Spotlight.setPointerMode(false);
			Spotlight.focus(OVERLAY_SPOTLIGHT_ID);
		};

		window.addEventListener('keydown', recaptureFocus, true);
		return () => window.removeEventListener('keydown', recaptureFocus, true);
	}, [mode]);

	if (mode === 'first-launch') {
		if (subMode === 'form') {
			return (
				<div className={css.firstLaunchForm}>
					<AuthForm
						initialUrl=""
						onSubmit={handleSubmit}
						pairingDriver={pairingDriver}
						onPairedLogin={handlePairedLogin}
					/>
				</div>
			);
		}
		return (
			<div className={css.firstLaunch}>
				<img src={bannerImage} alt="" className={css.banner} />
				<h2 className={css.welcomeTitle}>Immuch360</h2>
				<p className={css.welcomeSub}>{t('welcome_tagline')}</p>
				<p className={css.welcomeSub}>{t('welcome_server_title')}</p>
				<Button autoFocus size="large" icon="plus" onClick={goForm} backgroundOpacity="opaque">
					{t('webos_add_account')}
				</Button>
				<PrivacyPolicyButton className={css.privacy} />
			</div>
		);
	}

	return (
		<OverlayContainer
			spotlightId={OVERLAY_SPOTLIGHT_ID}
			spotlightRestrict="self-only"
			role="dialog"
			aria-modal="true"
			className={css.overlay}
			onMouseMove={handleOverlayMouseMove}
		>
			<div className={css.panel}>
				{subMode === 'grid' ? (
					<AccountGrid
						accounts={accounts}
						activeAccountId={activeAccountId}
						defaultAccountId={defaultAccountId}
						onSwitch={onSwitch}
						onSetDefault={onSetDefault}
						onRemove={onRemove}
						onAdd={goForm}
						startError={startError}
						onRetry={onRetry}
					/>
				) : (
					<AuthForm
						initialUrl={activeBaseUrl}
						onSubmit={handleSubmit}
						onBack={accounts.length > 0 ? goGrid : undefined}
						pairingDriver={pairingDriver}
						onPairedLogin={handlePairedLogin}
					/>
				)}
			</div>
		</OverlayContainer>
	);
};
