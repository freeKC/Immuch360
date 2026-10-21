// Immuch360: the texts of the webOS app, from the fork's i18n/ files.
//
// tools/build-i18n.mjs reads the keys this app uses (the t('key') and i18nKey('key') calls of src/) and writes:
// - generated/en.json, the English texts, bundled so that a text is always there;
// - generated/locales.json, the names of the locale files;
// - at pack time, dist/i18n/<locale>.json for every other locale, with the keys it translates.
// The locale of the TV is loaded before the first render (loadLocale); a key it lacks falls back to English.

import {formatMessage, type MessageParams} from './format';
import {localeTag, pickLocale} from './locale';
import en from './generated/en.json';
import locales from './generated/locales.json';

const english = en as Record<string, string>;
let messages: Record<string, string> = english;
let current = 'en';
let loadError: string | null = null;

/** The text of a key in the language of the TV, its arguments filled in */
export function t(key: string, params?: MessageParams): string {
	const message = messages[key] ?? english[key];
	return message === undefined ? key : formatMessage(message, params, localeTag(current));
}

/** Marks a key held in a constant, so that tools/build-i18n.mjs keeps it; returns it as it is */
export const i18nKey = (key: string): string => key;

/** The locale file in use: "en", "fr", "pt_BR"... */
export const currentLocale = (): string => current;

/** The BCP 47 tag of the locale in use, for Intl and toLocaleString */
export const currentLocaleTag = (): string => (current === 'en' ? 'en-US' : localeTag(current));

/** Why the locale could not be loaded, null when it was (or when English is used) */
export const localeLoadError = (): string | null => loadError;

/** The locale files the app ships, English included */
export const availableLocales = (): string[] => ['en'].concat((locales as string[]).filter((name) => name !== 'en'));

function preferredLanguages(): string[] {
	if (typeof navigator === 'undefined') return [];
	const list = (navigator.languages as readonly string[] | undefined) ?? [];
	return list.length ? list.slice() : [navigator.language];
}

// XMLHttpRequest rather than fetch: the app runs from file:// on the TV, which fetch does not read
function readJson(url: string, timeoutMs: number): Promise<Record<string, string>> {
	return new Promise((resolve, reject) => {
		const request = new XMLHttpRequest();
		request.open('GET', url, true);
		request.timeout = timeoutMs;
		request.onload = () => {
			// file:// answers with status 0
			if (request.status !== 0 && (request.status < 200 || request.status >= 300)) {
				reject(new Error(`HTTP ${request.status}`));
				return;
			}
			try {
				resolve(JSON.parse(request.responseText) as Record<string, string>);
			} catch (error) {
				reject(error);
			}
		};
		request.onerror = () => reject(new Error('read error'));
		request.ontimeout = () => reject(new Error('timeout'));
		request.send();
	});
}

/**
 * Picks the locale file for the languages of the TV and loads it. Never fails: on any error the app stays in English
 * and the reason is kept for the diagnostics page.
 */
export async function loadLocale(preferred: string[] = preferredLanguages()): Promise<string> {
	const picked = pickLocale(preferred, availableLocales());
	if (picked === 'en') {
		current = 'en';
		messages = english;
		return current;
	}
	try {
		const loaded = await readJson(`i18n/${picked}.json`, 3000);
		messages = Object.assign({}, english, loaded);
		current = picked;
		loadError = null;
	} catch (error) {
		loadError = `${picked}: ${error instanceof Error ? error.message : String(error)}`;
		messages = english;
		current = 'en';
	}
	return current;
}
