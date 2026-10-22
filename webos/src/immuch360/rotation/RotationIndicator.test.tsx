import React from 'react';
import {act, render, screen} from '@testing-library/react';
import {RotationIndicator, ROTATION_WAIT_SHOWN_FROM_S} from './RotationIndicator';

const text = () => screen.getByRole('status').textContent;
const wait = (ms: number) =>
	act(() => {
		jest.advanceTimersByTime(ms);
	});

beforeEach(() => jest.useFakeTimers());
afterEach(() => jest.useRealTimers());

test('nothing while no turn is saved', () => {
	const {container} = render(<RotationIndicator active={false} />);
	expect(container.firstChild).toBeNull();
});

test('says at once that the turn is saved, then how long it has been waiting', () => {
	render(<RotationIndicator active />);
	expect(text()).toBe('Saving the rotation');
	wait((ROTATION_WAIT_SHOWN_FROM_S - 1) * 1000);
	expect(text()).toBe('Saving the rotation');
	wait(1000);
	expect(text()).toBe(`Saving the rotation, please wait (${ROTATION_WAIT_SHOWN_FROM_S} s)`);
	wait(9000);
	expect(text()).toBe(`Saving the rotation, please wait (${ROTATION_WAIT_SHOWN_FROM_S + 9} s)`);
});

test('the count each second is not read aloud', () => {
	render(<RotationIndicator active />);
	const label = () => screen.getByText(/Saving the rotation/);
	expect(label().getAttribute('aria-hidden')).toBeNull();
	wait(ROTATION_WAIT_SHOWN_FROM_S * 1000);
	expect(label().getAttribute('aria-hidden')).toBe('true');
});

test('goes away when the turned picture is shown, and counts again from the next turn', () => {
	const {rerender} = render(<RotationIndicator active />);
	wait(5000);
	rerender(<RotationIndicator active={false} />);
	expect(screen.queryByRole('status')).toBeNull();
	rerender(<RotationIndicator active />);
	expect(text()).toBe('Saving the rotation');
});

test('nothing in it takes the focus or the pointer', () => {
	render(<RotationIndicator active />);
	const status = screen.getByRole('status');
	expect(status.getAttribute('aria-live')).toBe('polite');
	expect(status.hasAttribute('tabindex')).toBe(false);
	expect(status.querySelector('[tabindex], button, a, input, [data-spotlight-id]')).toBeNull();
});
