import React, {useCallback, useState} from 'react';
import {PlaceCard, placeCardSpotlightId} from '../components/PlaceCard';
import {CollectionGrid} from '../components/CollectionGrid/CollectionGrid';
import {QueryStateView} from '../components/QueryStateView';
import PlaceView from './PlaceView';
import {usePlaces} from '../hooks/usePlaces';
import {useFocusOnReturn} from '../hooks/useFocusOnReturn';
import type {RoutePanelProps} from '../types/navigation';
import {t} from '../immuch360/i18n';

const PlacesPanel: React.FC<RoutePanelProps> = ({contentWidth}) => {
	const [selectedCity, setSelectedCity] = useState<string | null>(null);
	const {data: places, isLoading, error} = usePlaces();

	const handleSelectPlace = useCallback((city: string) => {
		setSelectedCity(city);
	}, []);

	const handleBack = useCallback(() => setSelectedCity(null), []);
	useFocusOnReturn(selectedCity, placeCardSpotlightId);

	if (selectedCity) {
		return <PlaceView city={selectedCity} onBack={handleBack} contentWidth={contentWidth} />;
	}

	return (
		<QueryStateView
			isLoading={isLoading}
			error={error}
			isEmpty={!places?.length}
			loadingText={t('webos_loading')}
			emptyText={t('webos_places_empty')}
		>
			<CollectionGrid title={t('places')} subtitle={places ? t('places_count', {count: places.length}) : undefined}>
				{places?.map((place) => (
					<PlaceCard key={place.city} place={place} onSelect={handleSelectPlace} />
				))}
			</CollectionGrid>
		</QueryStateView>
	);
};

export default PlacesPanel;
