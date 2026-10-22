// Immuch360: the page that adds a share (SMB, WebDAV, DLNA) or a Tapo camera on the TV: the fields of the mobile app's
// page (its texts, network_* and camera_* keys), a test through the bridge, then the source is kept on the TV.

import React, {useCallback, useEffect, useMemo, useState} from 'react';
import Button from '@enact/sandstone/Button';
import Scroller from '@enact/sandstone/Scroller';
import Spotlight from '@enact/spotlight';
import {FieldRow} from '../../components/FieldRow/FieldRow';
import {useWebOSKeys} from '../../hooks/useWebOSKeys';
import {createSpotlightContainer} from '../../utils/spotlight';
import {i18nKey, t} from '../i18n';
import type {BridgeClient} from './bridgeClient';
import {webdavUrl} from './addresses';
import {sourceErrorText} from './messages';
import {SourceTile, kindIcon} from './SourceTile';
import {newSourceId, sourceStore} from './store';
import type {DiscoveredServer, SourceConfig, SourceKind} from './types';
import css from './sources.module.less';

export type FormKind = Exclude<SourceKind, 'plex'>;

interface SourceFormProps {
	client: BridgeClient;
	kind: FormKind | null;
	smbAvailable: boolean;
	discovered: DiscoveredServer[];
	onSaved: (source: SourceConfig) => void;
	onCancel: () => void;
}

const FORM_ID = 'source-form';

// The names of the kinds, held through i18nKey so that tools/build-i18n.mjs bundles them
const TYPE_NAMES: Record<FormKind, string> = {
	smb: i18nKey('network_share_type_smb'),
	webdav: i18nKey('network_share_type_webdav'),
	dlna: i18nKey('network_share_type_dlna'),
	tapo: i18nKey('camera_cameras'),
};
const Container = createSpotlightContainer({enterTo: 'last-focused'});

const Field: React.FC<{label: string; children: React.ReactNode}> = ({label, children}) => (
	<div className={css.field}>
		<label className={css.label}>{label}</label>
		{children}
	</div>
);

