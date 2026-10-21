// Runtime polyfills for webOS 4.x (Chrome 53) and 5.x (Chrome 68). Each one is
// feature-guarded, so this file is a no-op on modern Chromium. Enact's core-js entry only
// covers what the browserslist floor (Chrome 79) lacks; lowering that floor would add ~40 KB
// of core-js and replace Promise/RegExp on webOS 4, hence these hand-rolled versions.
// globalThis and Object.getOwnPropertyDescriptors are needed before any bundle code runs:
// tools/transpile-legacy.mjs prepends them to main.js.
//
// Language built-ins (Chrome version that introduced each):
//   Object.entries / Object.values  (Chrome 54) — used by Enact event handling
//   String.prototype.padStart/padEnd (Chrome 57) — used in ImmichRepository, FormattingService
//   Promise.prototype.finally       (Chrome 63) — used in slideshow, @tanstack/query-core
//   AbortController                 (Chrome 66) — created by @tanstack/query-core for every query
//   Array.prototype.flat            (Chrome 69) — used in ImmichRepository
//   Array.prototype.flatMap         (Chrome 69) — used in TimelineGrid, MainPanel
//   Object.fromEntries              (Chrome 73) — used in NavigationRail
//   Promise.allSettled              (Chrome 76) — safety
// DOM:
//   :focus-within (class fallback)  (Chrome 60) — Sandstone InputField, paired with tools/legacy-css.mjs
//   Element.prototype.scrollTo/By   (Chrome 61) — used by the Enact/Sandstone Scroller
//   focus({preventScroll})          (Chrome 64) — used by Enact Spotlight in overflow containers
//
// All assignments use `as any` casts because the TypeScript lib already declares
// these on the prototypes, and reassigning them in TS code requires the cast.

if (!Array.prototype.flat) {
	(Array.prototype as any).flat = function flat(depth = 1) {
		const flatten = (arr: any[], d: number): any[] =>
			d > 0
				? arr.reduce((acc: any[], val: any) => acc.concat(Array.isArray(val) ? flatten(val, d - 1) : val), [])
				: arr.slice();
		return flatten(this as any[], depth);
	};
}

if (!Array.prototype.flatMap) {
	(Array.prototype as any).flatMap = function flatMap(callback: (value: any, index: number, array: any[]) => any, thisArg?: any) {
		return (this as any[]).map(callback, thisArg).reduce((acc: any[], val: any) => acc.concat(val), []);
	};
}

if (!Object.fromEntries) {
	(Object as any).fromEntries = function fromEntries(entries: Iterable<readonly [PropertyKey, any]>) {
		const obj: Record<PropertyKey, any> = {};
		for (const [key, value] of entries as any) {
			obj[key] = value;
		}
		return obj;
	};
}

if (!Promise.allSettled) {
	(Promise as any).allSettled = function allSettled(promises: Iterable<Promise<any>>) {
		return Promise.all(
			Array.from(promises, (p) =>
				Promise.resolve(p).then(
					(value) => ({status: 'fulfilled' as const, value}),
					(reason) => ({status: 'rejected' as const, reason}),
				),
			),
		);
	};
}

if (!Object.entries) {
	(Object as any).entries = function entries(obj: object) {
		return Object.keys(obj).map((key) => [key, (obj as any)[key]]);
	};
}

if (!Object.values) {
	(Object as any).values = function values(obj: object) {
		return Object.keys(obj).map((key) => (obj as any)[key]);
	};
}

if (!String.prototype.padStart) {
	const padding = (str: string, targetLength: number, padString: unknown = ' ') => {
		const filler = String(padString);
		const missing = targetLength - str.length;
		if (missing <= 0 || !filler) return '';
		return filler.repeat(Math.ceil(missing / filler.length)).slice(0, missing);
	};
	(String.prototype as any).padStart = function padStart(targetLength: number, padString?: string) {
		const str = String(this);
		return padding(str, targetLength, padString) + str;
	};
	(String.prototype as any).padEnd = function padEnd(targetLength: number, padString?: string) {
		const str = String(this);
		return str + padding(str, targetLength, padString);
	};
}

if (!(Promise.prototype as any).finally) {
	(Promise.prototype as any).finally = function finally_<T>(this: Promise<T>, onFinally?: () => unknown) {
		if (typeof onFinally !== 'function') return this.then(onFinally, onFinally);
		return this.then(
			(value) => Promise.resolve(onFinally()).then(() => value),
			(reason) => Promise.resolve(onFinally()).then(() => {
				throw reason;
			}),
		);
	};
}

// Covers what @tanstack/query-core uses: `aborted` and 'abort' listeners. The engines that need
// it ignore fetch's signal, so a cancelled request still completes.
if (typeof AbortController === 'undefined') {
	type AbortListener = (event: {type: 'abort'}) => void;

	class AbortSignalPolyfill {
		aborted = false;
		private listeners: AbortListener[] = [];

		addEventListener(type: string, listener: AbortListener) {
			if (type === 'abort') this.listeners.push(listener);
		}

		removeEventListener(type: string, listener: AbortListener) {
			if (type === 'abort') this.listeners = this.listeners.filter((registered) => registered !== listener);
		}

		dispatchAbort() {
			this.aborted = true;
			const listeners = this.listeners;
			this.listeners = [];
			listeners.forEach((listener) => listener.call(this, {type: 'abort'}));
		}
	}

	class AbortControllerPolyfill {
		readonly signal = new AbortSignalPolyfill();

		abort() {
			if (!this.signal.aborted) this.signal.dispatchAbort();
		}
	}

	(window as any).AbortSignal = AbortSignalPolyfill;
	(window as any).AbortController = AbortControllerPolyfill;
}

