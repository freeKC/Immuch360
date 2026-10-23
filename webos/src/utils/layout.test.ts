// Immuch360: the width of the pages follows the rail of each package (the 1280x720 one included)
import ri from '@enact/ui/resolution';
import {contentWidthNow} from './layout';

const screenTypes = [
	{name: 'hd', pxPerRem: 16, width: 1280, height: 720, aspectRatioName: 'hdtv'},
	{name: 'fhd', pxPerRem: 24, width: 1920, height: 1080, aspectRatioName: 'hdtv'},
	{name: 'uhd', pxPerRem: 48, width: 3840, height: 2160, aspectRatioName: 'hdtv', base: true},
];

function at(width: number, height: number): number {
	Object.defineProperty(window, 'innerWidth', {value: width, configurable: true});
	Object.defineProperty(window, 'innerHeight', {value: height, configurable: true});
	ri.defineScreenTypes(screenTypes);
	ri.init({measurementNode: window});
	return contentWidthNow();
}

describe('the width of the pages', () => {
	test('1920x1080: the window less a rail of 180 px', () => {
		expect(at(1920, 1080)).toBe(1740);
	});

	test('1280x720: the window less a rail of 144 px, wider than the scale alone gives (120) so that its labels fit', () => {
		expect(at(1280, 720)).toBe(1136);
	});
});
