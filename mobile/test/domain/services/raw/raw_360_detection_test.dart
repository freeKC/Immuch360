import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import '../../../fixtures/raw/insta360.stub.dart';

ByteRangeReader _reader(Uint8List file, [List<(int, int)>? reads]) => (offset, length) async {
  reads?.add((offset, length));
  final start = math.min(offset, file.length);
  return Uint8List.sublistView(file, start, math.min(file.length, start + length));
};

void main() {
  group('names', () {
    test('an Insta360 photo is .insp, a video .insv, whatever the case', () {
      expect(isRawPhotoName('IMG_20240908_133036_00_001.insp'), isTrue);
      expect(isRawPhotoName('IMG_001.INSP'), isTrue);
      expect(isRawPhotoName('IMG_001.insp.jpg'), isFalse);
      expect(isRawVideoName('VID_20240908_133036_00_002.insv'), isTrue);
      expect(isRawVideoName('VID_002.INSV'), isTrue);
      expect(isRawVideoName('LRV_20240908_133036_01_004.lrv'), isFalse);
      expect(isRawVideoName('VID_002.mp4'), isFalse);
    });
  });

  group('rawVideoLayout', () {
    test('two squares side by side, else one lens; side by side while the frame is unknown', () {
      expect(isSideBySideFrame(5760, 2880), isTrue);
      expect(isSideBySideFrame(1024, 512), isTrue);
      expect(isSideBySideFrame(2880, 2880), isFalse);
      expect(isSideBySideFrame(null, 2880), isNull);
      expect(rawVideoLayout(5760, 2880), Raw360Layout.dualFisheye);
      expect(rawVideoLayout(3840, 3840), Raw360Layout.separateLenses);
      expect(rawVideoLayout(null, null), Raw360Layout.dualFisheye);
    });

    test('raw360LayoutOf tells by the name, and by the frame for a video', () {
      expect(raw360LayoutOf(name: 'IMG_001.insp', isVideo: false), Raw360Layout.dualFisheye);
      expect(raw360LayoutOf(name: 'IMG_001.jpg', isVideo: false), isNull);
      expect(
        raw360LayoutOf(name: 'VID_00_002.insv', isVideo: true, width: 5760, height: 2880),
        Raw360Layout.dualFisheye,
      );
      expect(
        raw360LayoutOf(name: 'VID_10_002.insv', isVideo: true, width: 2880, height: 2880),
        Raw360Layout.separateLenses,
      );
      expect(raw360LayoutOf(name: 'VID_002.mp4', isVideo: true, width: 5760, height: 2880), isNull);
      // A photo named like a video is no raw video
      expect(raw360LayoutOf(name: 'VID_002.insv', isVideo: false), isNull);
    });

    test('rawVideoFrameSize prefers what the file declares', () {
      const probe = SphericalProbe(codedWidth: 5760, codedHeight: 2880);
      expect(rawVideoFrameSize(probe: probe, width: 2880, height: 2880), (width: 5760, height: 2880));
      expect(rawVideoFrameSize(probe: const SphericalProbe(), width: 2880, height: 2880), (width: 2880, height: 2880));
      expect(rawVideoFrameSize(), isNull);
    });
  });

  test('a stitched raw media is one picture over the whole sphere', () {
    expect(raw360SphereView.layout, StereoLayout.mono);
    expect(raw360SphereView.coverage, SphereCoverage.full);
    expect(raw360SphereView.coverageGuess, SphereCoverage.full);
  });

  group('hasInsta360Trailer', () {
    test('finds the trailer of a version 3 file in its last 72 bytes', () async {
      final file = insta360File([insta360Record(1, x3Metadata(), format: 1)], body: List.filled(5000, 0));
      final reads = <(int, int)>[];

      expect(await hasInsta360Trailer(_reader(file, reads), file.length), isTrue);
      expect(reads, [(file.length - 72, 72)]);
    });

    test('refuses another magic, another version, and a file too short', () async {
      final otherMagic = insta360File([], magic: '9c792b1ac55c40418d36ffb0d1d16b58');
      final version2 = insta360File([], version: 2);
      final jpeg = Uint8List.fromList(List.filled(1000, 0));

      expect(await hasInsta360Trailer(_reader(otherMagic), otherMagic.length), isFalse);
      expect(await hasInsta360Trailer(_reader(version2), version2.length), isFalse);
      expect(await hasInsta360Trailer(_reader(jpeg), jpeg.length), isFalse);
      expect(await hasInsta360Trailer(_reader(jpeg), 10), isFalse);
    });
  });

  test('RawVideoUnsupportedException names the video', () {
    expect(const RawVideoUnsupportedException('VID_10_002.insv').toString(), contains('VID_10_002.insv'));
  });
}
