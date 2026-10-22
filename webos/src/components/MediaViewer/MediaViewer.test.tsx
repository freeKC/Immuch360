// Immuch360: the viewer while a turn of the yellow or blue key is saved: it shows that it works, over the photo
// already turned, and the keys go on as before (more presses, Back).
import React from 'react';
import {fireEvent, render, screen} from '@testing-library/react';
import {RepositoryProvider} from '../../domain/RepositoryContext';
import type {PhotoRepository} from '../../domain/PhotoRepository';
import type {TimelineAsset} from '../../domain/types';
import {useAssetRotation, type AssetRotation} from '../../hooks/useAssetRotation';
import {useWebOSKeys} from '../../hooks/useWebOSKeys';
import {MediaViewer} from './MediaViewer';

jest.mock('../../hooks/useAssetRotation', () => ({useAssetRotation: jest.fn()}));
jest.mock('../../hooks/useWebOSKeys', () => ({useWebOSKeys: jest.fn()}));
jest.mock('../../hooks/useAutoHideControls', () => ({useAutoHideControls: () => ({visible: false, show: () => {}, hide: () => {}})}));
jest.mock('../../hooks/useAssetDetails', () => ({useAssetDetails: () => null}));
jest.mock('../../utils/spotlight', () => ({
	forceFocus: () => {},
	SpottableDiv: ({className}: {className?: string}) => <div className={className} />,
	createSpotlightContainer: () => ({className, children}: {className?: string; children?: React.ReactNode}) => <div className={className}>{children}</div>,
}));
jest.mock('./MediaControls', () => ({
	ACTION_BAR_SPOTLIGHT_ID: 'media-viewer-actions',
	MediaControls: ({notice}: {notice?: string}) => (notice ? <p data-testid="notice">{notice}</p> : null),
}));
jest.mock('./VideoPlayer', () => ({VideoPlayer: () => null}));
jest.mock('../../immuch360/sphere/SphereView', () => ({SphereView: () => null}));
jest.mock('../../immuch360/details/AssetDetailsPanel', () => ({AssetDetailsPanel: () => null}));

const photo: TimelineAsset = {id: 'a', type: 'IMAGE', ratio: 1.5, localDateTime: '2026-10-22', durationSeconds: null};
const repository = {
	previewUrl: (id: string) => `/preview/${id}`,
	fullsizeUrl: (id: string) => `/fullsize/${id}`,
	videoPlaybackUrl: (id: string) => `/video/${id}`,
} as unknown as PhotoRepository;
let rotate: jest.Mock;
let onClose: jest.Mock;

const mount = (state: Partial<AssetRotation>) => {
	(useAssetRotation as jest.Mock).mockReturnValue({rotation: 0, rotate, notice: null, phase: 'idle', ...state});
	return render(
		<RepositoryProvider repository={repository}>
			<MediaViewer
				getAssetAt={() => photo}
				totalCount={1}
				currentIndex={0}
				position="1 / 1"
				onClose={onClose}
				onNavigate={() => {}}
				onStartSlideshow={() => {}}
			/>
		</RepositoryProvider>
	);
};
const lastKeys = () => (useWebOSKeys as jest.Mock).mock.calls[(useWebOSKeys as jest.Mock).mock.calls.length - 1][0];

beforeEach(() => {
	localStorage.clear();
	rotate = jest.fn();
	onClose = jest.fn();
	(useWebOSKeys as jest.Mock).mockReset();
});

test('while a turn is saved, the photo already turned shows that it works, and more presses still turn it', () => {
	mount({rotation: 90, phase: 'turning'});
	expect(screen.getByRole('status').textContent).toBe('Saving the rotation');
	// The photo, an image without a text (alt=""), turned at once
	expect(screen.getByRole('presentation').style.transform).toBe('rotate(90deg)');
	fireEvent.keyDown(window, {keyCode: 405});
	fireEvent.keyDown(window, {keyCode: 406});
	expect(rotate.mock.calls).toEqual([[1], [-1]]);
});

test('Back still leaves the viewer while a turn is saved', () => {
	mount({phase: 'turning'});
	lastKeys().onBack();
	expect(onClose).toHaveBeenCalled();
});

test('no indicator once the turned picture is shown', () => {
	mount({phase: 'shown'});
	expect(screen.queryByRole('status')).toBeNull();
});

test('the notice replaces the indicator when the turn stays on the TV or was not saved', () => {
	mount({phase: 'notice', notice: 'keptOnDevice', rotation: 90});
	expect(screen.queryByRole('status')).toBeNull();
	expect(screen.getByTestId('notice').textContent).toBe('The rotation is kept on this device only');
});
