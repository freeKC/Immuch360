// Immuch360: the turn chosen by hand for a video is kept on the TV, so that it opens the right way up next time (issue 17)
import {setVideoTurnChoice, videoTurnChoice} from './turnChoice';

beforeEach(() => window.localStorage.clear());

test('none until one is chosen, then the last one chosen for that video only', () => {
	expect(videoTurnChoice('v1')).toBeNull();
	setVideoTurnChoice('v1', {degrees: 90});
	setVideoTurnChoice('v2', {degrees: 270, fit: 'player'});
	setVideoTurnChoice('v1', {degrees: 180, fit: 'file'});
	expect(videoTurnChoice('v1')).toEqual({degrees: 180, fit: 'file'});
	expect(videoTurnChoice('v2')).toEqual({degrees: 270, fit: 'player'});
	expect(JSON.parse(window.localStorage.getItem('immuch360_video_turns') ?? '{}')).toEqual({v2: {degrees: 270, fit: 'player'}, v1: {degrees: 180, fit: 'file'}});
});

test('a stored value that is not a turn counts as none, a broken store as empty', () => {
	window.localStorage.setItem('immuch360_video_turns', JSON.stringify({a: {degrees: 45}, b: {degrees: 90, fit: 'wide'}, c: 'x', d: {degrees: 0}}));
	expect(videoTurnChoice('a')).toBeNull();
	expect(videoTurnChoice('b')).toBeNull();
	expect(videoTurnChoice('c')).toBeNull();
	expect(videoTurnChoice('d')).toEqual({degrees: 0});
	window.localStorage.setItem('immuch360_video_turns', '{not json');
	expect(videoTurnChoice('d')).toBeNull();
	setVideoTurnChoice('e', {degrees: 90});
	expect(videoTurnChoice('e')).toEqual({degrees: 90});
});

test('the latest 1000 choices are kept', () => {
	for (let i = 0; i < 1002; i++) setVideoTurnChoice(`v${i}`, {degrees: 90});
	expect(videoTurnChoice('v0')).toBeNull();
	expect(videoTurnChoice('v1')).toBeNull();
	expect(videoTurnChoice('v2')).toEqual({degrees: 90});
	expect(videoTurnChoice('v1001')).toEqual({degrees: 90});
});
