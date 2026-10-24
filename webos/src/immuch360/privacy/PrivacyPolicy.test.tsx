// Immuch360: the privacy policy is reachable inside the app (LG's Privacy Guideline): a button opens a layer with the
// address of the policy and its QR code; Back and Close close it
import React from 'react';
import {fireEvent, render, screen} from '@testing-library/react';
import {PRIVACY_POLICY_URL, PRIVACY_POLICY_URL_TIZEN, PrivacyPolicyButton, privacyPolicyUrl} from './PrivacyPolicy';

jest.mock('@enact/sandstone/Button', () => ({
	__esModule: true,
	default: ({children, onClick}: any) => <button onClick={onClick}>{children}</button>,
}));

describe('the privacy policy in the app', () => {
	test("its address is the LG TVs section of the repository's PRIVACY.md", () => {
		expect(PRIVACY_POLICY_URL).toBe('https://github.com/freeKC/Immuch360/blob/immuch360/PRIVACY.md#lg-tvs-webos');
	});

	test('on a Samsung TV it is the Samsung TVs section, in the layer as well', () => {
		expect(PRIVACY_POLICY_URL_TIZEN).toBe('https://github.com/freeKC/Immuch360/blob/immuch360/PRIVACY.md#samsung-tvs-tizen');
		expect(privacyPolicyUrl()).toBe(PRIVACY_POLICY_URL);
		(window as {tizen?: unknown}).tizen = {application: {}};
		try {
			expect(privacyPolicyUrl()).toBe(PRIVACY_POLICY_URL_TIZEN);
			render(<PrivacyPolicyButton />);
			fireEvent.click(screen.getByText('Privacy policy'));
			expect(screen.getByText(PRIVACY_POLICY_URL_TIZEN)).toBeTruthy();
			expect(screen.queryByText(PRIVACY_POLICY_URL)).toBeNull();
		} finally {
			delete (window as {tizen?: unknown}).tizen;
		}
	});

	test('the button opens the layer with the address and its QR code; Close closes it', () => {
		render(<PrivacyPolicyButton />);
		expect(screen.queryByRole('dialog')).toBeNull();
		fireEvent.click(screen.getByText('Privacy policy'));
		expect(screen.getByRole('dialog')).toBeTruthy();
		expect(screen.getByText(PRIVACY_POLICY_URL)).toBeTruthy();
		expect(screen.getByRole('dialog').getElementsByTagName('canvas')).toHaveLength(1);
		fireEvent.click(screen.getByText('Close'));
		expect(screen.queryByRole('dialog')).toBeNull();
	});

	test('Back closes the layer and goes no further', () => {
		render(<PrivacyPolicyButton />);
		fireEvent.click(screen.getByText('Privacy policy'));
		const event = new KeyboardEvent('keydown', {key: 'GoBack', keyCode: 461, bubbles: true, cancelable: true} as KeyboardEventInit);
		React.act(() => {
			window.dispatchEvent(event);
		});
		expect(event.defaultPrevented).toBe(true);
		expect(screen.queryByRole('dialog')).toBeNull();
	});
});
