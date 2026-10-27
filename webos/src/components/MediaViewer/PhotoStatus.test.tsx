// Immuch360: the two pills of the viewer over a flat photo (PhotoStatus.tsx): the loading pill and the zoom level
import React from 'react';
import {act, render, screen} from '@testing-library/react';
import {ZOOM_LEVEL_SHOWN_MS} from '../../immuch360/viewerStatus';
import {PhotoLoading, ZoomLevel} from './PhotoStatus';

const wait = (ms: number) =>
	act(() => {
		jest.advanceTimersByTime(ms);
	});

beforeEach(() => jest.useFakeTimers());
afterEach(() => jest.useRealTimers());

test('the loading pill: nothing while nothing loads, "Loading…" with a spinner the screen reader skips', () => {
	const {container, rerender} = render(<PhotoLoading active={false} />);
	expect(container.firstChild).toBeNull();
	rerender(<PhotoLoading active />);
	const status = screen.getByRole('status');
	expect(status.textContent).toBe('Loading…');
	expect(status.querySelector('[aria-hidden="true"]')).not.toBeNull();
});

test('the zoom level: nothing before a zoom key, then the level for 1.5 s from each press', () => {
	const {rerender} = render(<ZoomLevel pulse={0} scale={1} />);
	expect(screen.queryByRole('status')).toBeNull();
	rerender(<ZoomLevel pulse={1} scale={1.25} />);
	expect(screen.getByRole('status').textContent).toBe('125%');
	wait(ZOOM_LEVEL_SHOWN_MS - 500);
	rerender(<ZoomLevel pulse={2} scale={1.5625} />);
	expect(screen.getByRole('status').textContent).toBe('156%');
	wait(ZOOM_LEVEL_SHOWN_MS - 1);
	expect(screen.getByRole('status').textContent).toBe('156%');
	wait(1);
	expect(screen.queryByRole('status')).toBeNull();
});

test('the zoom level gives way to the pill of a turn, and does not come back after it', () => {
	const {rerender} = render(<ZoomLevel pulse={1} scale={1.25} />);
	rerender(<ZoomLevel pulse={1} scale={1} hidden />);
	expect(screen.queryByRole('status')).toBeNull();
	wait(ZOOM_LEVEL_SHOWN_MS);
	rerender(<ZoomLevel pulse={1} scale={1} />);
	expect(screen.queryByRole('status')).toBeNull();
});

test('nothing in either pill takes the focus or the pointer', () => {
	render(
		<>
			<PhotoLoading active />
			<ZoomLevel pulse={1} scale={1.25} />
		</>
	);
	const pills = screen.getAllByRole('status');
	expect(pills).toHaveLength(2);
	for (const pill of pills) {
		expect(pill.getAttribute('aria-live')).toBe('polite');
		expect(pill.hasAttribute('tabindex')).toBe(false);
		expect(pill.querySelector('[tabindex], button, a, input, [data-spotlight-id]')).toBeNull();
	}
});
