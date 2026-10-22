// Immuch360: the bridge for the source screens: the shared client, kept alive while a screen that uses it is shown.

import {useEffect, useSyncExternalStore} from 'react';
import {BridgeClient} from './bridgeClient';
import {sourceStore} from './store';
import {createBridgeTransport} from './transport';
import type {BridgeError, BridgeInfo, SourceConfig} from './types';

let client: BridgeClient | null | undefined;

/** The client of the app, null where no service answers (a production build in a browser) */
export function bridgeClient(): BridgeClient | null {
	if (client === undefined) {
		const transport = createBridgeTransport();
		client = transport ? new BridgeClient(transport, sourceStore()) : null;
	}
	return client;
}

const noSubscribe = () => () => undefined;

export interface BridgeState {
	client: BridgeClient | null;
	info: BridgeInfo | null;
	error: BridgeError | null;
	/** Changes when the bridge restarts: the URLs built before it no longer work */
	version: number;
}

/** The bridge, started and held while the calling screen is mounted */
export function useBridge(): BridgeState {
	const c = bridgeClient();
	useEffect(() => (c ? c.hold() : undefined), [c]);
	const version = useSyncExternalStore(c ? (l: () => void) => c.subscribe(l) : noSubscribe, () => (c ? c.version() * 2 + (c.error() ? 1 : 0) : 0));
	return {client: c, info: c ? c.current() : null, error: c ? c.error() : null, version};
}

/** The sources kept on the TV, following their changes */
export function useSources(): SourceConfig[] {
	const store = sourceStore();
	return useSyncExternalStore((l: () => void) => store.subscribe(l), () => store.list());
}
