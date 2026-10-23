import {APIError} from '../api/client';
import {isOnline, REQUEST_TIMEOUT_MS, type FailureKind} from '../api/network';
import {t} from '../immuch360/i18n';

/** Immuch360: the message of a request that got no answer from the server, by its cause */
export function failureMessage(kind: FailureKind): string {
	if (kind === 'offline') return t('webos_error_offline');
	if (kind === 'timeout') return t('webos_error_timeout', {seconds: String(REQUEST_TIMEOUT_MS / 1000)});
	if (kind === 'cors') return t('webos_error_cors');
	return t('webos_error_unreachable');
}

export function presentError(err: unknown): string {
	if (err instanceof APIError) {
		if (err.kind) return failureMessage(err.kind);
		if (err.status === 401) return t('webos_error_sign_in_again');
		if (err.status === 403) return t('webos_error_access_denied');
		if (err.status === 404) return t('webos_error_not_found');
		if (err.status && err.status >= 500) return t('webos_error_server_unavailable');
		if (!err.status) return failureMessage(isOnline() ? 'unreachable' : 'offline');
	}
	if (!isOnline()) return failureMessage('offline');
	return t('errors.something_went_wrong');
}
