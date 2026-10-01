import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import 'spherical_probe_fixtures.dart';

/// Reads [file] as a local file or a server does: fewer bytes at the end, none past it. Records each read.
ByteRangeReader _reader(Uint8List file, [List<(int, int)>? reads]) => (offset, length) async {
  reads?.add((offset, length));
  if (offset >= file.length) {
    return Uint8List(0);
  }
  return Uint8List.sublistView(file, offset, math.min(file.length, offset + length));
};

Future<SphericalProbe> _probe(Uint8List file, {List<(int, int)>? reads, int? maxMoovLength}) => maxMoovLength == null
    ? probeSphericalMetadata(_reader(file, reads))
    : probeSphericalMetadata(_reader(file, reads), maxMoovLength: maxMoovLength);

void main() {
  group('probeSphericalMetadata', () {
    test('reads the stereo layout of the st3d box', () async {
      for (final (mode, expected) in [
        (0, StereoLayout.mono),
        (1, StereoLayout.topBottom),
        (2, StereoLayout.leftRight),
        (3, null),
      ]) {
        final probe = await _probe(
          mp4File(
            mp4Moov([
              mp4VideoTrack([mp4St3d(mode)]),
            ]),
          ),
        );

        expect(probe, SphericalProbe(stereo: expected), reason: 'stereo_mode $mode');
      }
    });

    test('takes an equirectangular projection cropped to half the width for a half sphere', () async {
      final probe = await _probe(
        mp4File(
          mp4Moov([
            mp4VideoTrack([mp4St3d(2), mp4Sv3dEquirectangular(left: 0.25, right: 0.25)]),
          ]),
        ),
      );

      expect(probe, const SphericalProbe(stereo: StereoLayout.leftRight, halfSphere: true, hasSphericalMetadata: true));
    });

    test('takes an equirectangular projection with full bounds for a full sphere', () async {
      final probe = await _probe(
        mp4File(
          mp4Moov([
            mp4VideoTrack([mp4St3d(1), mp4Sv3dEquirectangular()]),
          ]),
        ),
      );

      expect(
        probe,
        const SphericalProbe(stereo: StereoLayout.topBottom, halfSphere: false, hasSphericalMetadata: true),
      );
    });

    test('takes other crops for no half sphere', () async {
      for (final (left, right) in [(0.1, 0.1), (0.35, 0.35), (0.0, 0.0)]) {
        final probe = await _probe(
          mp4File(
            mp4Moov([
              mp4VideoTrack([mp4Sv3dEquirectangular(left: left, right: right)]),
            ]),
          ),
        );

        expect(probe.halfSphere, isFalse, reason: 'left $left right $right');
      }
      // Within 0.4 to 0.6 of the width cropped
      final uneven = await _probe(
        mp4File(
          mp4Moov([
            mp4VideoTrack([mp4Sv3dEquirectangular(left: 0.4, right: 0.15)]),
          ]),
        ),
      );
      expect(uneven.halfSphere, isTrue);
    });

    test('takes a mesh projection, as VR180 cameras write it, for a half sphere', () async {
      final probe = await _probe(
        mp4File(
          mp4Moov([
            mp4VideoTrack([mp4St3d(2), mp4Sv3dProjection(mp4Mshp())]),
          ]),
        ),
      );

      expect(probe, const SphericalProbe(stereo: StereoLayout.leftRight, halfSphere: true, hasSphericalMetadata: true));
    });

    test('takes a cube map for no half sphere', () async {
      final probe = await _probe(
        mp4File(
          mp4Moov([
            mp4VideoTrack([mp4Sv3dProjection(mp4FullBox('cbmp', mp4Zeros(8)))]),
          ]),
        ),
      );

      expect(probe, const SphericalProbe(halfSphere: false, hasSphericalMetadata: true));
    });

    test('finds nothing declared in a regular video', () async {
      final probe = await _probe(mp4File(mp4Moov([mp4VideoTrack([]), mp4AudioTrack()])));

      expect(probe, const SphericalProbe());
      expect(probe.hasSphericalMetadata, isFalse);
      expect(probe.halfSphere, isNull);
      expect(probe.stereo, isNull);
    });

    test('reads every visual sample entry, H.264 and AV1 included', () async {
      for (final codec in ['avc1', 'avc3', 'hev1', 'av01', 'vp09', 'mp4v']) {
        final probe = await _probe(
          mp4File(
            mp4Moov([
              mp4VideoTrack([mp4Sv3dProjection(mp4Mshp())], codec: codec),
            ]),
          ),
        );

        expect(probe.halfSphere, isTrue, reason: codec);
      }
    });

    test('skips the tracks that are no video', () async {
      final probe = await _probe(
        mp4File(
          mp4Moov([
            mp4AudioTrack(),
            mp4VideoTrack([mp4St3d(1), mp4Sv3dEquirectangular(left: 0.25, right: 0.25)]),
          ]),
        ),
      );

      expect(probe.stereo, StereoLayout.topBottom);
      expect(probe.halfSphere, isTrue);
    });

    test('finds the moov box at the end of a recording, reading box headers only past the media data', () async {
      const mediaLength = 2 * 1024 * 1024;
      final file = mp4File(
        mp4Moov([
          mp4VideoTrack([mp4St3d(2), mp4Sv3dProjection(mp4Mshp())]),
        ]),
        moovAtEnd: true,
        mdat: mp4Box('mdat', mp4Zeros(mediaLength)),
      );
      final reads = <(int, int)>[];

      final probe = await _probe(file, reads: reads);

      expect(probe.halfSphere, isTrue);
      expect(probe.stereo, StereoLayout.leftRight);
      final bytesRead = reads.fold(0, (total, read) => total + read.$2);
      expect(bytesRead, lessThan(256 * 1024), reason: 'not the media data: $reads');
      expect(reads, hasLength(lessThanOrEqualTo(3)));
    });

    test('reads the head of the file once when the moov box is in it', () async {
      final reads = <(int, int)>[];

      final probe = await _probe(
        mp4File(
          mp4Moov([
            mp4VideoTrack([mp4Sv3dProjection(mp4Mshp())]),
          ]),
        ),
        reads: reads,
      );

      expect(probe.halfSphere, isTrue);
      expect(reads, [(0, 64 * 1024)]);
    });

    test('follows 64 bit box sizes', () async {
      final file = mp4File(
        mp4Moov([
          mp4VideoTrack([mp4St3d(1)]),
        ]),
        moovAtEnd: true,
        mdat: mp4LargeBox('mdat', mp4Zeros(100000)),
      );

      expect((await _probe(file)).stereo, StereoLayout.topBottom);

      final largeMoov = Uint8List.fromList([
        ...mp4Ftyp,
        ...mp4LargeBox('moov', [
          ...mp4FullBox('mvhd', mp4Zeros(96)),
          ...mp4VideoTrack([mp4St3d(2)]),
        ]),
      ]);
      expect((await _probe(largeMoov)).stereo, StereoLayout.leftRight);
    });

    test('reads a moov box that runs to the end of the file (size 0)', () async {
      final moov = mp4Moov([
        mp4VideoTrack([mp4Sv3dProjection(mp4Mshp())]),
      ]);
      final file = mp4File(moov, moovAtEnd: true)..setAll(mp4Ftyp.length + 4096 + 8, mp4Uint32(0));

      expect((await _probe(file)).halfSphere, isTrue);
    });

    test('skips uuid boxes, and reads the spherical uuid box of the first version of the format', () async {
      const sphericalV1 = [
        0xff,
        0xcc,
        0x82,
        0x63,
        0xf8,
        0x55,
        0x4a,
        0x93,
        0x88,
        0x14,
        0x58,
        0x7a,
        0x02,
        0x52,
        0x1f,
        0xdd,
      ];
      const xml =
          '<?xml version="1.0"?><rdf:SphericalVideo xmlns:GSpherical="http://ns.google.com/videos/1.0/spherical/">'
          '<GSpherical:Spherical>true</GSpherical:Spherical>'
          '<GSpherical:ProjectionType>equirectangular</GSpherical:ProjectionType>'
          '<GSpherical:StereoMode>left-right</GSpherical:StereoMode>'
          '<GSpherical:CroppedAreaImageWidthPixels>3840</GSpherical:CroppedAreaImageWidthPixels>'
          '<GSpherical:FullPanoWidthPixels>7680</GSpherical:FullPanoWidthPixels>'
          '</rdf:SphericalVideo>';
      final otherUuid = mp4Box('uuid', [...List.generate(16, (i) => i), ...mp4Zeros(40)]);
      final file = Uint8List.fromList([
        ...mp4Ftyp,
        ...otherUuid,
        ...mp4Moov([
          mp4VideoTrack(
            [otherUuid],
            trackBoxes: [
              otherUuid,
              mp4Box('uuid', [...sphericalV1, ...utf8.encode(xml)]),
            ],
          ),
        ]),
      ]);

      expect(
        await _probe(file),
        const SphericalProbe(stereo: StereoLayout.leftRight, halfSphere: true, hasSphericalMetadata: true),
      );
    });

    test('prefers the boxes of the sample entry to the first version of the format', () async {
      const sphericalV1 = [
        0xff,
        0xcc,
        0x82,
        0x63,
        0xf8,
        0x55,
        0x4a,
        0x93,
        0x88,
        0x14,
        0x58,
        0x7a,
        0x02,
        0x52,
        0x1f,
        0xdd,
      ];
      const xml =
          '<GSpherical:Spherical>true</GSpherical:Spherical><GSpherical:StereoMode>top-bottom</GSpherical:StereoMode>';
      final file = mp4File(
        mp4Moov([
          mp4VideoTrack(
            [mp4St3d(2), mp4Sv3dProjection(mp4Mshp())],
            trackBoxes: [
              mp4Box('uuid', [...sphericalV1, ...utf8.encode(xml)]),
            ],
          ),
        ]),
      );

      expect(
        await _probe(file),
        const SphericalProbe(stereo: StereoLayout.leftRight, halfSphere: true, hasSphericalMetadata: true),
      );
    });

    test('reads what a truncated file still holds, and nothing past it', () async {
      final file = mp4File(
        mp4Moov([
          mp4VideoTrack([mp4St3d(2), mp4Sv3dProjection(mp4Mshp())]),
        ]),
        moovAtEnd: true,
      );
      // Cut in the tables after the sample description: the boxes before them are whole
      final cutAfter = Uint8List.sublistView(file, 0, file.length - 200);
      expect((await _probe(cutAfter)).halfSphere, isTrue);

      // Cut at every length: no failure, and never a declaration that is not in the bytes read
      for (var length = 0; length < file.length; length += 7) {
        final probe = await _probe(Uint8List.sublistView(file, 0, length));
        expect(probe.halfSphere, anyOf(isNull, isTrue), reason: 'cut at $length');
      }
    });

    test('reads the head of a long moov box only', () async {
      final moov = mp4Moov([
        mp4VideoTrack([mp4St3d(1)]),
        mp4AudioTrack(),
        mp4Box('free', mp4Zeros(300000)),
      ]);
      final file = mp4File(moov, moovAtEnd: true, mdat: mp4Box('mdat', mp4Zeros(100000)));
      final moovContent = mp4Ftyp.length + 100008 + 8;
      final reads = <(int, int)>[];

      final probe = await _probe(file, reads: reads, maxMoovLength: 100000);

      expect(probe.stereo, StereoLayout.topBottom);
      expect(reads.last, (moovContent, 100000));
      expect(reads.every((read) => read.$2 <= 100000), isTrue, reason: '$reads');
    });

    test('gives nothing for a file that is no MP4, empty, or damaged', () async {
      for (final file in [
        Uint8List(0),
        Uint8List.fromList(utf8.encode('Just some text, not a video at all')),
        Uint8List.fromList(List.generate(5000, (i) => i * 7 % 251)),
        // A box size smaller than its header
        Uint8List.fromList([...mp4Ftyp, ...mp4Uint32(4), ...ascii.encode('moov'), ...mp4Zeros(100)]),
        // A box running to the end of the file before any moov box
        Uint8List.fromList([...mp4Ftyp, ...mp4Uint32(0), ...ascii.encode('mdat'), ...mp4Zeros(100)]),
      ]) {
        expect(await _probe(file), const SphericalProbe());
      }
    });

    test('stops after a bounded number of top level boxes', () async {
      final reads = <(int, int)>[];
      final file = Uint8List.fromList([
        ...mp4Ftyp,
        for (var i = 0; i < 70; i++) ...mp4Box('free', mp4Zeros(66000)),
        ...mp4Moov([
          mp4VideoTrack([mp4St3d(1)]),
        ]),
      ]);

      expect(await _probe(file, reads: reads), const SphericalProbe());
      expect(reads.length, lessThanOrEqualTo(64));
    });

    test('lets the errors of the reader through', () async {
      Future<Uint8List> failing(int offset, int length) => Future.error(StateError('no network'));

      await expectLater(probeSphericalMetadata(failing), throwsStateError);
    });
  });
}
