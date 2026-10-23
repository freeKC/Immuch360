import {useEffect, useState} from 'react';
import {isOnline} from '../api/network';

/**
 * Immuch360: whether the TV has a network connection, kept up to date by the online and offline events. TanStack Query
 * pauses its requests while offline, which left a page reading "No albums found." when the network dropped.
 */
export function useOnline(): boolean {
	const [online, setOnline] = useState(isOnline);
	useEffect(() => {
		const update = () => setOnline(isOnline());
		window.addEventListener('online', update);
		window.addEventListener('offline', update);
		update();
		return () => {
			window.removeEventListener('online', update);
			window.removeEventListener('offline', update);
		};
	}, []);
	return online;
}
