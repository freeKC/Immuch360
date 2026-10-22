// Immuch360: adding a Plex Media Server on the TV. A server of the network that has no plex.direct certificate (not
// claimed) is added as it is, without a token. For the others the TV signs in to Plex with a PIN: the bridge asks
// plex.tv for a code, the user types it on plex.tv/link with a phone or a computer (or scans the QR code), and the
// bridge then reads the servers of the account, each with its own token, kept on the TV. Pasting a token as on the
// phones would mean typing 20 characters with a remote.

import React, {useCallback, useEffect, useRef, useState} from 'react';
import Button from '@enact/sandstone/Button';
import Scroller from '@enact/sandstone/Scroller';
import Spotlight from '@enact/spotlight';
import {QrCode} from '../../components/QrCode/QrCode';
import {useWebOSKeys} from '../../hooks/useWebOSKeys';
import {createSpotlightContainer} from '../../utils/spotlight';
import {t} from '../i18n';
import type {BridgeClient} from './bridgeClient';
import {sourceErrorText} from './messages';
import {SourceTile, kindIcon} from './SourceTile';
import {newSourceId, sourceStore} from './store';
import type {DiscoveredServer, PlexAccountServer, SourceConfig} from './types';
import css from './sources.module.less';

const PLEX_ID = 'plex-sign-in';
const LINK_URL = 'https://plex.tv/link';
const POLL_MS = 2000;
const Container = createSpotlightContainer({enterTo: 'last-focused'});

interface PlexSignInProps {
	client: BridgeClient;
	discovered: DiscoveredServer[];
	onSaved: (source: SourceConfig) => void;
	onCancel: () => void;
}

type Step = {kind: 'choose'} | {kind: 'pin'; id: number; code: string} | {kind: 'servers'; servers: PlexAccountServer[]};

export const PlexSignIn: React.FC<PlexSignInProps> = ({client, discovered, onSaved, onCancel}) => {
	const [step, setStep] = useState<Step>({kind: 'choose'});
	const [status, setStatus] = useState<{text: string; error: boolean} | null>(null);
	const [busy, setBusy] = useState(false);
	const alive = useRef(true);
	useEffect(
		() => () => {
			alive.current = false;
		},
		[]
	);

	const back = useCallback(() => {
		if (step.kind !== 'choose') {
			setStep({kind: 'choose'});
			setStatus(null);
		} else onCancel();
	}, [step.kind, onCancel]);
	useWebOSKeys({onBack: back});

	useEffect(() => {
		const raf = requestAnimationFrame(() => Spotlight.focus(PLEX_ID));
		return () => cancelAnimationFrame(raf);
	}, [step.kind]);

	const save = useCallback(
		async (source: SourceConfig) => {
			setBusy(true);
			setStatus({text: t('network_share_loading'), error: false});
			try {
				const answer = await client.control<{count?: number}>('test', {source});
				if (!alive.current) return;
				setStatus({text: t('plex_connected', {count: answer.count ?? 0}), error: false});
				sourceStore().save(source);
				onSaved(source);
			} catch (error) {
				if (alive.current) setStatus({text: sourceErrorText(error, 'plex'), error: true});
			} finally {
				if (alive.current) setBusy(false);
			}
		},
		[client, onSaved]
	);

	const startPin = useCallback(async () => {
		setBusy(true);
		setStatus(null);
		try {
			const pin = await client.control<{id: number; code: string}>('plexPin', {clientId: sourceStore().plexClientId()});
			if (alive.current) setStep({kind: 'pin', id: pin.id, code: pin.code});
		} catch (error) {
			if (alive.current) setStatus({text: sourceErrorText(error, 'plex'), error: true});
		} finally {
			if (alive.current) setBusy(false);
		}
	}, [client]);

	// While the code shows, plex.tv is asked every 2 s whether it was linked
	useEffect(() => {
		if (step.kind !== 'pin') return undefined;
		let stopped = false;
		const clientId = sourceStore().plexClientId();
		const timer = setInterval(async () => {
			try {
				const answer = await client.control<{token: string | null}>('plexPinCheck', {clientId, id: step.id});
				if (stopped || !answer.token) return;
				stopped = true;
				clearInterval(timer);
				const list = await client.control<{servers: PlexAccountServer[]}>('plexServers', {clientId, token: answer.token});
				if (!alive.current) return;
				setStep({kind: 'servers', servers: list.servers});
				if (!list.servers.length) setStatus({text: t('webos_plex_no_server'), error: true});
			} catch (error) {
				if (!stopped && alive.current) setStatus({text: sourceErrorText(error, 'plex'), error: true});
			}
		}, POLL_MS);
		return () => {
			stopped = true;
			clearInterval(timer);
		};
	}, [client, step]);

	const addDiscovered = useCallback(
		(server: DiscoveredServer) => {
			if (server.hash) {
				void startPin();
				return;
			}
			void save({id: newSourceId(), kind: 'plex', name: server.name || server.address || 'Plex', address: server.address, port: server.port, hash: null, token: null, machineId: server.machineId});
		},
		[save, startPin]
	);

	const addAccountServer = useCallback(
		(server: PlexAccountServer) =>
			void save({id: newSourceId(), kind: 'plex', name: server.name, address: server.address, port: server.port, hash: server.hash, token: server.token, machineId: server.machineId}),
		[save]
	);

	let body: React.ReactNode;
	if (step.kind === 'pin') {
		body = (
			<>
				<div className={css.notice}>{t('webos_plex_link_code')}</div>
				<div className={css.pinBox}>
					<QrCode value={LINK_URL} className={css.qr} />
					<div className={css.pinCode}>{step.code}</div>
				</div>
				<div className={css.notice}>{t('webos_plex_link_waiting')}</div>
				<Button onClick={back}>{t('cancel')}</Button>
			</>
		);
	} else if (step.kind === 'servers') {
		body = (
			<>
				<div className={css.section}>{t('webos_plex_choose_server')}</div>
				<div className={css.grid}>
					{step.servers.map((server) => (
						<SourceTile key={server.machineId + server.address} icon={kindIcon('plex')} title={server.name} secondary={`${server.address}:${server.port}`} onClick={() => addAccountServer(server)} />
					))}
				</div>
			</>
		);
	} else {
		const found = discovered.filter((server) => server.kind === 'plex');
		body = (
			<>
				<div className={css.row}>
					<Button disabled={busy} onClick={startPin}>
						{t('webos_plex_sign_in')}
					</Button>
				</div>
				<div className={css.section}>{t('network_share_scan_title')}</div>
				{found.length ? (
					<div className={css.grid}>
						{found.map((server) => (
							<SourceTile
								key={(server.machineId || '') + server.address}
								icon={kindIcon('plex')}
								title={server.name || server.address || 'Plex'}
								secondary={server.hash ? t('webos_plex_sign_in') : `${server.address}:${server.port}`}
								onClick={() => addDiscovered(server)}
							/>
						))}
					</div>
				) : (
					<div className={css.notice}>{t('plex_scan_none_found')}</div>
				)}
			</>
		);
	}

	return (
		<Scroller direction="vertical" scrollMode="native" verticalScrollbar="hidden" className={css.scroller}>
			<Container spotlightId={PLEX_ID} className={css.page}>
				<div className={css.header}>
					<Button icon="arrowlargeleft" size="small" backgroundOpacity="transparent" onClick={back} />
					<div className={css.headerText}>
						<span className={css.title}>{t('plex_server_add')}</span>
					</div>
				</div>
				{status && <div className={status.error ? css.error : css.notice}>{status.text}</div>}
				{body}
			</Container>
		</Scroller>
	);
};
