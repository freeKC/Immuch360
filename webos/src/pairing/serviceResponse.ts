import type {PairingStartInfo, PairingPollResult, PairedAccountResult} from './types';

// One envelope for both pairing transports (luna on TV, HTTP mirror in dev), so a
// service change lands in a single place instead of two parallel copies.
export interface PairingServiceResponse {
	returnValue: boolean;
	errorText?: string;
	// Immuch360: what failed, for the app's own text (service.js: no_address, listen_failed)
	errorCode?: string;
	url?: string;
	code?: string;
	state?: string;
	result?: PairedAccountResult;
}

/**
 * Immuch360: a failed call to the pairing service. The message is the service's own English, for the log; code says
 * what failed, for the text on screen: no_address (the TV has no network address), listen_failed (the phone page could
 * not start), no_answer (the service did not answer), bad_answer, failed.
 */
export class PairingServiceError extends Error {
	public code: string;

	constructor(message: string, code?: string | null) {
		super(message);
		this.name = 'PairingServiceError';
		this.code = code || 'failed';
	}
}

export function parseStartInfo(res: PairingServiceResponse): PairingStartInfo {
	if (!res.url || !res.code) throw new PairingServiceError('Pairing service returned no URL', 'bad_answer');
	return {url: res.url, code: res.code};
}

export function parsePollResult(res: PairingServiceResponse): PairingPollResult {
	if (res.state === 'approved' && res.result) return {state: 'approved', result: res.result};
	if (res.state === 'pending') return {state: 'pending'};
	// none/consumed/expired: the session is gone either way — restart.
	return {state: 'expired'};
}
