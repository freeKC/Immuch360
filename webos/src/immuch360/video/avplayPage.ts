// Immuch360: AVPlay draws on the TV's video plane, under the web page: the page shows it only where nothing of its own
// is painted. While AVPlay plays, every ancestor of the player loses its background (the viewer's black, the app's
// theme, body and html) and what lies beside the viewer (the grid, the rail) is hidden. The viewer's own top bar and
// Sandstone's transport bar stay over the picture, as over the HTML video. Everything is put back as it was when the
// player closes. Moonfin, a Jellyfin client for Samsung TVs, makes its page transparent the same way (read for facts
// only).

/** The attribute that marks the viewer, the part of the page that stays visible over the video plane */
export const VIEWER_MARK = 'data-immuch360-viewer';

/** Marks the page while AVPlay plays, for the tests and the diagnostics */
export const AVPLAY_PAGE_CLASS = 'immuch360-avplay';

/** Clears the page over the video plane for the player's node; returns what puts it back */
export function clearPageForVideoPlane(node: HTMLElement): () => void {
	const undo: (() => void)[] = [];
	const viewer = typeof node.closest === 'function' ? node.closest(`[${VIEWER_MARK}]`) : null;
	let aboveViewer = false;
	for (let element: HTMLElement | null = node; element; element = element.parentElement) {
		const target = element;
		const background = target.style.getPropertyValue('background');
		const priority = target.style.getPropertyPriority('background');
		target.style.setProperty('background', 'transparent', 'important');
		undo.push(() => {
			target.style.removeProperty('background');
			if (background) target.style.setProperty('background', background, priority);
		});
		if (target === viewer) aboveViewer = true;
		// Beside the viewer and its ancestors: hidden, up to body
		if (aboveViewer && target !== document.body && target !== document.documentElement && target.parentElement) {
			for (const sibling of Array.from(target.parentElement.children)) {
				if (sibling === target || !(sibling instanceof HTMLElement) || sibling.tagName === 'SCRIPT' || sibling.tagName === 'STYLE') continue;
				const visibility = sibling.style.getPropertyValue('visibility');
				const visibilityPriority = sibling.style.getPropertyPriority('visibility');
				sibling.style.setProperty('visibility', 'hidden', 'important');
				undo.push(() => {
					sibling.style.removeProperty('visibility');
					if (visibility) sibling.style.setProperty('visibility', visibility, visibilityPriority);
				});
			}
		}
	}
	document.documentElement.classList.add(AVPLAY_PAGE_CLASS);
	let done = false;
	return () => {
		if (done) return;
		done = true;
		for (const step of undo.reverse()) step();
		document.documentElement.classList.remove(AVPLAY_PAGE_CLASS);
	};
}
