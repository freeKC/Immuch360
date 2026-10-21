import {APIError} from '../api/client';
import {t} from '../immuch360/i18n';

export function presentError(err: unknown): string {
	if (err instanceof APIError) {
		if (err.status === 401) return t('webos_error_sign_in_again');
		if (err.status === 403) return t('webos_error_access_denied');
		if (err.status === 404) return t('webos_error_not_found');
		if (err.status && err.status >= 500) return t('webos_error_server_unavailable');
		if (!err.status) return t('webos_error_unreachable');
	}
	return t('errors.something_went_wrong');
}
