// Immuch360: the folders of a source on the TV. A folder with subfolders shows them as tiles, with a first tile for
// its own photos and videos; a folder of media alone opens on their grid. The grid, the viewer and the slideshow are
// those of the Immich screens, fed by a SourceRepository whose pictures and videos come through the bridge.

import React, {useCallback, useEffect, useMemo, useState} from 'react';
import Button from '@enact/sandstone/Button';
import Scroller from '@enact/sandstone/Scroller';
import Spotlight from '@enact/spotlight';
import {useQuery} from '@tanstack/react-query';
import {AssetGridView} from '../../components/AssetGridView';
import {RepositoryProvider} from '../../domain/RepositoryContext';
import type {DayGroup} from '../../domain/types';
import {useWebOSKeys} from '../../hooks/useWebOSKeys';
import {createSpotlightContainer} from '../../utils/spotlight';
import {t} from '../i18n';
import type {BridgeClient} from './bridgeClient';
import {sourceErrorText} from './messages';
import {SourceRepository} from './repository';
import {SourceTile, kindIcon} from './SourceTile';
import {sourceStore} from './store';
import type {BridgeInfo, Listing, SourceConfig} from './types';
import css from './sources.module.less';

const BROWSER_ID = 'source-browser';
// The first tile of a folder takes the focus when it opens, rather than the button that removes the source
const FIRST_TILE_ID = 'source-browser-first';
const Container = createSpotlightContainer({enterTo: 'last-focused'});

interface Folder {
	ref: string;
	name: string;
}

interface SourceBrowserProps {
	client: BridgeClient;
	info: BridgeInfo;
	version: number;
	source: SourceConfig;
	contentWidth: number;
	onClose: () => void;
}

const fetchJson = (url: string, init?: {signal?: AbortSignal}) => fetch(url, init);

const MediaGrid: React.FC<{
	info: BridgeInfo;
	source: SourceConfig;
	folder: Folder;
	listing: Listing;
	contentWidth: number;
	onBack: () => void;
}> = ({info, source, folder, listing, contentWidth, onBack}) => {
	const repository = useMemo(
		() =>
			new SourceRepository(info, source, listing.files, {
				unsupportedCaption: t('webos_not_on_tv'),
				screen: {width: Math.min(3840, window.screen?.width || 1920), height: Math.min(2160, window.screen?.height || 1080)},
				fetch: fetchJson,
			}),
		[info, source, listing.files]
	);
	const groups = useMemo<DayGroup[]>(
		() => [{timeBucket: `folder:${folder.ref}`, label: source.name, assets: repository.assets, count: repository.assets.length}],
		[repository, folder, source.name]
	);
	return (
		<RepositoryProvider repository={repository}>
			<AssetGridView
				title={folder.name}
				subtitle={t('webos_folder_media', {count: repository.assets.length})}
				groups={groups}
				isLoading={false}
				error={null}
				isEmpty={repository.assets.length === 0}
				emptyText={t('network_share_empty_folder')}
				spotlightId="source-media-grid"
				onBack={onBack}
				contentWidth={contentWidth}
			/>
		</RepositoryProvider>
	);
};

