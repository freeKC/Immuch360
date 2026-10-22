// Immuch360: how the page reaches the bridge's Luna methods: the Luna bus on the TV, the HTTP stand-in of
// service/dev.js on a computer (npm run serve), nothing in a plain browser.

import LS2Request from '@enact/webos/LS2Request';
import type {BridgeTransport} from './bridgeClient';

const SERVICE = 'luna://com.aprogsys.immuch360.service';
const DEV_BASE = 'http://127.0.0.1:8788';
const CALL_TIMEOUT_MS = 30000;

class LunaTransport implements BridgeTransport {
	call(method: string, parameters: Record<string, unknown>): Promise<Record<string, unknown>> {
		return new Promise((resolve, reject) => {
			new LS2Request().send({
				service: SERVICE,
				method,
				parameters,
				timeout: CALL_TIMEOUT_MS,
				onSuccess: resolve,
				onFailure: (res: Record<string, unknown>) => reject(res),
				onTimeout: () => reject({errorText: 'The app service did not answer', errorCode: 'timeout'}),
			});
		});
	}
}

class HttpTransport implements BridgeTransport {
	async call(method: string, parameters: Record<string, unknown>): Promise<Record<string, unknown>> {
		const response = await fetch(`${DEV_BASE}/bridge/${method}`, {
			method: 'POST',
			headers: {'Content-Type': 'application/json'},
			body: JSON.stringify(parameters),
		});
		return (await response.json()) as Record<string, unknown>;
	}
}

const hasServiceBridge = (): boolean => typeof (window as {WebOSServiceBridge?: unknown}).WebOSServiceBridge === 'function';

/** The transport of this run, null when there is none (a production build in a browser) */
export function createBridgeTransport(): BridgeTransport | null {
	if (hasServiceBridge()) return new LunaTransport();
	if (process.env.NODE_ENV !== 'production') return new HttpTransport();
	return null;
}
