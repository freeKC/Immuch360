import {useQuery, type QueryKey, type UseQueryOptions, type UseQueryResult} from '@tanstack/react-query';
import {APIError} from '../api/client';
import {useRepository} from '../domain/RepositoryContext';
import type {PhotoRepository} from '../domain/PhotoRepository';

/**
 * Shared TanStack Query configuration for asset-related queries.
 * Provides consistent caching, stale time, and retry behavior.
 */
export const ASSETS_QUERY_CONFIG = {
	staleTime: 5 * 60 * 1000, // 5 minutes
	gcTime: 10 * 60 * 1000, // 10 minutes
	refetchOnWindowFocus: false,
	refetchOnMount: false,
	retry: (failureCount: number, error: unknown) => {
		// Don't retry on 401 (auth error)
		if (error instanceof APIError && error.status === 401) return false;
		// Immuch360: a page says why it failed soon after the 15 s of a request (src/api/network.ts): offline or a CORS
		// refusal do not change with a retry; a timeout gets one more try (a cold smart search can take longer once),
		// so the message comes after about 31 s (15 + 1 + 15), not 48
		if (error instanceof APIError && (error.kind === 'offline' || error.kind === 'cors')) return false;
		if (error instanceof APIError && error.kind === 'timeout') return failureCount < 1;
		return failureCount < 2;
	},
};

export function useRepositoryQuery<T>(
	queryKey: QueryKey,
	fetcher: (r: PhotoRepository) => Promise<T>,
	options?: Partial<Omit<UseQueryOptions<T>, 'queryKey' | 'queryFn'>>,
): UseQueryResult<T> {
	const repository = useRepository();
	return useQuery({
		queryKey,
		queryFn: () => fetcher(repository),
		...ASSETS_QUERY_CONFIG,
		...options,
	});
}
