// CSS rewrites for Chromium 53 (webOS 4) that neither Enact's pipeline nor esbuild performs,
// applied to the minified stylesheet. Chromium 53 drops any declaration or rule it cannot
// parse, so an unlowered value silently loses a whole border, shadow or focus style. Each
// rewrite renders the same on engines that support the original syntax.

const RULE = /([^{}]*)\{([^{}]*)\}/g;

// Every `name(…)` call with its top-level arguments; nested calls are yielded too.
function* functionCalls(css, name) {
	for (const match of css.matchAll(new RegExp(`(?<![\\w-])${name}\\(`, 'g'))) {
		const args = [];
		let depth = 0;
		let argStart = match.index + name.length + 1;
		for (let i = argStart - 1; i < css.length; i++) {
			if (css[i] === '(') depth++;
			else if (css[i] === ',' && depth === 1) {
				args.push(css.slice(argStart, i));
				argStart = i + 1;
			} else if (css[i] === ')' && --depth === 0) {
				args.push(css.slice(argStart, i));
				yield {start: match.index, end: i + 1, args};
				break;
			}
		}
	}
}

const hasAlpha = (rgbArgs) => rgbArgs.length === 2 || rgbArgs.length === 4;
const PERCENT = /(-?[\d.]+)%/;
const toNumber = (percent) => String(+(parseFloat(percent) / 100).toFixed(4));

// Sandstone writes translucent colors as rgb(var(--sand-…-rgb), 30%) and
// rgb(var(--…-rgb), var(--…-alpha, 40%)): four-argument rgb() and percentage alpha are Chrome 65.
export function rgbAlphaToRgba(css) {
	let out = '';
	let cursor = 0;
	for (const {start, end, args} of functionCalls(css, 'rgb')) {
		if (start < cursor || !hasAlpha(args)) continue;
		const alpha = args.pop().trim().replace(PERCENT, (_, number) => toNumber(number));
		out += `${css.slice(cursor, start)}rgba(${args.join(',')},${alpha})`;
		cursor = end;
	}
	return out + css.slice(cursor);
}

// Logical margins/paddings are Chrome 69 (so webOS 5 drops them too); the -webkit- aliases
// date back to Chrome 2/8 and resolve to the same property on newer engines.
const LOGICAL_ALIASES = {
	'margin-inline-start': '-webkit-margin-start',
	'margin-inline-end': '-webkit-margin-end',
	'padding-inline-start': '-webkit-padding-start',
	'padding-inline-end': '-webkit-padding-end',
	'margin-block-start': '-webkit-margin-before',
	'margin-block-end': '-webkit-margin-after',
	'padding-block-start': '-webkit-padding-before',
	'padding-block-end': '-webkit-padding-after',
};
const LOGICAL_DECLARATION = new RegExp(`(^|[;{])(${Object.keys(LOGICAL_ALIASES).join('|')}):([^;}]*)`, 'g');

export function addLogicalAliases(css) {
	return css.replace(LOGICAL_DECLARATION, (_, lead, property, value) => `${lead}${LOGICAL_ALIASES[property]}:${value};${property}:${value}`);
}

// Chromium 53 drops whole rules using ::placeholder (Chrome 57) or :focus-within (Chrome 60).
// The twin follows its rule, so the cascade order is unchanged: newer engines still match
// ::-webkit-input-placeholder with the same declarations, and only the src/polyfills.ts
// fallback ever sets the .focus-within class.
const SELECTOR_TWINS = [
	['::placeholder', '::-webkit-input-placeholder'],
	[':focus-within', '.focus-within'],
];

export function addSelectorTwins(css) {
	return css.replace(RULE, (rule, prelude, body) => {
		// The prelude can start with a preceding statement such as @charset "…";
		const selector = prelude.slice(prelude.lastIndexOf(';') + 1);
		const twin = SELECTOR_TWINS.reduce((text, [modern, legacy]) => text.split(modern).join(legacy), selector);
		return twin === selector ? rule : `${rule}${twin}{${body}}`;
	});
}

export function lowerForChromium53(css) {
	return [rgbAlphaToRgba, addLogicalAliases, addSelectorTwins].reduce((text, lower) => lower(text), css);
}

const STRING_OR_URL = /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|url\([^)]*\)/g;
const UNSUPPORTED_SELECTOR = /:(?:is|where|has)\(|:focus-visible/;
const UNSUPPORTED_VALUE = /#(?:[0-9a-f]{4}|[0-9a-f]{8})(?![\w-])|(?<![\w-])(?:clamp|min|max|env)\(/i;

const isUnsupportedProperty = (property) =>
	!(property in LOGICAL_ALIASES) &&
	!property.startsWith('-') &&
	(/^(?:inset|aspect-ratio|gap)$/.test(property) || /^inset-|-(?:inline|block)(?:-|$)/.test(property));

const isUnsupportedValue = (property, value) =>
	UNSUPPORTED_VALUE.test(value) ||
	(property === 'position' && /\bsticky\b/.test(value)) ||
	(property === 'display' && /\bcontents\b/.test(value)) ||
	[...functionCalls(value, 'rgb')].some(({args}) => hasAlpha(args)) ||
	[...functionCalls(value, 'rgba')].some(({args}) => PERCENT.test(args[args.length - 1]));

// What Chromium 53 would still drop after lowerForChromium53 and esbuild's own lowering.
// CSS grid is deliberately absent: it ships with an @supports fallback (see CollectionGrid).
export function findChromium53Unsupported(css) {
	const found = [];
	for (const [, prelude, body] of css.matchAll(RULE)) {
		if (UNSUPPORTED_SELECTOR.test(prelude)) found.push(prelude.trim());
		for (const declaration of body.replace(STRING_OR_URL, '""').split(';')) {
			const colon = declaration.indexOf(':');
			if (colon === -1) continue;
			const property = declaration.slice(0, colon).trim();
			if (isUnsupportedProperty(property) || isUnsupportedValue(property, declaration.slice(colon + 1))) found.push(declaration.trim());
		}
	}
	return found;
}
