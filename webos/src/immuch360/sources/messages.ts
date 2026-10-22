// Immuch360: what the source screens say when the bridge or a source answers with an error.

import {t} from '../i18n';
import type {SourceKind} from './types';

interface ErrorLike {
	message?: string;
	code?: string | null;
}

function parts(error: unknown): {message: string; code: string | null} {
	if (error && typeof error === 'object') {
		const e = error as ErrorLike;
		return {message: e.message || String(error), code: e.code ?? null};
	}
	return {message: String(error), code: null};
}

/** Why the bridge itself is not there: an old TV, or a service that did not start */
export function bridgeErrorText(error: unknown): string {
	const {message, code} = parts(error);
	if (code === 'needs_webos5') return t('webos_sources_needs_webos5');
	return t('webos_service_unavailable', {error: message});
}

/** The error of a source, in the words of its kind */
export function sourceErrorText(error: unknown, kind: SourceKind, host?: string): string {
	const {message, code} = parts(error);
	if (code === 'needs_webos5') return t('webos_sources_needs_webos5');
	if (code === 'smb_needs_node12') return t('webos_smb_needs_webos22');
	if (code === 'bridge_unavailable' || code === 'timeout') return t('webos_service_unavailable', {error: message});
	if (kind === 'tapo') {
		if (code === 'auth') return t('camera_error_wrong_password');
		if (code === 'unreachable' || /ECONNREFUSED|EHOSTUNREACH|ETIMEDOUT|does not answer/.test(message)) return t('camera_error_unreachable', {host: host || ''});
		if (code === 'h265') return t('webos_camera_live_h265');
		return t('camera_live_failed', {error: message});
	}
	if (kind === 'plex') {
		if (code === 'token_refused') return t('plex_token_refused');
		if (code === 'token_forbidden') return t('plex_token_forbidden');
		if (/ECONNREFUSED|EHOSTUNREACH|ETIMEDOUT|did not answer/.test(message)) return t('plex_server_unreachable');
	}
	return t('network_share_failed', {error: message});
}
