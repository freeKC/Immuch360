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

        expect(
          probe,
          SphericalProbe(stereo: expected, codec: 'hvc1'),
          reason: 'stereo_mode $mode',
        );
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

      expect(
        probe,
        const SphericalProbe(
          stereo: StereoLayout.leftRight,
          halfSphere: true,
          hasSphericalMetadata: true,
          codec: 'hvc1',
        ),
      );
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
        const SphericalProbe(
          stereo: StereoLayout.topBottom,
          halfSphere: false,
          hasSphericalMetadata: true,
          codec: 'hvc1',
        ),
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

      expect(
        probe,
        const SphericalProbe(
          stereo: StereoLayout.leftRight,
          halfSphere: true,
          hasSphericalMetadata: true,
          codec: 'hvc1',
        ),
      );
    });

    test('takes a cube map for no half sphere', () async {
      final probe = await _probe(
        mp4File(
          mp4Moov([
            mp4VideoTrack([mp4Sv3dProjection(mp4FullBox('cbmp', mp4Zeros(8)))]),
          ]),
        ),
      );

      expect(probe, const SphericalProbe(halfSphere: false, hasSphericalMetadata: true, codec: 'hvc1'));
    });

    test('finds nothing declared in a regular video', () async {
      final probe = await _probe(mp4File(mp4Moov([mp4VideoTrack([]), mp4AudioTrack()])));

      expect(probe, const SphericalProbe(codec: 'hvc1'));
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
        const SphericalProbe(
          stereo: StereoLayout.leftRight,
          halfSphere: true,
          hasSphericalMetadata: true,
          codec: 'hvc1',
        ),
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
        const SphericalProbe(
          stereo: StereoLayout.leftRight,
          halfSphere: true,
          hasSphericalMetadata: true,
          codec: 'hvc1',
        ),
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

    test('reads the codec, the coded frame size and the frame rate of the video track', () async {
      final probe = await _probe(
        mp4File(
          mp4Moov([
            mp4AudioTrack(),
            mp4VideoTrack(
              [mp4St3d(1), mp4Sv3dEquirectangular()],
              width: 5760,
              height: 5760,
              config: mp4HvcC(profile: 2, flags: 0x20000000, level: 153),
              timescale: 30000,
              timeToSample: [(300, 1001)],
            ),
          ]),
          moovAtEnd: true,
        ),
      );

      expect(
        probe,
        const SphericalProbe(
          stereo: StereoLayout.topBottom,
          halfSphere: false,
          hasSphericalMetadata: true,
          codec: 'hvc1',
          codecs: 'hvc1.2.4.L153',
          codedWidth: 5760,
          codedHeight: 5760,
          frameRate: 30000 / 1001,
        ),
      );
    });

    test('writes the codecs string of H.264, HEVC and AV1 as RFC 6381 does', () async {
      for (final (codec, config, expected) in [
        ('avc1', mp4AvcC(profile: 0x64, compatibility: 0, level: 0x33), 'avc1.640033'),
        ('avc3', mp4AvcC(profile: 0x42, compatibility: 0xe0, level: 0x1e), 'avc3.42E01E'),
        ('hvc1', mp4HvcC(profile: 1, flags: 0x60000000, level: 93), 'hvc1.1.6.L93'),
        ('hev1', mp4HvcC(profile: 2, highTier: true, flags: 0x20000000, level: 153), 'hev1.2.4.H153'),
        ('hvc1', mp4HvcC(space: 1, profile: 1, flags: 0x40000000, level: 120), 'hvc1.A1.2.L120'),
        // The profile, the level and the tier, then the bit depth: Media3 reads no profile without all four
        ('av01', mp4Av1C(profile: 0, level: 13), 'av01.0.13M.08'),
        ('av01', mp4Av1C(profile: 0, level: 16, highBitDepth: true), 'av01.0.16M.10'),
        ('av01', mp4Av1C(profile: 1, level: 8, highTier: true), 'av01.1.08H.08'),
        ('av01', mp4Av1C(profile: 2, level: 19, highBitDepth: true, twelveBit: true), 'av01.2.19M.12'),
      ]) {
        final probe = await _probe(mp4File(mp4Moov([mp4VideoTrack([], codec: codec, config: config)])));

        expect(probe.codec, codec, reason: expected);
        expect(probe.codecs, expected);
      }
    });

    test('gives no codecs string for a configuration missing, damaged, or of another codec', () async {
      for (final (codec, config) in [
        // Version 0: zeros, not a configuration
        ('hvc1', mp4Box('hvcC', mp4Zeros(30))),
        ('dvh1', mp4Box('hvcC', mp4Zeros(30))),
        ('vp09', mp4FullBox('vpcC', mp4Zeros(8))),
        ('avc1', mp4HvcC()),
        ('avc1', mp4Box('avcC', [1, 0x64])),
        ('hvc1', mp4Box('hvcC', [1, 1, 0x60, 0, 0, 0])),
        ('av01', mp4Box('av1C', [0x01, 0x0d, 0, 0])),
        // Without the byte of the tier and the bit depth
        ('av01', mp4Box('av1C', [0x81, 0x0d])),
      ]) {
        final probe = await _probe(mp4File(mp4Moov([mp4VideoTrack([], codec: codec, config: config)])));

        expect(probe.codec, codec);
        expect(probe.codecs, isNull, reason: '$codec with ${String.fromCharCodes(config.sublist(4, 8))}');
      }
    });

    test('writes the codecs string of Dolby Vision from its own configuration, profile and level', () async {
      for (final (codec, dovi, expected) in [
        ('dvh1', mp4DoviC(type: 'dvvC', profile: 8, level: 6), 'dvh1.08.06'),
        ('dvhe', mp4DoviC(type: 'dvcC', profile: 5, level: 9), 'dvhe.05.09'),
        // The level spans the two bytes
        ('dvh1', mp4DoviC(type: 'dvcC', profile: 7, level: 13), 'dvh1.07.13'),
        ('dvh1', mp4DoviC(type: 'dvvC', profile: 10, level: 32), 'dvh1.10.32'),
      ]) {
        final probe = await _probe(
          mp4File(
            mp4Moov([
              mp4VideoTrack([dovi], codec: codec, config: mp4HvcC(profile: 2, flags: 0x20000000)),
            ]),
          ),
        );

        expect(probe.codec, codec, reason: expected);
        expect(probe.codecs, expected);
      }
    });

    test('gives the HEVC base layer of a Dolby Vision track without its own configuration', () async {
      for (final (codec, children, expected) in [
        ('dvh1', <List<int>>[], 'hvc1.2.4.L153'),
        ('dvhe', <List<int>>[], 'hev1.2.4.L153'),
        // Cut short, or without a level
        (
          'dvh1',
          [
            mp4Box('dvvC', [1, 0, 0x10]),
          ],
          'hvc1.2.4.L153',
        ),
        ('dvh1', [mp4DoviC(level: 0)], 'hvc1.2.4.L153'),
      ]) {
        final probe = await _probe(
          mp4File(
            mp4Moov([
              mp4VideoTrack(children, codec: codec, config: mp4HvcC(profile: 2, flags: 0x20000000, level: 153)),
            ]),
          ),
        );

        expect(probe.codec, codec, reason: '$codec with ${children.length} Dolby Vision boxes');
        expect(probe.codecs, expected, reason: '$codec with ${children.length} Dolby Vision boxes');
      }
    });

    test('keeps HEVC for an HEVC track that carries a Dolby Vision configuration, as iPhones write', () async {
      final probe = await _probe(
        mp4File(
          mp4Moov([
            mp4VideoTrack([
              mp4DoviC(type: 'dvvC', profile: 8, level: 6),
            ], config: mp4HvcC(profile: 2, flags: 0x20000000, level: 153)),
          ]),
        ),
      );

      expect(probe.codec, 'hvc1');
      expect(probe.codecs, 'hvc1.2.4.L153');
    });

    test('reads the mean frame rate of a variable frame rate track, and of a version 1 media header', () async {
      final variable = await _probe(
        mp4File(
          mp4Moov([
            mp4VideoTrack([], timescale: 90000, timeToSample: [(10, 3000), (20, 3003)]),
          ]),
        ),
      );
      expect(variable.frameRate, closeTo(29.98, 0.01));

      final version1 = await _probe(
        mp4File(
          mp4Moov([
            mp4VideoTrack([], timescale: 600, mdhdVersion: 1, timeToSample: [(60, 20)]),
          ]),
        ),
      );
      expect(version1.frameRate, 30);
    });

    test('gives no frame size nor frame rate when the file does not say', () async {
      for (final track in [
        // Zeros in the sample entry, no time scale, no sample
        mp4VideoTrack([]),
        mp4VideoTrack([], width: 1920, timescale: 30000),
        mp4VideoTrack([], height: 1080, timeToSample: [(30, 1000)]),
        mp4VideoTrack([], timescale: 30000, timeToSample: [(0, 1000)]),
      ]) {
        final probe = await _probe(mp4File(mp4Moov([track])));

        expect(probe.frameRate, isNull);
        expect(probe.codedWidth == null || probe.codedHeight == null, isTrue);
      }
    });

    test('reads the frame size and the codec from a moov box cut in its tables', () async {
      final file = mp4File(
        mp4Moov([
          mp4VideoTrack(
            [],
            codec: 'avc1',
            config: mp4AvcC(),
            width: 3840,
            height: 2160,
            timescale: 30,
            timeToSample: [for (var i = 0; i < 50; i++) (1, 1)],
          ),
        ]),
        moovAtEnd: true,
      );
      // Cut in the stsz box: the sample description and the time to sample table are whole
      final probe = await _probe(Uint8List.sublistView(file, 0, file.length - 300));

      expect(probe.codec, 'avc1');
      expect(probe.codecs, 'avc1.640033');
      expect((probe.codedWidth, probe.codedHeight), (3840, 2160));
      expect(probe.frameRate, 30);
    });

    test('lets the errors of the reader through', () async {
      Future<Uint8List> failing(int offset, int length) => Future.error(StateError('no network'));

      await expectLater(probeSphericalMetadata(failing), throwsStateError);
    });
  });
}
