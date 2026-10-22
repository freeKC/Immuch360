// Immuch360: the "Network shares" page of the TV app: the shares, Plex servers and Tapo cameras kept on the TV, the
// servers found on the network, and the pages that add them. Everything goes through the media bridge of the app's JS
// service (webOS 5 and later; SMB from webOS 22).

import React, {useCallback, useEffect, useState} from 'react';
import Scroller from '@enact/sandstone/Scroller';
import Spotlight from '@enact/spotlight';
import {createSpotlightContainer} from '../../utils/spotlight';
import type {RoutePanelProps} from '../../types/navigation';
import {t} from '../i18n';
import {CameraLive} from './CameraLive';
import {bridgeErrorText, sourceErrorText} from './messages';
import {PlexSignIn} from './PlexSignIn';
import {SourceBrowser} from './SourceBrowser';
import {SourceForm, type FormKind} from './SourceForm';
import {SourceTile, kindIcon} from './SourceTile';
import {newSourceId, sourceStore} from './store';
import type {DiscoveredServer, SourceConfig} from './types';
import {useBridge, useSources} from './useBridge';
import css from './sources.module.less';

type Screen = {kind: 'home'} | {kind: 'browse'; id: string} | {kind: 'add'; form: FormKind | null} | {kind: 'plex'} | {kind: 'camera'; id: string};

const HOME_ID = 'sources-home';
const Container = createSpotlightContainer({enterTo: 'last-focused'});
const DISCOVERY_MS = 3000;