export const SourceBrowser: React.FC<SourceBrowserProps> = ({client, info, version, source, contentWidth, onClose}) => {
	const [stack, setStack] = useState<Folder[]>([{ref: '', name: source.name}]);
	const [mediaOpen, setMediaOpen] = useState(false);
	const [confirmRemove, setConfirmRemove] = useState(false);
	const folder = stack[stack.length - 1]!;
	const query = useQuery({
		queryKey: ['source-list', source.id, folder.ref, version],
		queryFn: () => client.list(source.id, folder.ref),
		retry: false,
		staleTime: 60000,
	});
	const listing = query.data;
	const mediaOnly = !!listing && listing.folders.length === 0 && listing.files.length > 0;

	const up = useCallback(() => {
		setMediaOpen(false);
		setConfirmRemove(false);
		if (stack.length > 1) setStack(stack.slice(0, -1));
		else onClose();
	}, [stack, onClose]);

	const closeMedia = useCallback(() => {
		if (mediaOnly) up();
		else setMediaOpen(false);
	}, [mediaOnly, up]);

	const showMedia = mediaOpen || mediaOnly;
	useWebOSKeys({onBack: showMedia ? undefined : up});

	useEffect(() => {
		if (showMedia) return undefined;
		const raf = requestAnimationFrame(() => {
			if (!Spotlight.focus(FIRST_TILE_ID)) Spotlight.focus(BROWSER_ID);
		});
		return () => cancelAnimationFrame(raf);
	}, [showMedia, folder.ref, query.isLoading]);

	const toggleRemove = useCallback(() => setConfirmRemove((on) => !on), []);
	const openMedia = useCallback(() => setMediaOpen(true), []);
	const refetch = query.refetch;
	const retry = useCallback(() => void refetch(), [refetch]);
	const folders = listing?.folders;
	const openFolder = useCallback(
		(ref: string) => {
			const target = folders?.find((f) => f.ref === ref);
			if (target) setStack((current) => current.concat([{ref: target.ref, name: target.name}]));
		},
		[folders]
	);

	const remove = useCallback(() => {
		sourceStore().remove(source.id);
		onClose();
	}, [source.id, onClose]);

	if (showMedia && listing) {
		return <MediaGrid info={info} source={source} folder={folder} listing={listing} contentWidth={contentWidth} onBack={closeMedia} />;
	}

	const removeText = source.kind === 'plex' ? t('plex_remove_confirm', {name: source.name}) : t('network_share_remove_confirm', {name: source.name});

	return (
		<Scroller direction="vertical" scrollMode="native" verticalScrollbar="hidden" className={css.scroller}>
			<Container spotlightId={BROWSER_ID} className={css.page}>
				<div className={css.header}>
					<Button icon="arrowlargeleft" size="small" backgroundOpacity="transparent" onClick={up} />
					<div className={css.headerText}>
						<span className={css.title}>{folder.name}</span>
						{stack.length > 1 && <span className={css.subtitle}>{source.name}</span>}
					</div>
					{stack.length === 1 && (
						<Button size="small" icon="trash" onClick={toggleRemove}>
							{t('network_share_remove')}
						</Button>
					)}
				</div>
				{confirmRemove && (
					<div>
						<div className={css.notice}>{removeText}</div>
						<div className={css.row}>
							<Button onClick={remove}>{t('remove')}</Button>
							<Button onClick={toggleRemove}>{t('cancel')}</Button>
						</div>
					</div>
				)}
				{query.isLoading && <div className={css.notice}>{t('network_share_loading')}</div>}
				{query.error && (
					<div>
						<div className={css.error}>{sourceErrorText(query.error, source.kind, source.host || source.address)}</div>
						<Button onClick={retry}>{t('retry')}</Button>
					</div>
				)}
				{listing && listing.folders.length === 0 && listing.files.length === 0 && <div className={css.notice}>{t('network_share_empty_folder')}</div>}
				{listing && listing.folders.length > 0 && (
					<div className={css.grid}>
						{listing.files.length > 0 && <SourceTile icon="picture" title={t('webos_folder_media', {count: listing.files.length})} value="" onSelect={openMedia} spotlightId={FIRST_TILE_ID} />}
						{listing.folders.map((f, index) => (
							<SourceTile
								key={f.ref}
								icon={folder.ref === '' && source.kind === 'plex' ? kindIcon('plex') : 'folder'}
								title={f.name}
								value={f.ref}
								onSelect={openFolder}
								spotlightId={index === 0 && listing.files.length === 0 ? FIRST_TILE_ID : undefined}
							/>
						))}
					</div>
				)}
			</Container>
		</Scroller>
	);
};
