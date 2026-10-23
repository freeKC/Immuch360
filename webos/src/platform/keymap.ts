// Immuch360: the Samsung keys Enact's keymap must know. Enact closes its popups on "cancel" (only 461, LG's Back, added
// by Sandstone's ThemeDecorator) and its text input popup takes the text on "enter" (13). A Samsung remote sends Back
// as 10009, and the Samsung on screen keyboard sends Done as 65376 and Cancel as 65385 (Samsung's IME guide). Added on
// every TV: no LG remote sends these codes for anything else.

import {addAll} from '@enact/core/keymap';

export const SAMSUNG_KEYMAP: Record<string, number[]> = {
	cancel: [10009, 65385],
	enter: [65376],
};

export function addTizenKeymap(): void {
	addAll(SAMSUNG_KEYMAP);
}
