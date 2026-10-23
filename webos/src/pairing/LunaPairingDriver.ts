import LS2Request from '@enact/webos/LS2Request';
import type {PairingDriver, PairingStartInfo, PairingPollResult} from './types';
import type {PairingServiceResponse} from './serviceResponse';
import {PairingServiceError, parseStartInfo, parsePollResult} from './serviceResponse';

const SERVICE = 'luna://com.aprogsys.immuch360.service';
const CALL_TIMEOUT_MS = 10000;

function lunaCall(method: string, parameters: Record<string, unknown>): Promise<PairingServiceResponse> {
	return new Promise((resolve, reject) => {
		new LS2Request().send({
			service: SERVICE,
			method,
			parameters,
			timeout: CALL_TIMEOUT_MS,
			onSuccess: resolve,
			onFailure: (res: PairingServiceResponse) => reject(new PairingServiceError(res.errorText || 'Pairing service call failed', res.errorCode)),
			onTimeout: () => reject(new PairingServiceError('Pairing service did not respond', 'no_answer')),
		});
	});
}

export class LunaPairingDriver implements PairingDriver {
	public async start(suggestedUrl?: string): Promise<PairingStartInfo> {
		return parseStartInfo(await lunaCall('start', suggestedUrl ? {suggestedUrl} : {}));
	}

	public async status(): Promise<PairingPollResult> {
		return parsePollResult(await lunaCall('status', {}));
	}

	public async cancel(): Promise<void> {
		await lunaCall('cancel', {});
	}
}
