// Immuch360: one message per cause of a failure, so that no network does not read as a CORS problem
import {APIError} from '../api/client';
import {AuthMethod} from '../api/types';
import {makeAuthErrorMessage} from '../hooks/_authHelpers';
import {t} from '../immuch360/i18n';
import {presentError} from './presentError';

const setOnline = (value: boolean) => Object.defineProperty(window.navigator, 'onLine', {value, configurable: true});

describe('the messages of a request without an answer', () => {
	afterEach(() => setOnline(true));

	test('each cause has its own message, in the pages and at sign in', () => {
		const offline = presentError(new APIError('x', undefined, 'offline'));
		const timeout = presentError(new APIError('x', undefined, 'timeout'));
		const cors = presentError(new APIError('x', undefined, 'cors'));
		const unreachable = presentError(new APIError('x', undefined, 'unreachable'));
		expect(new Set([offline, timeout, cors, unreachable]).size).toBe(4);
		expect(offline).toBe(t('webos_error_offline'));
		expect(timeout).toContain('15');
		expect(cors).toContain('CORS');
		expect(unreachable).not.toContain('CORS');
		expect(makeAuthErrorMessage(new APIError('x', undefined, 'offline'), AuthMethod.USER_CREDENTIALS)).toBe(offline);
		expect(makeAuthErrorMessage(new APIError('x', undefined, 'cors'), AuthMethod.API_KEY)).toBe(cors);
	});

	test('the CORS message is no longer the answer to every failure', () => {
		expect(makeAuthErrorMessage(new TypeError('Failed to fetch'), AuthMethod.USER_CREDENTIALS)).toBe(t('webos_error_unreachable'));
		setOnline(false);
		expect(makeAuthErrorMessage(new TypeError('Failed to fetch'), AuthMethod.USER_CREDENTIALS)).toBe(t('webos_error_offline'));
		expect(presentError(new Error('anything'))).toBe(t('webos_error_offline'));
	});

	test('answers of the server keep their messages', () => {
		expect(presentError(new APIError('x', 401))).toBe(t('webos_error_sign_in_again'));
		expect(presentError(new APIError('x', 503))).toBe(t('webos_error_server_unavailable'));
		expect(makeAuthErrorMessage(new APIError('x', 401), AuthMethod.API_KEY)).toBe(t('webos_error_invalid_api_key'));
	});
});
