// Immuch360: Enact's popups close with the Back of a Samsung remote and with the Cancel of its keyboard, and the text
// input popup takes the text on the keyboard's Done (src/platform/keymap.ts)
import {is} from '@enact/core/keymap';
import {addTizenKeymap} from './keymap';

test('Back 10009 and IME Cancel 65385 are cancel, IME Done 65376 is enter', () => {
	addTizenKeymap();
	expect(is('cancel', 10009)).toBe(true);
	expect(is('cancel', 65385)).toBe(true);
	expect(is('enter', 65376)).toBe(true);
	// Enact's own Enter stays, Back is no Enter
	expect(is('enter', 13)).toBe(true);
	expect(is('enter', 10009)).toBe(false);
});
