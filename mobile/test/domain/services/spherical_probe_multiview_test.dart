import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import 'spherical_probe_fixtures.dart';

// The boxes of an Apple spatial video (MV-HEVC), as the stereo video format of Apple writes them: lhvC beside hvcC,
// vexu with eyes, and hfov beside vexu

List<int> _lhvC() => mp4Box('lhvC', [1, ...mp4Zeros(20)]);

List<int> _stri(int flags) => mp4FullBox('stri', [flags]);

List<int> _hero(int eye) => mp4FullBox('hero', [eye]);

List<int> _cams(int baselineMicrometres) => mp4Box('cams', mp4FullBox('blin', mp4Uint32(baselineMicrometres)));

List<int> _cmfy(int disparity) => mp4Box('cmfy', mp4FullBox('dadj', mp4Uint32(disparity & 0xffffffff)));

List<int> _vexu(List<List<int>> eyesChildren, {bool eyesAsFullBox = false}) => mp4Box('vexu', [
  ...mp4Box('must', mp4Uint32(0)),
  ...(eyesAsFullBox
      ? mp4FullBox('eyes', [for (final child in eyesChildren) ...child])
      : mp4Box('eyes', [for (final child in eyesChildren) ...child])),
]);

List<int> _hfov(int thousandths) => mp4Box('hfov', mp4Uint32(thousandths));

/// The probe of a file whose only video track has the sample entry children [children] after its hvcC
Future<SphericalProbe> _probe(List<List<int>> children) {
  final file = Uint8List.fromList(
    mp4File(mp4Moov([mp4VideoTrack(children, config: mp4HvcC(), width: 1920, height: 1080)])),
  );
  return probeSphericalMetadata(
    (offset, length) async => offset >= file.length
        ? Uint8List(0)
        : Uint8List.sublistView(file, offset, math.min(file.length, offset + length)),
  );
}

void main() {
  group('probeSphericalMetadata, Apple spatial videos', () {
    test('reads every field of a spatial video', () async {
      final probe = await _probe([
        _lhvC(),
        _vexu([_stri(0x03), _hero(2), _cams(19240), _cmfy(200)]),
        _hfov(63400),
      ]);

      expect(
        probe.multiview,
        const MultiviewInfo(
          heroEye: 2,
          baselineMicrometres: 19240,
          disparityAdjustment: 200,
          horizontalFovDegrees: 63.4,
        ),
      );
      // The rest of the probe is the base layer, an HEVC video like any other
      expect(probe.codec, 'hvc1');
      expect(probe.codedWidth, 1920);
    });

    test('a negative disparity and reversed eyes', () async {
      final probe = await _probe([
        _lhvC(),
        _vexu([_stri(0x0b), _cmfy(-150)]),
      ]);

      expect(probe.multiview, const MultiviewInfo(heroEye: 0, disparityAdjustment: -150, eyesReversed: true));
    });

    test('lhvC without vexu is no spatial video', () async {
      expect((await _probe([_lhvC()])).multiview, isNull);
    });

    test('vexu without lhvC is no spatial video', () async {
      expect(
        (await _probe([
          _vexu([_stri(0x03)]),
        ])).multiview,
        isNull,
      );
    });

    test('one eye only is no spatial video', () async {
      expect(
        (await _probe([
          _lhvC(),
          _vexu([_stri(0x01)]),
        ])).multiview,
        isNull,
      );
    });

    test('a stri with its reserved bits set is not trusted', () async {
      expect(
        (await _probe([
          _lhvC(),
          _vexu([_stri(0x13)]),
        ])).multiview,
        isNull,
      );
    });

    test('eyes written as a full box', () async {
      final probe = await _probe([
        _lhvC(),
        _vexu([_stri(0x03), _hero(1), _cams(64000)], eyesAsFullBox: true),
      ]);

      expect(probe.multiview, const MultiviewInfo(heroEye: 1, baselineMicrometres: 64000));
    });

    test('a plain HEVC video has no multiview', () async {
      expect((await _probe([])).multiview, isNull);
    });

    test('multiview takes part in equality', () {
      const info = MultiviewInfo(heroEye: 1);
      expect(const SphericalProbe(multiview: info), const SphericalProbe(multiview: MultiviewInfo(heroEye: 1)));
      expect(const SphericalProbe(multiview: info) == const SphericalProbe(), isFalse);
      expect(const SphericalProbe(multiview: info).toString(), contains('MultiviewInfo(hero: 1'));
    });
  });
}
