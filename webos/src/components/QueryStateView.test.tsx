// Immuch360: a page offline says so instead of "No albums found.", and a failed page has a Retry
import React from 'react';
import {act, fireEvent, render, screen} from '@testing-library/react';
import {QueryClient, QueryClientProvider} from '@tanstack/react-query';
import {APIError} from '../api/client';
import {t} from '../immuch360/i18n';
import {QueryStateView} from './QueryStateView';

jest.mock('@enact/sandstone/Button', () => ({
	__esModule: true,
	default: ({children, onClick}: any) => <button onClick={onClick}>{children}</button>,
}));

const setOnline = (value: boolean) => Object.defineProperty(window.navigator, 'onLine', {value, configurable: true});

describe('QueryStateView', () => {
	afterEach(() => setOnline(true));

	test('offline, an empty or paused page says the TV has no network', () => {
		setOnline(false);
		render(
			<QueryStateView isLoading={false} error={null} isEmpty emptyText="No albums found.">
				<div>albums</div>
			</QueryStateView>
		);
		expect(screen.getByText(t('webos_error_offline'))).toBeTruthy();
		expect(screen.queryByText('No albums found.')).toBeNull();
	});

	test('what a page already loaded stays on screen offline', () => {
		setOnline(false);
		render(
			<QueryStateView isLoading={false} error={null}>
				<div>albums</div>
			</QueryStateView>
		);
		expect(screen.getByText('albums')).toBeTruthy();
	});

	test('the page follows the network: offline, then back', () => {
		render(
			<QueryStateView isLoading={false} error={null} isEmpty emptyText="No albums found.">
				<div>albums</div>
			</QueryStateView>
		);
		expect(screen.getByText('No albums found.')).toBeTruthy();
		act(() => {
			setOnline(false);
			window.dispatchEvent(new Event('offline'));
		});
		expect(screen.getByText(t('webos_error_offline'))).toBeTruthy();
		act(() => {
			setOnline(true);
			window.dispatchEvent(new Event('online'));
		});
		expect(screen.getByText('No albums found.')).toBeTruthy();
	});

	test("an error shows its cause and a Retry that runs the page's queries again", () => {
		const client = new QueryClient();
		const refetch = jest.spyOn(client, 'refetchQueries').mockResolvedValue(undefined);
		render(
			<QueryClientProvider client={client}>
				<QueryStateView isLoading={false} error={new APIError('x', undefined, 'timeout')}>
					<div>albums</div>
				</QueryStateView>
			</QueryClientProvider>
		);
		expect(screen.getByText(/15 seconds/)).toBeTruthy();
		fireEvent.click(screen.getByText(t('retry')));
		expect(refetch).toHaveBeenCalledWith({type: 'active'});
	});
});
