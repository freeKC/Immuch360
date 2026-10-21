import React, {useCallback, useState} from 'react';
import {AlbumCard, albumCardSpotlightId} from '../components/AlbumCard';
import {CollectionGrid} from '../components/CollectionGrid/CollectionGrid';
import {QueryStateView} from '../components/QueryStateView';
import AlbumView from './AlbumView';
import {useAlbums} from '../hooks/useAlbums';
import {useFocusOnReturn} from '../hooks/useFocusOnReturn';
import type {RoutePanelProps} from '../types/navigation';
import {t} from '../immuch360/i18n';

const AlbumsPanel: React.FC<RoutePanelProps> = ({contentWidth}) => {
	const [selectedAlbumId, setSelectedAlbumId] = useState<string | null>(null);
	const {data: albums, isLoading, error} = useAlbums();

	const handleSelectAlbum = useCallback((albumId: string) => {
		setSelectedAlbumId(albumId);
	}, []);

	const handleBack = useCallback(() => setSelectedAlbumId(null), []);
	useFocusOnReturn(selectedAlbumId, albumCardSpotlightId);

	if (selectedAlbumId) {
		return <AlbumView albumId={selectedAlbumId} onBack={handleBack} contentWidth={contentWidth} />;
	}

	return (
		<QueryStateView
			isLoading={isLoading}
			error={error}
			isEmpty={!albums?.length}
			loadingText={t('webos_loading')}
			emptyText={t('webos_albums_empty')}
		>
			<CollectionGrid title={t('albums')} subtitle={albums ? t('albums_count', {count: albums.length}) : undefined}>
				{albums?.map((album) => (
					<AlbumCard key={album.id} album={album} onSelect={handleSelectAlbum} />
				))}
			</CollectionGrid>
		</QueryStateView>
	);
};

export default AlbumsPanel;