/** The second line of a source's tile: where it is */
function whereOf(source: SourceConfig): string {
	if (source.kind === 'webdav') return (source.url || '').replace(/^https?:\/\//, '');
	if (source.kind === 'smb') return `${source.host}/${source.share}${source.root ? `/${source.root}` : ''}`;
	if (source.kind === 'dlna') return (source.location || '').replace(/^http:\/\//, '').split('/')[0] || '';
	if (source.kind === 'plex') return `${source.address}:${source.port ?? 32400}`;
	return source.host || '';
}

function isSaved(server: DiscoveredServer, sources: SourceConfig[]): boolean {
	if (server.kind === 'dlna') return sources.some((s) => s.kind === 'dlna' && s.location === server.location);
	return sources.some((s) => s.kind === 'plex' && ((!!server.machineId && s.machineId === server.machineId) || s.address === server.address));
}

const SourcesPanel: React.FC<RoutePanelProps> = ({contentWidth}) => {
	const {client, info, error, version} = useBridge();
	const sources = useSources();
	const [screen, setScreen] = useState<Screen>({kind: 'home'});
	const [discovered, setDiscovered] = useState<DiscoveredServer[]>([]);
	const [scanning, setScanning] = useState(false);
	const [status, setStatus] = useState<{text: string; error: boolean} | null>(null);
	const home = useCallback(() => setScreen({kind: 'home'}), []);

	// The DLNA and Plex servers of the network, looked for each time the page opens
	useEffect(() => {
		if (!client || !info) return undefined;
		let cancelled = false;
		setScanning(true);
		Promise.all(
			(['dlna', 'plex'] as const).map((kind) =>
				client.control<{servers: DiscoveredServer[]}>('discover', {kind, ms: DISCOVERY_MS}).then(
					(answer) => answer.servers,
					() => []
				)
			)
		).then((lists) => {
			if (cancelled) return;
			setDiscovered(([] as DiscoveredServer[]).concat(...lists));
			setScanning(false);
		});
		return () => {
			cancelled = true;
		};
	}, [client, info, version]);

	useEffect(() => {
		if (screen.kind !== 'home') return undefined;
		const raf = requestAnimationFrame(() => Spotlight.focus(HOME_ID));
		return () => cancelAnimationFrame(raf);
	}, [screen.kind]);

	const open = useCallback((source: SourceConfig) => setScreen(source.kind === 'tapo' ? {kind: 'camera', id: source.id} : {kind: 'browse', id: source.id}), []);

	const addFound = useCallback(
		async (server: DiscoveredServer) => {
			if (!client) return;
			if (server.kind === 'plex') {
				setScreen({kind: 'plex'});
				return;
			}
			const source: SourceConfig = {id: newSourceId(), kind: 'dlna', name: server.name, location: server.location, control: server.control};
			setStatus({text: t('network_share_loading'), error: false});
			try {
				await client.control('test', {source});
				sourceStore().save(source);
				setStatus(null);
				setScreen({kind: 'browse', id: source.id});
			} catch (e) {
				setStatus({text: sourceErrorText(e, 'dlna'), error: true});
			}
		},
		[client]
	);

	const current = screen.kind === 'browse' || screen.kind === 'camera' ? sources.find((s) => s.id === screen.id) ?? null : null;

	if (client && info && screen.kind === 'browse' && current) {
		return <SourceBrowser client={client} info={info} version={version} source={current} contentWidth={contentWidth} onClose={home} />;
	}
	if (client && info && screen.kind === 'camera' && current) {
		return <CameraLive info={info} source={current} onClose={home} />;
	}
	if (client && info && screen.kind === 'add') {
		return <SourceForm client={client} kind={screen.form} smbAvailable={info.smb} discovered={discovered} onSaved={open} onCancel={home} />;
	}
	if (client && info && screen.kind === 'plex') {
		return <PlexSignIn client={client} discovered={discovered} onSaved={open} onCancel={home} />;
	}

	const found = discovered.filter((server) => !isSaved(server, sources));
	const bridgeProblem = !client ? t('webos_service_unavailable', {error: 'no Luna service'}) : error ? bridgeErrorText(error) : null;

	return (
		<Scroller direction="vertical" scrollMode="native" verticalScrollbar="hidden" className={css.scroller}>
			<Container spotlightId={HOME_ID} className={css.page}>
				<div className={css.header}>
					<div className={css.headerText}>
						<span className={css.title}>{t('network_shares')}</span>
						<span className={css.subtitle}>{t('network_shares_description')}</span>
					</div>
				</div>
				{bridgeProblem && <div className={css.error}>{bridgeProblem}</div>}
				{!bridgeProblem && !info && <div className={css.notice}>{t('webos_loading')}</div>}
				{status && <div className={status.error ? css.error : css.notice}>{status.text}</div>}
				{info && (
					<>
						{sources.length === 0 && <div className={css.notice}>{t('network_share_no_shares')}</div>}
						<div className={css.grid}>
							{sources.map((source) => (
								<SourceTile key={source.id} icon={kindIcon(source.kind)} title={source.name} secondary={whereOf(source)} onClick={() => open(source)} />
							))}
							<SourceTile icon="plus" title={t('network_share_add')} secondary={t('network_add_choose_share')} onClick={() => setScreen({kind: 'add', form: null})} />
							<SourceTile icon="plus" title={t('plex_server_add')} secondary={t('network_add_choose_plex')} onClick={() => setScreen({kind: 'plex'})} />
							<SourceTile icon="plus" title={t('camera_add')} secondary={t('network_add_choose_camera')} onClick={() => setScreen({kind: 'add', form: 'tapo'})} />
						</div>
						<div className={css.section}>{t('network_share_scan_title')}</div>
						{scanning && <div className={css.notice}>{t('network_share_scan_scanning')}</div>}
						{!scanning && found.length === 0 && <div className={css.notice}>{t('network_share_scan_none_found')}</div>}
						{found.length > 0 && (
							<div className={css.grid}>
								{found.map((server) => (
									<SourceTile
										key={`${server.kind}:${server.location || server.address}`}
										icon={kindIcon(server.kind)}
										title={server.name || server.address || server.host || ''}
										secondary={server.kind === 'dlna' ? t('network_share_scan_type_dlna') : t('network_share_scan_type_plex')}
										onClick={() => void addFound(server)}
									/>
								))}
							</div>
						)}
					</>
				)}
			</Container>
		</Scroller>
	);
};

export default SourcesPanel;
