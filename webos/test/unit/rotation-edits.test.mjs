// The one-key rotation on the server: the edits it sends are those the editor saves after as many presses on "rotate
// clockwise", and their transform is that of the edits it started from with the turns appended. The cases of the
// Flutter app (mobile/test/unit/utils/editor_compose_test.dart on branch feat-rotate).

import {test, describe} from 'node:test';
import assert from 'node:assert/strict';
import {
	affineOfEdits,
	composeQuarterTurns,
	editsFromServer,
	normalizeQuarterTurns,
	quarterTurnsOfEdits,
} from '../../src/immuch360/rotation/edits.ts';

const rotate = (angle) => ({action: 'rotate', parameters: {angle}});
const mirror = (axis) => ({action: 'mirror', parameters: {axis}});
const crop = () => ({action: 'crop', parameters: {x: 13, y: 7, width: 1001, height: 667}});

const sameTransform = (left, right) => {
	const a = affineOfEdits(left);
	const b = affineOfEdits(right);
	return ['a', 'b', 'c', 'd'].every((k) => Math.abs(a[k] - b[k]) < 1e-9);
};

const describeEdits = (edits) =>
	edits.map((edit) => (edit.action === 'rotate' ? `rotate ${edit.parameters.angle}` : edit.action === 'mirror' ? `mirror ${edit.parameters.axis}` : 'crop')).join(', ');

// Every list the editor or the web can leave: no edit, a rotation, a mirror on either axis, and both in either order
const starts = [[]];
for (const angle of [90, 180, 270]) starts.push([rotate(angle)]);
for (const axis of ['horizontal', 'vertical']) {
	starts.push([mirror(axis)]);
	for (const angle of [90, 180, 270]) {
		starts.push([mirror(axis), rotate(angle)]);
		starts.push([rotate(angle), mirror(axis)]);
	}
}

describe('composeQuarterTurns', () => {
	test('turns the result of any list as appending the rotations would', () => {
		for (const start of starts) {
			for (const turns of [-5, -1, 1, 2, 3, 4, 7]) {
				const composed = composeQuarterTurns(start, turns);
				const appended = [...start, rotate((((90 * turns) % 360) + 360) % 360)];
				assert.ok(sameTransform(composed, appended), `${describeEdits(start)} turned ${turns} times gave ${describeEdits(composed)}`);
			}
		}
	});

	test('keeps at most one mirror and one rotation, in the order of the editor', () => {
		for (const start of starts) {
			for (const turns of [1, 2, 3]) {
				const composed = composeQuarterTurns(start, turns);
				assert.ok(composed.filter((e) => e.action === 'rotate').length <= 1);
				assert.ok(composed.filter((e) => e.action === 'mirror').length <= 1);
				if (composed.length === 2) {
					assert.equal(composed[0].action, 'mirror');
					assert.equal(composed[1].action, 'rotate');
				}
				for (const edit of composed.filter((e) => e.action === 'rotate')) assert.ok([90, 180, 270].includes(edit.parameters.angle));
			}
		}
	});

	test('is what the editor saves after as many presses on rotate clockwise', () => {
		assert.equal(describeEdits(composeQuarterTurns([], 1)), 'rotate 90');
		assert.equal(describeEdits(composeQuarterTurns([rotate(90)], 1)), 'rotate 180');
		assert.equal(describeEdits(composeQuarterTurns([rotate(270)], 1)), '');
		assert.equal(describeEdits(composeQuarterTurns([mirror('vertical')], 1)), 'mirror vertical, rotate 90');
		// A horizontal mirror is a vertical one turned half way, as the editor reads it
		assert.equal(describeEdits(composeQuarterTurns([mirror('horizontal')], 1)), 'mirror vertical, rotate 270');
	});

	test('comes back to no edit at all after four turns, which removes the edits', () => {
		assert.deepEqual(composeQuarterTurns([], 4), []);
		assert.deepEqual(composeQuarterTurns([rotate(90)], 3), []);
		assert.deepEqual(composeQuarterTurns([rotate(180)], -2), []);
	});

	test('keeps the crop first and to the pixel', () => {
		const first = crop();
		for (const turns of [1, 2, 3, 4]) {
			const composed = composeQuarterTurns([first, mirror('horizontal'), rotate(90)], turns);
			assert.equal(composed[0], first, 'the crop is passed on as stored');
			assert.deepEqual(composed[0].parameters, {x: 13, y: 7, width: 1001, height: 667});
		}
		// The crop alone is no reason to remove the edits
		assert.deepEqual(composeQuarterTurns([first, rotate(90)], 3), [first]);
	});

	test('counter clockwise is three turns clockwise', () => {
		for (const start of starts) assert.equal(describeEdits(composeQuarterTurns(start, -1)), describeEdits(composeQuarterTurns(start, 3)));
	});
});

test('quarterTurnsOfEdits reads the rotation of the edits, the mirror aside', () => {
	assert.equal(quarterTurnsOfEdits([]), 0);
	assert.equal(quarterTurnsOfEdits([rotate(90)]), 1);
	assert.equal(quarterTurnsOfEdits([crop(), rotate(270)]), 3);
	assert.equal(quarterTurnsOfEdits([mirror('vertical'), rotate(180)]), 2);
});

test('normalizeQuarterTurns brings any count into 0 to 3', () => {
	assert.deepEqual([-5, -1, 0, 1, 3, 4, 7].map(normalizeQuarterTurns), [3, 3, 0, 1, 3, 0, 3]);
});

test('editsFromServer drops the ids, and refuses a kind of edit it does not know', () => {
	assert.deepEqual(editsFromServer([{id: 'e1', action: 'rotate', parameters: {angle: 90}}]), [rotate(90)]);
	assert.equal(editsFromServer([{id: 'e1', action: 'blur', parameters: {}}]), null);
	assert.deepEqual(editsFromServer([]), []);
});
