// The one-key rotation on the server: the edits it sends are those the editor saves after as many presses on "rotate
// clockwise", and their transform is that of the edits it started from with the turns appended.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/utils/editor.utils.dart';
import 'package:openapi/api.dart' show CropParameters, MirrorAxis, MirrorParameters, RotateParameters;

RotateEdit _rotate(int angle) => RotateEdit(RotateParameters(angle: angle));
MirrorEdit _mirror(MirrorAxis axis) => MirrorEdit(MirrorParameters(axis: axis));
CropEdit _crop() => CropEdit(CropParameters(x: 13, y: 7, width: 1001, height: 667));

bool _sameTransform(List<AssetEdit> a, List<AssetEdit> b) {
  final left = buildAffineFromEdits(a);
  final right = buildAffineFromEdits(b);
  return (left.a - right.a).abs() < 1e-9 &&
      (left.b - right.b).abs() < 1e-9 &&
      (left.c - right.c).abs() < 1e-9 &&
      (left.d - right.d).abs() < 1e-9;
}

String _describe(List<AssetEdit> edits) => edits
    .map(
      (edit) => switch (edit) {
        RotateEdit(:final parameters) => 'rotate ${parameters.angle}',
        MirrorEdit(:final parameters) => 'mirror ${parameters.axis}',
        CropEdit() => 'crop',
      },
    )
    .join(', ');

void main() {
  // Every list the editor or the web can leave: no edit, a rotation, a mirror on either axis, and both in either order
  final starts = <List<AssetEdit>>[
    [],
    for (final angle in [90, 180, 270]) [_rotate(angle)],
    for (final axis in [MirrorAxis.horizontal, MirrorAxis.vertical]) ...[
      [_mirror(axis)],
      for (final angle in [90, 180, 270]) ...[
        [_mirror(axis), _rotate(angle)],
        [_rotate(angle), _mirror(axis)],
      ],
    ],
  ];

  group('composeQuarterTurns', () {
    test('turns the result of any list as appending the rotations would', () {
      for (final start in starts) {
        for (final turns in [-5, -1, 1, 2, 3, 4, 7]) {
          final composed = composeQuarterTurns(start, turns);
          final appended = [...start, _rotate(((90 * turns) % 360 + 360) % 360)];
          expect(
            _sameTransform(composed, appended),
            isTrue,
            reason: '${_describe(start)} turned $turns times gave ${_describe(composed)}',
          );
        }
      }
    });

    test('keeps at most one mirror and one rotation, in the order of the editor', () {
      for (final start in starts) {
        for (final turns in [1, 2, 3]) {
          final composed = composeQuarterTurns(start, turns);
          expect(composed.whereType<RotateEdit>().length, lessThanOrEqualTo(1));
          expect(composed.whereType<MirrorEdit>().length, lessThanOrEqualTo(1));
          if (composed.length == 2) {
            expect(composed.first, isA<MirrorEdit>());
            expect(composed.last, isA<RotateEdit>());
          }
          for (final rotate in composed.whereType<RotateEdit>()) {
            expect([90, 180, 270], contains(rotate.parameters.angle));
          }
        }
      }
    });

    test('is what the editor saves after as many presses on rotate clockwise', () {
      expect(_describe(composeQuarterTurns([], 1)), 'rotate 90');
      expect(_describe(composeQuarterTurns([_rotate(90)], 1)), 'rotate 180');
      expect(_describe(composeQuarterTurns([_rotate(270)], 1)), '');
      expect(_describe(composeQuarterTurns([_mirror(MirrorAxis.vertical)], 1)), 'mirror vertical, rotate 90');
      // A horizontal mirror is a vertical one turned half way, as the editor reads it
      expect(_describe(composeQuarterTurns([_mirror(MirrorAxis.horizontal)], 1)), 'mirror vertical, rotate 270');
    });

    test('comes back to no edit at all after four turns, which removes the edits', () {
      expect(composeQuarterTurns([], 4), isEmpty);
      expect(composeQuarterTurns([_rotate(90)], 3), isEmpty);
      expect(composeQuarterTurns([_rotate(180)], -2), isEmpty);
    });

    test('keeps the crop first and to the pixel', () {
      final crop = _crop();
      for (final turns in [1, 2, 3, 4]) {
        final composed = composeQuarterTurns([crop, _mirror(MirrorAxis.horizontal), _rotate(90)], turns);
        expect(identical(composed.first, crop), isTrue, reason: 'the crop is passed on as stored');
        final parameters = (composed.first as CropEdit).parameters;
        expect((parameters.x, parameters.y, parameters.width, parameters.height), (13, 7, 1001, 667));
      }
      // The crop alone is no reason to remove the edits
      expect(composeQuarterTurns([crop, _rotate(90)], 3), [crop]);
    });

    test('counter clockwise is three turns clockwise', () {
      for (final start in starts) {
        expect(_describe(composeQuarterTurns(start, -1)), _describe(composeQuarterTurns(start, 3)));
      }
    });
  });

  group('quarterTurnsOfEdits', () {
    test('reads the rotation of the edits, the mirror aside', () {
      expect(quarterTurnsOfEdits([]), 0);
      expect(quarterTurnsOfEdits([_rotate(90)]), 1);
      expect(quarterTurnsOfEdits([_crop(), _rotate(270)]), 3);
      expect(quarterTurnsOfEdits([_mirror(MirrorAxis.vertical), _rotate(180)]), 2);
    });
  });
}
