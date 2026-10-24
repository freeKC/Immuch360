// Immuch360: the details of an asset the 360° viewer decides with (name, size, camera), fetched once per asset
import {useQuery} from '@tanstack/react-query';
import {useRepository} from '../domain/RepositoryContext';
import type {AssetDetails} from '../domain/types';

/** The details, and whether their request ended (they came, or it failed): the video check waits for one or the other */
export const useAssetDetailsQuery = (assetId: string | undefined, enabled: boolean): {details: AssetDetails | null; settled: boolean} => {
	const repository = useRepository();
	const query = useQuery({
		queryKey: ['assetDetails', assetId],
		queryFn: () => repository.getAssetDetails(assetId!),
		enabled: enabled && !!assetId,
		staleTime: Infinity,
		retry: false,
	});
	return {details: query.data ?? null, settled: query.isSuccess || query.isError};
};

export const useAssetDetails = (assetId: string | undefined, enabled: boolean): AssetDetails | null => useAssetDetailsQuery(assetId, enabled).details;
