import {APIError} from '../api/client';
import {AuthMethod} from '../api/types';
import {t} from '../immuch360/i18n';


export function makeAuthErrorMessage(error: unknown, method: AuthMethod): string {
	if (error instanceof APIError) {
		if (error.status === 401) {
			return method === AuthMethod.API_KEY ? t('webos_error_invalid_api_key') : t('webos_error_invalid_credentials');
		}
		if (error.status) return t('webos_error_server_status', {status: String(error.status)});
	}
	return t('webos_error_cors');
}