export const SourceForm: React.FC<SourceFormProps> = ({client, kind: initialKind, smbAvailable, discovered, onSaved, onCancel}) => {
	const [kind, setKind] = useState<FormKind | null>(initialKind);
	const [name, setName] = useState('');
	const [host, setHost] = useState('');
	const [port, setPort] = useState('');
	const [share, setShare] = useState('');
	const [root, setRoot] = useState('');
	const [path, setPath] = useState('');
	const [tls, setTls] = useState(true);
	const [user, setUser] = useState('');
	const [password, setPassword] = useState('');
	const [location, setLocation] = useState('');
	const [status, setStatus] = useState<{text: string; error: boolean} | null>(null);
	const [busy, setBusy] = useState(false);
	const [shares, setShares] = useState<string[] | null>(null);

	const back = useCallback(() => {
		if (kind && !initialKind) setKind(null);
		else onCancel();
	}, [kind, initialKind, onCancel]);
	useWebOSKeys({onBack: back});

	useEffect(() => {
		const raf = requestAnimationFrame(() => Spotlight.focus(FORM_ID));
		return () => cancelAnimationFrame(raf);
	}, [kind]);

	const build = useCallback(
		(dlna?: DiscoveredServer): SourceConfig | null => {
			const id = newSourceId();
			if (dlna) return {id, kind: 'dlna', name: dlna.name, location: dlna.location, control: dlna.control};
			if (kind === 'smb') {
				if (!host.trim() || !share.trim()) return null;
				return {id, kind, name: name.trim() || `${share.trim()} (${host.trim()})`, host: host.trim(), port: Number(port) || undefined, share: share.trim(), root: root.trim(), user: user.trim(), password};
			}
			if (kind === 'webdav') {
				if (!host.trim()) return null;
				return {id, kind, name: name.trim() || host.trim(), url: webdavUrl(host, port, path, tls), user: user.trim(), password};
			}
			if (kind === 'dlna') {
				if (!/^http:\/\//i.test(location.trim())) return null;
				return {id, kind, name: name.trim() || location.trim().replace(/^http:\/\//i, '').split('/')[0]!, location: location.trim()};
			}
			if (kind === 'tapo') {
				if (!host.trim()) return null;
				return {id, kind, name: name.trim() || host.trim(), host: host.trim(), port: Number(port) || undefined, user: user.trim(), password};
			}
			return null;
		},
		[kind, name, host, port, share, root, path, tls, user, password, location]
	);

	const test = useCallback(
		async (source: SourceConfig): Promise<boolean> => {
			setBusy(true);
			setStatus({text: source.kind === 'tapo' ? t('camera_live_connecting') : t('network_share_loading'), error: false});
			try {
				const answer = await client.control<{count?: number; size?: {width: number; height: number}; codec?: string}>('test', {source});
				if (source.kind === 'tapo') setStatus({text: `${t('camera_live')}: ${answer.size ? `${answer.size.width} × ${answer.size.height}` : ''} ${answer.codec ?? ''}`, error: false});
				else setStatus({text: t('network_share_connected', {count: answer.count ?? 0}), error: false});
				return true;
			} catch (error) {
				setStatus({text: sourceErrorText(error, source.kind, source.host), error: true});
				return false;
			} finally {
				setBusy(false);
			}
		},
		[client]
	);

	const handleTest = useCallback(() => {
		const source = build();
		if (source) void test(source);
	}, [build, test]);

	const save = useCallback(
		async (source: SourceConfig | null) => {
			if (!source) return;
			if (!(await test(source))) return;
			sourceStore().save(source);
			onSaved(source);
		},
		[test, onSaved]
	);

	const handleSave = useCallback(() => void save(build()), [save, build]);

	const listShares = useCallback(async () => {
		setBusy(true);
		setShares(null);
		try {
			const answer = await client.control<{shares: string[]}>('smbShares', {host: host.trim(), port: Number(port) || undefined, user: user.trim(), password});
			setShares(answer.shares);
			setStatus(answer.shares.length ? null : {text: t('network_share_scan_shares_none'), error: false});
		} catch (error) {
			setStatus({text: t('network_share_scan_shares_error', {error: sourceErrorText(error, 'smb', host)}), error: true});
		} finally {
			setBusy(false);
		}
	}, [client, host, port, user, password]);

	const dlnaFound = useMemo(() => discovered.filter((server) => server.kind === 'dlna'), [discovered]);

	let body: React.ReactNode;
	if (!kind) {
		body = (
			<div className={css.grid}>
				<SourceTile icon="files" title={t('network_share_type_smb')} secondary={smbAvailable ? undefined : t('webos_smb_needs_webos22')} onClick={() => setKind('smb')} />
				<SourceTile icon="files" title={t('network_share_type_webdav')} onClick={() => setKind('webdav')} />
				<SourceTile icon="dlna" title={t('network_share_type_dlna')} onClick={() => setKind('dlna')} />
			</div>
		);
	} else if (kind === 'smb' && !smbAvailable) {
		body = <div className={css.notice}>{t('webos_smb_needs_webos22')}</div>;
	} else {
		body = (
			<div className={css.form}>
				{kind === 'dlna' && dlnaFound.length > 0 && (
					<>
						<div className={css.section}>{t('network_share_scan_title')}</div>
						<div className={css.grid}>
							{dlnaFound.map((server) => (
								<SourceTile key={server.location} icon={kindIcon('dlna')} title={server.name} secondary={server.host} onClick={() => void save(build(server))} />
							))}
						</div>
						<div className={css.notice}>{t('network_share_scan_enter_by_hand')}</div>
					</>
				)}
				<Field label={t('network_share_name')}>
					<FieldRow value={name} onChange={setName} placeholder={t('network_share_name')} />
				</Field>
				{kind === 'dlna' ? (
					<Field label={t('network_share_description_path')}>
						<FieldRow value={location} onChange={setLocation} placeholder="http://192.168.1.20:8200/rootDesc.xml" />
						<div className={css.notice}>{t('network_share_dlna_hint')}</div>
					</Field>
				) : (
					<>
						<Field label={kind === 'tapo' ? t('camera_host') : t('network_share_host')}>
							<FieldRow value={host} onChange={setHost} placeholder="192.168.1.20" />
						</Field>
						<Field label={t('network_share_port')}>
							<FieldRow value={port} onChange={setPort} placeholder={kind === 'smb' ? '445' : kind === 'tapo' ? '554' : tls ? '443' : '80'} />
						</Field>
					</>
				)}
				{kind === 'smb' && (
					<>
						<Field label={t('network_share_share_name')}>
							<div className={css.row}>
								<FieldRow value={share} onChange={setShare} placeholder="photos" />
								<Button size="small" disabled={busy || !host.trim()} onClick={listShares}>
									{t('network_share_scan_choose_share')}
								</Button>
							</div>
							{shares && shares.length > 0 && (
								<div className={css.row}>
									{shares.map((name_) => (
										<Button key={name_} size="small" selected={name_ === share} onClick={() => setShare(name_)}>
											{name_}
										</Button>
									))}
								</div>
							)}
						</Field>
						<Field label={t('network_share_root_path')}>
							<FieldRow value={root} onChange={setRoot} placeholder="Photos/2026" />
						</Field>
					</>
				)}
				{kind === 'webdav' && (
					<>
						<Field label={t('network_share_url_path')}>
							<FieldRow value={path} onChange={setPath} placeholder="remote.php/dav/files/me" />
						</Field>
						<Field label={t('network_share_use_tls')}>
							<Button size="small" selected={tls} icon={tls ? 'check' : undefined} onClick={() => setTls(!tls)}>
								{tls ? 'HTTPS' : 'HTTP'}
							</Button>
						</Field>
					</>
				)}
				{kind !== 'dlna' && (
					<>
						<Field label={kind === 'tapo' ? t('camera_account_user') : t('network_share_username')}>
							<FieldRow value={user} onChange={setUser} />
						</Field>
						<Field label={kind === 'tapo' ? t('camera_account_password') : t('network_share_password')}>
							<FieldRow value={password} onChange={setPassword} type="password" />
						</Field>
					</>
				)}
				{kind === 'tapo' && (
					<>
						<div className={css.notice}>{t('camera_account_hint')}</div>
						<div className={css.notice}>{t('webos_camera_recordings_later')}</div>
					</>
				)}
				<div className={`${css.row} ${css.buttons}`}>
					<Button disabled={busy} onClick={handleTest}>
						{kind === 'tapo' ? t('camera_test') : t('network_share_test')}
					</Button>
					<Button disabled={busy} onClick={handleSave}>
						{t('network_share_save')}
					</Button>
					<Button onClick={back}>{t('cancel')}</Button>
				</div>
			</div>
		);
	}

	const title = kind === 'tapo' ? t('camera_add') : t('network_share_add');
	return (
		<Scroller direction="vertical" scrollMode="native" verticalScrollbar="hidden" className={css.scroller}>
			<Container spotlightId={FORM_ID} className={css.page}>
				<div className={css.header}>
					<Button icon="arrowlargeleft" size="small" backgroundOpacity="transparent" onClick={back} />
					<div className={css.headerText}>
						<span className={css.title}>{title}</span>
						{kind && kind !== 'tapo' && <span className={css.subtitle}>{t(TYPE_NAMES[kind])}</span>}
					</div>
				</div>
				{status && <div className={status.error ? css.error : css.notice}>{status.text}</div>}
				{body}
			</Container>
		</Scroller>
	);
};
