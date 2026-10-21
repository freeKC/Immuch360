// Immuch360: a small reader of the ICU messages of the fork's i18n/ files, for the webOS app.
//
// The texts of i18n/*.json use a subset of ICU MessageFormat: {name} arguments, {name, number}, plurals
// ({count, plural, =0 {...} one {# item} other {# items}}, # standing for the number) and selects
// ({name, select, null {...} other {...}}). That subset is what this file reads; anything else is left as it is.
// intl-messageformat would do it all, at the cost of about 50 KB and of Intl features webOS 4 (Chromium 53) lacks.

export type MessageParams = Record<string, string | number | null | undefined>;

type Node =
	| string
	| {kind: 'arg'; name: string}
	| {kind: 'number'; name: string}
	| {kind: 'pound'}
	| {kind: 'plural'; name: string; offset: number; options: Record<string, Node[]>}
	| {kind: 'select'; name: string; options: Record<string, Node[]>};

class Parser {
	private pos = 0;

	constructor(private readonly text: string) {}

	parse(): Node[] {
		const nodes = this.nodes(false);
		if (this.pos < this.text.length) throw new Error('unbalanced }');
		return nodes;
	}

	private nodes(inPlural: boolean): Node[] {
		const out: Node[] = [];
		let literal = '';
		const flush = () => {
			if (literal) out.push(literal);
			literal = '';
		};
		while (this.pos < this.text.length) {
			const c = this.text.charAt(this.pos);
			if (c === '}') break;
			if (c === '{') {
				flush();
				out.push(this.argument());
				continue;
			}
			if (c === '#' && inPlural) {
				flush();
				out.push({kind: 'pound'});
				this.pos++;
				continue;
			}
			if (c === "'") {
				const next = this.text.charAt(this.pos + 1);
				if (next === "'") {
					literal += "'";
					this.pos += 2;
					continue;
				}
				if (next === '{' || next === '}' || (inPlural && next === '#')) {
					const end = this.text.indexOf("'", this.pos + 1);
					if (end > 0) {
						literal += this.text.slice(this.pos + 1, end);
						this.pos = end + 1;
						continue;
					}
				}
			}
			literal += c;
			this.pos++;
		}
		flush();
		return out;
	}

	private skipSpaces(): void {
		while (this.pos < this.text.length && /\s/.test(this.text.charAt(this.pos))) this.pos++;
	}

	private word(): string {
		this.skipSpaces();
		const start = this.pos;
		while (this.pos < this.text.length && !/[\s,{}]/.test(this.text.charAt(this.pos))) this.pos++;
		return this.text.slice(start, this.pos);
	}

	private expect(c: string): void {
		this.skipSpaces();
		if (this.text.charAt(this.pos) !== c) throw new Error(`expected ${c} at ${this.pos}`);
		this.pos++;
	}

	private argument(): Node {
		this.expect('{');
		const name = this.word();
		this.skipSpaces();
		if (this.text.charAt(this.pos) === '}') {
			this.pos++;
			return {kind: 'arg', name};
		}
		this.expect(',');
		const type = this.word();
		this.skipSpaces();
		if (type === 'plural' || type === 'selectordinal' || type === 'select') {
			this.expect(',');
			let offset = 0;
			const options: Record<string, Node[]> = {};
			for (;;) {
				this.skipSpaces();
				if (this.text.charAt(this.pos) === '}') {
					this.pos++;
					break;
				}
				const selector = this.word();
				if (!selector) throw new Error(`empty selector at ${this.pos}`);
				if (selector.indexOf('offset:') === 0) {
					offset = Number(selector.slice(7)) || 0;
					continue;
				}
				this.expect('{');
				options[selector] = this.nodes(type !== 'select');
				this.expect('}');
			}
			return type === 'select' ? {kind: 'select', name, options} : {kind: 'plural', name, offset, options};
		}
		// {name, number} and {name, number, style}: the style is not read, the number is formatted for the locale
		let depth = 0;
		while (this.pos < this.text.length) {
			const c = this.text.charAt(this.pos++);
			if (c === '{') depth++;
			else if (c === '}') {
				if (depth === 0) break;
				depth--;
			}
		}
		return {kind: 'number', name};
	}
}

const cache: Record<string, Node[] | null> = {};

function parse(message: string): Node[] | null {
	if (Object.prototype.hasOwnProperty.call(cache, message)) return cache[message]!;
	let nodes: Node[] | null;
	try {
		nodes = new Parser(message).parse();
	} catch {
		nodes = null;
	}
	cache[message] = nodes;
	return nodes;
}

type PluralRulesLike = {select: (n: number) => string};

const pluralRulesCache: Record<string, PluralRulesLike> = {};

/** The plural category of n in the locale: Intl.PluralRules where the engine has it (Chromium 63+), else English */
export function pluralCategory(locale: string, n: number): string {
	let rules = pluralRulesCache[locale];
	if (!rules) {
		const intl = (typeof Intl !== 'undefined' ? Intl : undefined) as unknown as {PluralRules?: new (locale: string) => PluralRulesLike} | undefined;
		try {
			rules = intl?.PluralRules ? new intl.PluralRules(locale) : undefined;
		} catch {
			rules = undefined;
		}
		rules = rules ?? {select: (value: number) => (value === 1 ? 'one' : 'other')};
		pluralRulesCache[locale] = rules;
	}
	return rules.select(n);
}

/** A number written for the locale, digits grouped; falls back to plain digits */
export function formatNumber(locale: string, n: number): string {
	try {
		return n.toLocaleString(locale);
	} catch {
		return String(n);
	}
}

function render(nodes: Node[], params: MessageParams, locale: string, pound: number | null): string {
	let out = '';
	for (const node of nodes) {
		if (typeof node === 'string') {
			out += node;
			continue;
		}
		switch (node.kind) {
			case 'arg': {
				const value = params[node.name];
				out += value === undefined || value === null ? `{${node.name}}` : typeof value === 'number' ? formatNumber(locale, value) : value;
				break;
			}
			case 'number': {
				const value = Number(params[node.name]);
				out += isFinite(value) ? formatNumber(locale, value) : `{${node.name}}`;
				break;
			}
			case 'pound':
				out += pound === null ? '#' : formatNumber(locale, pound);
				break;
			case 'plural': {
				const n = Number(params[node.name]);
				const value = isFinite(n) ? n - node.offset : 0;
				const exact = node.options['=' + n];
				const branch = exact ?? node.options[pluralCategory(locale, value)] ?? node.options.other ?? [];
				out += render(branch, params, locale, value);
				break;
			}
			case 'select': {
				const raw = params[node.name];
				const key = raw === null ? 'null' : raw === undefined ? 'other' : String(raw);
				out += render(node.options[key] ?? node.options.other ?? [], params, locale, pound);
				break;
			}
		}
	}
	return out;
}

/** The message with its arguments filled in; a message this reader cannot parse is returned as it is */
export function formatMessage(message: string, params: MessageParams = {}, locale = 'en'): string {
	if (message.indexOf('{') < 0 && message.indexOf("'") < 0) return message;
	const nodes = parse(message);
	return nodes ? render(nodes, params, locale, null) : message;
}
