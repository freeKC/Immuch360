// Immuch360: the details of an asset the 360° viewer decides with (name, size, camera), fetched once per asset
import {useQuery} from '@tanstack/react-query';
import {useRepository} from '../domain/RepositoryContext';
import type {AssetDetails} from '../domain/types';

export const useAssetDetails = (assetId: string | undefined, enabled: boolean): AssetDetails | null => {
	const repository = useRepository();
	const query = useQuery({
		queryKey: ['assetDetails', assetId],
		queryFn: () => repository.getAssetDetails(assetId!),
		enabled: enabled && !!assetId,
		staleTime: Infinity,
		retry: false,
	});
	return query.data ?? null;
};
