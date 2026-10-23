import React from 'react';
import {act, render, screen} from '@testing-library/react';
import Spotlight from '@enact/spotlight';
import {spottableClass} from '@enact/spotlight/Spottable';
import {NAVIGATION_RAIL_ID} from '../../utils/constants';
import {NavigationRail} from './NavigationRail';

jest.mock('@enact/sandstone/Icon', () => ({
	__esModule: true,
	default: ({children}: {children: React.ReactNode}) => <i>{children}</i>,
}));

describe('NavigationRail', () => {
	beforeEach(() => Spotlight.initialize({selector: '.spottable'}));
	afterEach(() => Spotlight.terminate());

	test('registers every button as a Spotlight target', () => {
		render(
			<NavigationRail
				activeView="photos"
				onNavigate={() => {}}
				onOpenAccount={() => {}}
				accountLetter="Q"
				accountGradient="#123456"
			/>
		);

		const buttons = screen.getAllByRole('button');
		const rail = buttons[0]?.closest(`#${NAVIGATION_RAIL_ID}`);
		expect(rail).not.toBeNull();
		// Immuch360: Photos, Albums, Places, Search, Network shares, About, Account
		expect(buttons).toHaveLength(7);
		buttons.forEach(button => expect(button.classList.contains(spottableClass)).toBe(true));
	});

	test('keeps the replacement rail focusable when an account switch remounts the layout', () => {
		const accountLayout = (account: string) => (
			<div key={account}>
				<NavigationRail activeView="photos" onNavigate={() => {}} onOpenAccount={() => {}} accountLetter={account} accountGradient="#123456" />
			</div>
		);
		const {rerender} = render(accountLayout('Q'));
		for (const account of ['M', 'Q', 'M']) {
			rerender(accountLayout(account));
			act(() => {
				Spotlight.setPointerMode(false);
				expect(Spotlight.focus(`#${NAVIGATION_RAIL_ID}`)).toBe(true);
			});
			expect(document.activeElement).toBe(screen.getByRole('button', {name: /Photos/}));
		}
	});
	// Immuch360: LG's self checklist, item 6: a label cut with an ellipsis or rolling; the page shown is marked
	test('each label is a Marquee (ellipsis, rolls on focus) and the active item says aria-current', () => {
		render(<NavigationRail activeView="sources" onNavigate={() => {}} onOpenAccount={() => {}} accountLetter="Q" accountGradient="#123456" />);
		const shares = screen.getByRole('button', {name: /Network shares/});
		expect(shares.getAttribute('aria-current')).toBe('page');
		expect(screen.getByRole('button', {name: /Photos/}).getAttribute('aria-current')).toBeNull();
		const label = shares.querySelector('[data-rail-label]');
		expect(label?.textContent).toBe('Network shares');
		// The Marquee wraps its text in its own clipping box
		expect(label?.children.length).toBeGreaterThan(0);
	});
});
