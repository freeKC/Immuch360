// Immuch360: which of the fork's locale files fits the language of the TV.
//
// The files of i18n/ are named after Weblate's codes: "fr", "pt_BR", "zh_Hans", "nb_NO", "sr_Latn", "yue_Hant"...
// A TV reports BCP 47 tags: "fr-FR", "pt-BR", "zh-Hant-TW", "zh-TW", "nb-NO", "no", "sr-Latn-RS". The rules below
// pick the closest file, English when none fits.

const TRADITIONAL_CHINESE_REGIONS = ['tw', 'hk', 'mo'];

function find(available: readonly string[], name: string): string | null {
	const lower = name.toLowerCase();
	for (const candidate of available) {
		if (candidate.toLowerCase() === lower) return candidate;
	}
	return null;
}

/** The locale file for one BCP 47 tag, or null */
export function matchLocale(tag: string, available: readonly string[]): string | null {
	const parts = tag.replace(/_/g, '-').split('-').filter(Boolean);
	const language = (parts[0] ?? '').toLowerCase();
	if (!language) return null;
	let script = '';
	let region = '';
	for (const part of parts.slice(1)) {
		if (part.length === 4 && !script) script = part.charAt(0).toUpperCase() + part.slice(1).toLowerCase();
		else if ((part.length === 2 || part.length === 3) && !region) region = part.toUpperCase();
	}
	if (language === 'zh') {
		const traditional = script === 'Hant' || (!script && TRADITIONAL_CHINESE_REGIONS.indexOf(region.toLowerCase()) >= 0);
		return find(available, traditional ? 'zh_Hant' : 'zh_Hans');
	}
	if (language === 'yue') return find(available, 'yue_Hant');
	if (language === 'no' || language === 'nb') return find(available, 'nb_NO');
	if (language === 'sr') return find(available, script === 'Latn' ? 'sr_Latn' : 'sr_Cyrl');
	if (language === 'fil' || language === 'tl') return find(available, language) ?? find(available, language === 'fil' ? 'tl' : 'fil');
	return (
		(script && find(available, `${language}_${script}`)) ||
		(region && find(available, `${language}_${region}`)) ||
		find(available, language)
	);
}

/** The first of the preferred tags that has a locale file, else "en" */
export function pickLocale(preferred: readonly string[], available: readonly string[]): string {
	for (const tag of preferred) {
		if (!tag) continue;
		const match = matchLocale(tag, available);
		if (match) return match;
	}
	return 'en';
}

/** The BCP 47 tag of a locale file, for Intl: "pt_BR" gives "pt-BR", "zh_Hans" gives "zh-Hans", "nb_NO" "nb-NO" */
export function localeTag(locale: string): string {
	return locale.replace(/_/g, '-');
}
