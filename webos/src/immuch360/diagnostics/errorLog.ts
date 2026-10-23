// Immuch360: the last uncaught errors and content security policy blocks since the app started, for the About page.
// A TV has no console at hand: the page and its QR code are how a tester reports what went wrong. On a Samsung TV the
// policy of config.xml is written out (tizen/config.xml), and a block shows here.
//
// Addresses lose their query and fragment: a picture or video address carries the sign in (apiKey, sessionKey), and
// the page goes into public bug reports.

export const ERROR_LOG_SIZE = 5;

const entries: string[] = [];
let started = false;

/** An address without its query and fragment; the text as it is when it is no address */
export function withoutQuery(address: string): string {
	return address.replace(/[?#].*$/, '');
}

/** A message with the values of key, apiKey, sessionKey and token parameters hidden */
export function withoutKeys(message: string): string {
	return message.replace(/((?:api|session)?key|token)=[^&\s"')]+/gi, '$1=…');
}

/** Keeps a line, the oldest going once there are ERROR_LOG_SIZE */
export function recordError(line: string): void {
	entries.push(withoutKeys(line).slice(0, 300));
	if (entries.length > ERROR_LOG_SIZE) entries.splice(0, entries.length - ERROR_LOG_SIZE);
}

/** The lines kept, oldest first */
export const lastErrors = (): string[] => entries.slice();

/** For the tests: forgets the lines */
export function clearErrorLog(): void {
	entries.length = 0;
}

interface PolicyEvent {
	violatedDirective?: string;
	effectiveDirective?: string;
	blockedURI?: string;
}

/** The line of a content security policy block: "policy: img-src blocked http://host/path" */
export function policyLine(event: PolicyEvent): string {
	const directive = event.effectiveDirective || event.violatedDirective || '?';
	return `policy: ${directive} blocked ${withoutQuery(event.blockedURI || '') || '?'}`;
}

/** The line of an uncaught error: "error: message (file:line)" */
export function errorLine(message: string, file?: string, line?: number): string {
	const where = file ? ` (${withoutQuery(file).replace(/^.*\//, '')}${line ? `:${line}` : ''})` : '';
	return `error: ${message || '?'}${where}`;
}

function reasonText(reason: unknown): string {
	if (reason instanceof Error) return reason.message;
	return typeof reason === 'string' ? reason : String(reason);
}

/** Starts listening, once, before the first render */
export function startErrorLog(): void {
	if (started || typeof window === 'undefined') return;
	started = true;
	window.addEventListener('error', (event: ErrorEvent) => recordError(errorLine(event.message, event.filename, event.lineno)));
	window.addEventListener('unhandledrejection', (event: PromiseRejectionEvent) => recordError(`promise: ${reasonText(event.reason)}`));
	document.addEventListener('securitypolicyviolation', (event: Event) => recordError(policyLine(event as unknown as PolicyEvent)));
}