const supportsSelector = (selector: string) => {
	try {
		document.querySelector(selector);
		return true;
	} catch {
		return false;
	}
};

const supportsFocusOptions = () => {
	let optionsRead = false;
	document.createElement('div').focus({
		get preventScroll() {
			optionsRead = true;
			return false;
		},
	});
	return optionsRead;
};

// No smooth scrolling: `behavior` is ignored and the position is applied immediately.
if (!Element.prototype.scrollTo) {
	const toScrollOptions = (xOrOptions?: number | ScrollToOptions, y?: number): ScrollToOptions =>
		typeof xOrOptions === 'object' && xOrOptions !== null ? xOrOptions : {left: xOrOptions, top: y};
	(Element.prototype as any).scrollTo = function scrollTo(this: Element, xOrOptions?: number | ScrollToOptions, y?: number) {
		const {left, top} = toScrollOptions(xOrOptions, y);
		if (left !== undefined) this.scrollLeft = left;
		if (top !== undefined) this.scrollTop = top;
	};
	(Element.prototype as any).scrollBy = function scrollBy(this: Element, xOrOptions?: number | ScrollToOptions, y?: number) {
		const {left = 0, top = 0} = toScrollOptions(xOrOptions, y);
		this.scrollTo({left: this.scrollLeft + left, top: this.scrollTop + top});
	};
}

// Spotlight focuses with {preventScroll: true} inside overflow containers such as the timeline,
// whose scrolling useTimelineViewportFocus owns. Chromium 53 scrolls the element into view
// before dispatching the focus events, so the scroll is undone by a window capture listener,
// ahead of every focus handler: what those handlers scroll is kept.
if (!supportsFocusOptions()) {
	const nativeFocus = HTMLElement.prototype.focus;
	(HTMLElement.prototype as any).focus = function focus(this: HTMLElement, options?: FocusOptions) {
		if (!options || !options.preventScroll) return nativeFocus.call(this);
		const positions: [Element, number, number][] = [];
		for (let node = this.parentElement; node; node = node.parentElement) positions.push([node, node.scrollTop, node.scrollLeft]);
		let undone = false;
		const undoNativeScroll = () => {
			if (undone) return;
			undone = true;
			window.removeEventListener('focus', undoNativeScroll, true);
			window.removeEventListener('focusin', undoNativeScroll, true);
			positions.forEach(([node, top, left]) => {
				node.scrollTop = top;
				node.scrollLeft = left;
			});
		};
		window.addEventListener('focus', undoNativeScroll, true);
		window.addEventListener('focusin', undoNativeScroll, true);
		nativeFocus.call(this);
		// No focus event fires when the element was already focused.
		undoNativeScroll();
	};
}

// :focus-within styles Sandstone's InputField while typing. tools/legacy-css.mjs twins every
// such rule with a `.focus-within` class, which this keeps on the focused element's ancestors.
// Only ancestors a twin rule can match get the class: tagging the whole chain up to <html>
// would restyle the document each time the pointer leaves a card and Spotlight blurs it.
if (!supportsSelector(':focus-within')) {
	const FOCUS_WITHIN_CLASS = 'focus-within';
	const focusWithinSubjects = () => {
		const subjects = new Set<string>();
		const collect = (rules: CSSRuleList) =>
			Array.from(rules).forEach((rule) => {
				if ('cssRules' in rule) collect((rule as CSSGroupingRule).cssRules);
				((rule as CSSStyleRule).selectorText || '').split(/\s*[\s>+~,]\s*/).forEach((compound) => {
					if (compound.indexOf(`.${FOCUS_WITHIN_CLASS}`) === -1) return;
					const element = compound.replace(`.${FOCUS_WITHIN_CLASS}`, '').replace(/::?[\w-]+(\([^)]*\))?/g, '');
					subjects.add(element || '*');
				});
			});
		Array.from(document.styleSheets).forEach((sheet) => {
			try {
				collect((sheet as CSSStyleSheet).cssRules);
			} catch {
				// Cross-origin stylesheets can't be read and carry no twin rules.
			}
		});
		return Array.from(subjects).join(',');
	};

	const subjects = focusWithinSubjects();
	if (subjects) {
		let tagged: Element[] = [];
		const retag = (focused: Element | null) => {
			const next: Element[] = [];
			for (let node = focused; node; node = node.parentElement) if (node.matches(subjects)) next.push(node);
			tagged.forEach((el) => {
				if (next.indexOf(el) === -1) el.classList.remove(FOCUS_WITHIN_CLASS);
			});
			next.forEach((el) => el.classList.add(FOCUS_WITHIN_CLASS));
			tagged = next;
		};
		document.addEventListener('focusin', (event) => retag(event.target as Element), true);
		document.addEventListener('focusout', (event) => {
			if (!(event as FocusEvent).relatedTarget) retag(null);
		}, true);
	}
}
