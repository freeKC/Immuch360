import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import '../../fixtures/raw/insta360.stub.dart';
import 'spherical_probe_fixtures.dart';

/// Reads [file] as a local file or a server does: fewer bytes at the end, none past it. Records each read.
ByteRangeReader _reader(Uint8List file, [List<(int, int)>? reads]) => (offset, length) async {
  reads?.add((offset, length));
  if (offset >= file.length) {
    return Uint8List(0);
  }
  return Uint8List.sublistView(file, offset, math.min(file.length, offset + length));
};

/// The probe of [file] without its list of tracks: the fields of the first video track, which the tests compare whole.
/// The tracks are checked by the tests of the group 'tracks', on [probeSphericalMetadata] itself.
Future<SphericalProbe> _probe(Uint8List file, {List<(int, int)>? reads, int? maxMoovLength}) async {
  final probe = maxMoovLength == null
      ? await probeSphericalMetadata(_reader(file, reads))
      : await probeSphericalMetadata(_reader(file, reads), maxMoovLength: maxMoovLength);
  return SphericalProbe(
    stereo: probe.stereo,
    halfSphere: probe.halfSphere,
    hasSphericalMetadata: probe.hasSphericalMetadata,
    codec: probe.codec,
    codecs: probe.codecs,
    codedWidth: probe.codedWidth,
    codedHeight: probe.codedHeight,
    frameRate: probe.frameRate,
    bitDepth: probe.bitDepth,
    colourPrimaries: probe.colourPrimaries,
    transferCharacteristics: probe.transferCharacteristics,
    dolbyVision: probe.dolbyVision,
    videoBitRate: probe.videoBitRate,
    declaredBitRate: probe.declaredBitRate,
    mediaBitRate: probe.mediaBitRate,
  );
}

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
      // The head of the moov box, then the header of the box after the long one, at its end (the udta box)
      expect(reads[reads.length - 2], (moovContent, 100000));
      expect(reads.last, (moovContent + moov.length - 8 - 36, 36));
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
          bitDepth: 8,
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

    test('reads the bit depth of HEVC, H.264, AV1 and VP9 configurations', () async {
      for (final (codec, config, expected) in [
        ('hvc1', mp4HvcC(profile: 2, bitDepth: 10), 10),
        ('hvc1', mp4HvcC(), 8),
        // The profile of H.264, or the bit depth of its high profile extension
        ('avc1', mp4AvcC(profile: 0x6e), 10),
        ('avc1', mp4AvcC(profile: 0x64, highExtension: [0xfd, 0xfa, 0xf8, 0x00]), 10),
        ('avc1', mp4AvcC(profile: 0x64), 8),
        ('avc1', mp4AvcC(profile: 0x42), 8),
        ('av01', mp4Av1C(highBitDepth: true), 10),
        ('av01', mp4Av1C(highBitDepth: true, twelveBit: true), 12),
        ('vp09', mp4VpcC(bitDepth: 10), 10),
        // A configuration of zeros, or one of another codec
        ('hvc1', mp4Box('hvcC', mp4Zeros(30)), null),
        ('avc1', mp4HvcC(bitDepth: 10), null),
      ]) {
        final probe = await probeSphericalMetadata(
          _reader(mp4File(mp4Moov([mp4VideoTrack([], codec: codec, config: config)]))),
        );

        expect(probe.bitDepth, expected, reason: '$codec ${String.fromCharCodes(config.sublist(4, 8))}');
        expect(probe.tracks.single.bitDepth, expected);
      }
    });

    test('takes the bit depth of HEVC from its profile when the reserved bits are not set', () async {
      for (final (profile, expected) in [(2, 10), (1, 8), (4, null)]) {
        final probe = await _probe(
          mp4File(mp4Moov([mp4VideoTrack([], config: mp4HvcC(profile: profile, reservedBits: false))])),
        );

        expect(probe.bitDepth, expected, reason: 'profile $profile');
      }
    });

    group('an hvcC whose profile and level are zeros, as the Insta360 X4 writes it (docs/18-test-media.md, F6)', () {
      Future<SphericalProbe> probeOf(List<int> config) => probeSphericalMetadata(
        _reader(mp4File(mp4Moov([mp4VideoTrack([], width: 3840, height: 3840, config: config)]))),
      );

      test('the fixture is laid out as the SPS of the X4: one sub layer more, emulation prevention bytes', () {
        expect(hevcSpsNal(maxSubLayersMinus1: 1).sublist(0, 9), [0x42, 0x01, 0x02, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00]);
      });

      test('gives the profile, the level and the bit depth of the sequence parameter set', () async {
        for (final (sps, codecs, bitDepth) in [
          (hevcSpsNal(maxSubLayersMinus1: 1), 'hvc1.1.6.L183', 8),
          (hevcSpsNal(), 'hvc1.1.6.L183', 8),
          (
            hevcSpsNal(
              profile: 2,
              flags: 0x20000000,
              highTier: true,
              level: 156,
              conformanceWindow: [0, 0, 0, 4],
              bitDepth: 10,
            ),
            'hvc1.2.4.H156',
            10,
          ),
          (
            hevcSpsNal(
              space: 1,
              profile: 4,
              flags: 0x08000000,
              level: 153,
              maxSubLayersMinus1: 2,
              subLayers: [(true, true), (false, true)],
              chromaFormat: 3,
              width: 7680,
              height: 3840,
              bitDepth: 12,
            ),
            'hvc1.A4.10.L153',
            12,
          ),
        ]) {
          final probe = await probeOf(mp4HvcCOfX4(sps));

          expect(probe.codecs, codecs);
          expect(probe.bitDepth, bitDepth, reason: codecs);
          expect(probe.videoTracks.single.codecs, codecs);
          expect(probe.videoTracks.single.bitDepth, bitDepth);
        }
      });

      test('keeps the profile of a set cut short after it, and the zeros without a set to read', () async {
        // The NAL header, a byte, the profile_tier_level with its three emulation prevention bytes, and no more
        final cut = await probeOf(mp4HvcCOfX4(hevcSpsNal(maxSubLayersMinus1: 1, length: 18)));
        expect((cut.codecs, cut.bitDepth), ('hvc1.1.6.L183', null));

        final short = await probeOf(mp4HvcCOfX4(hevcSpsNal(length: 10)));
        expect((short.codecs, short.bitDepth), ('hvc1.0.0.L0', null));

        final none = await probeOf(mp4HvcC(profile: 0, flags: 0, level: 0, reservedBits: false, blank: true));
        expect((none.codecs, none.bitDepth), ('hvc1.0.0.L0', null));
      });

      test('reads no set behind an hvcC that gives its profile or its level', () async {
        final probe = await probeOf(
          mp4HvcC(profile: 2, flags: 0x20000000, level: 153, bitDepth: 10, parameterSets: [hevcSpsNal()]),
        );

        expect((probe.codecs, probe.bitDepth), ('hvc1.2.4.L153', 10));
      });

      // The real file of F6, read in place when IMMUCH_X4_SAMPLE names it
      // (VID_20240414_135511_00_027.insv of the test media, never committed)
      test(
        'reads hvc1.1.6.L183 and 8 bits for both tracks of a real X4 file',
        () async {
          final file = await File(Platform.environment['IMMUCH_X4_SAMPLE']!).open();
          addTearDown(file.close);
          final probe = await probeSphericalMetadata((offset, length) async {
            await file.setPosition(offset);
            return file.read(length);
          });

          expect(probe.videoTracks.map((track) => (track.codecs, track.bitDepth, track.codedWidth)), [
            ('hvc1.1.6.L183', 8, 3840),
            ('hvc1.1.6.L183', 8, 3840),
          ]);
          expect((probe.codecs, probe.bitDepth), ('hvc1.1.6.L183', 8));
        },
        skip: Platform.environment['IMMUCH_X4_SAMPLE'] == null
            ? 'Set IMMUCH_X4_SAMPLE to the path of the X4 file'
            : false,
      );
    });

    test('reads the colour of an nclx and an nclc colr box, and ignores an ICC one', () async {
      for (final (colr, primaries, transfer, range) in [
        (mp4Colr(), 9, 18, VideoDynamicRange.hlg),
        (mp4Colr(type: 'nclc', primaries: 1, transfer: 1), 1, 1, VideoDynamicRange.sdr),
        (mp4Colr(transfer: 16), 9, 16, VideoDynamicRange.pq),
        (mp4Box('colr', [...ascii.encode('prof'), ...mp4Zeros(20)]), null, null, null),
      ]) {
        final probe = await _probe(
          mp4File(
            mp4Moov([
              mp4VideoTrack([colr], config: mp4HvcC(profile: 2, bitDepth: 10)),
            ]),
          ),
        );

        expect((probe.colourPrimaries, probe.transferCharacteristics), (primaries, transfer));
        expect(probe.dynamicRange, range);
      }
    });

    test('takes the colour of a VP9 configuration when there is no colr box', () async {
      final vp9 = await _probe(
        mp4File(mp4Moov([mp4VideoTrack([], codec: 'vp09', config: mp4VpcC(bitDepth: 10, primaries: 9, transfer: 16))])),
      );
      expect((vp9.bitDepth, vp9.colourPrimaries, vp9.transferCharacteristics), (10, 9, 16));

      final both = await _probe(
        mp4File(
          mp4Moov([
            mp4VideoTrack(
              [mp4Colr(primaries: 1, transfer: 1)],
              codec: 'vp09',
              config: mp4VpcC(primaries: 9, transfer: 16),
            ),
          ]),
        ),
      );
      expect((both.colourPrimaries, both.transferCharacteristics), (1, 1));
    });

    test(
      'flags Dolby Vision for an HEVC sample entry that carries a dvvC box, and keeps its HEVC codecs string',
      () async {
        final probe = await _probe(
          mp4File(
            mp4Moov([
              mp4VideoTrack([mp4DoviC()], config: mp4HvcC(profile: 2, flags: 0x20000000, level: 153, bitDepth: 10)),
            ]),
          ),
        );

        expect(probe.dolbyVision, isTrue);
        expect(probe.codecs, 'hvc1.2.4.L153');
        expect(probe.bitDepth, 10);

        final dvh1 = await _probe(
          mp4File(
            mp4Moov([
              mp4VideoTrack([mp4DoviC()], codec: 'dvh1', config: mp4HvcC(profile: 2, bitDepth: 10)),
            ]),
          ),
        );
        expect(dvh1.dolbyVision, isTrue);
        expect(dvh1.bitDepth, 10, reason: 'from the hvcC box of its base layer');

        final plain = await _probe(mp4File(mp4Moov([mp4VideoTrack([], config: mp4HvcC())])));
        expect(plain.dolbyVision, isFalse);
      },
    );

    test('reads the average bit rate a btrt box declares', () async {
      for (final (avg, expected) in [(120000000, 120000000), (0, null)]) {
        final probe = await _probe(
          mp4File(
            mp4Moov([
              mp4VideoTrack([mp4Btrt(buffer: 1000, max: 200000000, avg: avg)]),
            ]),
          ),
        );

        expect(probe.declaredBitRate, expected);
      }
    });

    test('computes the bit rate of the video track from its sample sizes', () async {
      final sizes = await _probe(
        mp4File(
          mp4Moov([
            mp4VideoTrack(
              [],
              stsz: mp4Stsz(sizes: [1000, 2000, 3000]),
              timescale: 30,
              timeToSample: [(3, 1)],
            ),
          ]),
        ),
      );
      expect(sizes.videoBitRate, 480000);

      final constant = await _probe(
        mp4File(
          mp4Moov([
            mp4VideoTrack([], stsz: mp4Stsz(sampleSize: 500, count: 30), timescale: 30, timeToSample: [(30, 1)]),
          ]),
        ),
      );
      expect(constant.videoBitRate, 120000);
    });

    test('adds the bit rates of two video tracks, and leaves out the other tracks', () async {
      List<int> track() => mp4VideoTrack(
        [],
        stsz: mp4Stsz(sizes: [1000, 2000, 3000]),
        timescale: 30,
        timeToSample: [(3, 1)],
      );

      final probe = await _probe(mp4File(mp4Moov([track(), mp4AudioTrack(), track()])));

      expect(probe.videoBitRate, 960000);
    });

    test('gives no video bit rate for a sample size table cut short', () async {
      for (final stsz in [
        mp4Stsz(sizes: [1000, 2000, 3000], count: 100),
        null,
      ]) {
        final probe = await _probe(
          mp4File(
            mp4Moov([
              mp4VideoTrack([], stsz: stsz, timescale: 30, timeToSample: [(3, 1)]),
            ]),
          ),
        );

        expect(probe.videoBitRate, isNull);
      }
      // One track of two without a usable table: no sum
      final probe = await _probe(
        mp4File(
          mp4Moov([
            mp4VideoTrack(
              [],
              stsz: mp4Stsz(sizes: [1000, 2000, 3000]),
              timescale: 30,
              timeToSample: [(3, 1)],
            ),
            mp4VideoTrack([], timescale: 30, timeToSample: [(3, 1)]),
          ]),
        ),
      );
      expect(probe.videoBitRate, isNull);
    });

    test('computes the media bit rate from the mdat boxes before a moov box at the end', () async {
      for (final version in [0, 1]) {
        final probe = await _probe(
          mp4File(
            mp4Moov([mp4VideoTrack([])], mvhd: mp4Mvhd(timescale: 1000, duration: 2000, version: version)),
            moovAtEnd: true,
            mdat: mp4Box('mdat', mp4Zeros(100000)),
          ),
        );

        expect(probe.mediaBitRate, 400000, reason: 'mvhd version $version');
      }
    });

    test('reads the header of the mdat box after a moov box at the head, in the same single read', () async {
      final reads = <(int, int)>[];

      final probe = await _probe(
        mp4File(mp4Moov([mp4VideoTrack([])], mvhd: mp4Mvhd(timescale: 1000, duration: 1000))),
        reads: reads,
      );

      expect(probe.mediaBitRate, 32768);
      expect(reads, [(0, 65536)]);
    });

    test('gives no media bit rate without a movie duration, or with media data of unknown length', () async {
      final noDuration = await _probe(mp4File(mp4Moov([mp4VideoTrack([])]), moovAtEnd: true));
      expect(noDuration.mediaBitRate, isNull);

      final file = mp4File(mp4Moov([mp4VideoTrack([])], mvhd: mp4Mvhd(timescale: 1000, duration: 1000)))
        ..setAll(mp4Ftyp.length + mp4Moov([mp4VideoTrack([])], mvhd: mp4Mvhd()).length, mp4Uint32(0));
      expect((await _probe(file)).mediaBitRate, isNull);
    });
  });

  group('tracks', () {
    // The tracks of a DJI Osmo 360 file: two square HEVC Main 10 videos, the sound, two djmd and two dbgi metadata
    // tracks
    List<int> osmoVideo(int trackId) => mp4VideoTrack(
      [],
      width: 3840,
      height: 3840,
      config: mp4HvcC(profile: 2, highTier: true, flags: 0x20000000, level: 156, bitDepth: 10),
      timescale: 25000,
      timeToSample: [(585, 1000)],
      trackId: trackId,
      handlerType: 'vide',
      handlerName: 'VideoHandler',
      durationTicks: 585000,
    );

    final osmoMoov = mp4Moov([
      osmoVideo(1),
      osmoVideo(2),
      mp4AudioTrack(trackId: 3, handlerType: 'soun', handlerName: 'SoundHandler'),
      mp4MetaTrack('djmd', trackId: 4),
      mp4MetaTrack('djmd', trackId: 5),
      mp4MetaTrack('dbgi', handlerName: 'CAM dbgi', trackId: 6),
      mp4MetaTrack('dbgi', handlerName: 'CAM dbgi', trackId: 7),
    ]);

    test('lists every track in moov order, two of them videos, as an Osmo 360 file has them', () async {
      final probe = await probeSphericalMetadata(_reader(mp4File(osmoMoov, moovAtEnd: true)));

      ProbedTrack video(int index) => ProbedTrack(
        index: index,
        trackId: index + 1,
        handlerType: 'vide',
        handlerName: 'VideoHandler',
        codec: 'hvc1',
        codecs: 'hvc1.2.4.H156',
        codedWidth: 3840,
        codedHeight: 3840,
        frameRate: 25,
        durationMs: 23400,
        bitDepth: 10,
      );
      expect(probe.tracks, [
        video(0),
        video(1),
        const ProbedTrack(index: 2, trackId: 3, handlerType: 'soun', handlerName: 'SoundHandler', codec: 'mp4a'),
        const ProbedTrack(index: 3, trackId: 4, handlerType: 'meta', handlerName: 'CAM meta', codec: 'djmd'),
        const ProbedTrack(index: 4, trackId: 5, handlerType: 'meta', handlerName: 'CAM meta', codec: 'djmd'),
        const ProbedTrack(index: 5, trackId: 6, handlerType: 'meta', handlerName: 'CAM dbgi', codec: 'dbgi'),
        const ProbedTrack(index: 6, trackId: 7, handlerType: 'meta', handlerName: 'CAM dbgi', codec: 'dbgi'),
      ]);
      expect(probe.videoTracks, [video(0), video(1)]);
      expect(probe.tracks.map((track) => track.isVideo), [true, true, false, false, false, false, false]);
      // The fields of the probe are those of the first video track
      expect((probe.codec, probe.codecs, probe.codedWidth, probe.bitDepth), ('hvc1', 'hvc1.2.4.H156', 3840, 10));
    });

    test('decodes counted handler names, as QuickTime writes them, and NUL terminated ones', () async {
      final probe = await probeSphericalMetadata(
        _reader(
          mp4File(
            mp4Moov([
              mp4VideoTrack([], handlerType: 'vide', handlerName: 'GoPro H.265', countedHandlerName: true),
              mp4AudioTrack(handlerType: 'soun', handlerName: 'Ambarella AAC', countedHandlerName: true),
              mp4AudioTrack(handlerType: 'soun', handlerName: 'Lens 0'),
              mp4AudioTrack(handlerType: 'soun', handlerName: '  GoPro AAC  '),
            ]),
          ),
        ),
      );

      expect(probe.tracks.map((track) => track.handlerName), ['GoPro H.265', 'Ambarella AAC', 'Lens 0', 'GoPro AAC']);
    });

    test('reads a counted handler name without a NUL, to the end of its box', () async {
      // "\x0bGoPro AAC  ": the length, then the name and its padding, as the GoPro MAX writes it
      final hdlr = mp4FullBox('hdlr', [
        ...mp4Zeros(4),
        ...ascii.encode('soun'),
        ...mp4Zeros(12),
        11,
        ...ascii.encode('GoPro AAC  '),
      ]);
      final trak = mp4Box('trak', [
        ...mp4Tkhd(trackId: 2),
        ...mp4Box('mdia', [
          ...mp4Mdhd(),
          ...hdlr,
          ...mp4Box('minf', [
            ...mp4Box('stbl', [
              ...mp4FullBox('stsd', [...mp4Uint32(1), ...mp4Box('mp4a', mp4Zeros(28))]),
            ]),
          ]),
        ]),
      ]);

      final probe = await probeSphericalMetadata(_reader(mp4File(mp4Moov([trak]))));

      expect(probe.tracks.single.handlerName, 'GoPro AAC');
      expect(probe.tracks.single.handlerType, 'soun');
      expect(probe.tracks.single.trackId, 2);
    });

    test('takes a track without a handler type for a video when its sample entry is a visual one', () async {
      final probe = await probeSphericalMetadata(_reader(mp4File(mp4Moov([mp4VideoTrack([]), mp4AudioTrack()]))));

      expect(probe.tracks.map((track) => (track.handlerType, track.codec, track.isVideo)), [
        (null, 'hvc1', true),
        (null, 'mp4a', false),
      ]);
      expect(probe.tracks.first.trackId, isNull, reason: 'a track_ID of 0 is no ID');
      // A handler that says something else wins over the sample entry
      final other = await probeSphericalMetadata(_reader(mp4File(mp4Moov([mp4VideoTrack([], handlerType: 'auxv')]))));
      expect(other.tracks.single.isVideo, isFalse);
      expect(other.videoTracks, isEmpty);
    });

    test('lists the tracks of a moov box longer than the bytes read, with one more read for the second', () async {
      final file = mp4File(
        mp4Moov([
          mp4VideoTrack(
            [],
            width: 3840,
            height: 3840,
            config: mp4HvcC(profile: 2, bitDepth: 10),
            trackId: 1,
            handlerType: 'vide',
            stsz: mp4Stsz(sizes: List.filled(512 * 1024, 100000)),
            timescale: 30,
            timeToSample: [(512 * 1024, 1)],
          ),
          mp4VideoTrack(
            [],
            width: 3840,
            height: 3840,
            config: mp4HvcC(profile: 2, bitDepth: 10),
            trackId: 2,
            handlerType: 'vide',
          ),
        ]),
        moovAtEnd: true,
      );
      const maxMoovLength = 1024 * 1024;
      final reads = <(int, int)>[];

      final probe = await probeSphericalMetadata(_reader(file, reads), maxMoovLength: maxMoovLength);

      expect(probe.videoTracks.map((track) => (track.trackId, track.codedWidth, track.bitDepth)), [
        (1, 3840, 10),
        (2, 3840, 10),
      ]);
      expect(probe.codecs, 'hvc1.2.6.L153');
      expect(probe.videoBitRate, isNull, reason: 'the first size table is cut');
      final moovRead = reads.indexWhere((read) => read.$2 == maxMoovLength);
      expect(moovRead, isNot(-1), reason: '$reads');
      expect(reads.sublist(moovRead + 1), hasLength(1), reason: '$reads');
      expect(reads.last.$2, lessThanOrEqualTo(256 * 1024));
    });

    test('lists at most 16 tracks', () async {
      final probe = await probeSphericalMetadata(
        _reader(mp4File(mp4Moov([for (var i = 0; i < 20; i++) mp4AudioTrack(trackId: i + 1)]))),
      );

      expect(probe.tracks, hasLength(16));
      expect(probe.tracks.last.trackId, 16);
    });

    test('tells probes with other tracks apart', () async {
      final one = await probeSphericalMetadata(_reader(mp4File(mp4Moov([mp4VideoTrack([])]))));
      final two = await probeSphericalMetadata(_reader(mp4File(mp4Moov([mp4VideoTrack([]), mp4AudioTrack()]))));

      expect(one, isNot(two));
      expect(one, await probeSphericalMetadata(_reader(mp4File(mp4Moov([mp4VideoTrack([])])))));
      expect(one.hashCode, (await probeSphericalMetadata(_reader(mp4File(mp4Moov([mp4VideoTrack([])]))))).hashCode);
    });
  });

  group('listTopLevelBoxes', () {
    final moov = mp4Moov([mp4VideoTrack([], handlerType: 'vide')]);
    final camd = mp4Box('camd', [...mp4Ftyp, ...mp4Box('mdat', mp4Zeros(100))]);

    test('lists the boxes of a file to its end, a trailing camd box included', () async {
      final file = Uint8List.fromList([
        ...mp4Ftyp,
        ...mp4Box('free'),
        ...mp4LargeBox('mdat', mp4Zeros(100000)),
        ...moov,
        ...camd,
      ]);
      final reads = <(int, int)>[];

      final boxes = await listTopLevelBoxes(_reader(file, reads));

      final mdatAt = mp4Ftyp.length + 8;
      final moovAt = mdatAt + 100016;
      expect(boxes, [
        (type: 'ftyp', offset: 0, size: mp4Ftyp.length, headerLength: 8),
        (type: 'free', offset: mp4Ftyp.length, size: 8, headerLength: 8),
        (type: 'mdat', offset: mdatAt, size: 100016, headerLength: 16),
        (type: 'moov', offset: moovAt, size: moov.length, headerLength: 8),
        (type: 'camd', offset: moovAt + moov.length, size: camd.length, headerLength: 8),
      ]);
      // The head of the file, then a header each past it, the last one at the end of the file
      expect(reads, [
        (0, 64 * 1024),
        (moovAt, 16),
        (moovAt + moov.length, 16),
        (moovAt + moov.length + camd.length, 16),
      ]);
    });

    test('stops cleanly at the bare trailer an Insta360 X3 appends after its moov box', () async {
      final mp4 = mp4File(moov, moovAtEnd: true);
      final file = insta360File([
        insta360Record(3, rawImuSamples([(32768, 32768, 32768), (32768, 32768, 32768)])),
        insta360Record(1, x3Metadata(), format: 1),
      ], body: mp4);

      final boxes = await listTopLevelBoxes(_reader(file));

      expect(boxes.map((box) => box.type), ['ftyp', 'mdat', 'moov']);
      // The probe reads such a file as any other
      expect((await probeSphericalMetadata(_reader(file))).videoTracks, hasLength(1));
    });

    test(
      'stops at a box that runs to the end of the file, at a damaged header, and after the most boxes asked',
      () async {
        final toEnd = Uint8List.fromList([...mp4Ftyp, ...mp4Uint32(0), ...ascii.encode('mdat'), ...mp4Zeros(100)]);
        expect(await listTopLevelBoxes(_reader(toEnd)), [
          (type: 'ftyp', offset: 0, size: mp4Ftyp.length, headerLength: 8),
          (type: 'mdat', offset: mp4Ftyp.length, size: null, headerLength: 8),
        ]);

        final damaged = Uint8List.fromList([...mp4Ftyp, ...mp4Uint32(4), ...ascii.encode('free'), ...mp4Zeros(100)]);
        expect((await listTopLevelBoxes(_reader(damaged))).map((box) => box.type), ['ftyp']);

        final many = Uint8List.fromList([for (var i = 0; i < 10; i++) ...mp4Box('free')]);
        expect(await listTopLevelBoxes(_reader(many), maxBoxes: 4), hasLength(4));
        expect(await listTopLevelBoxes(_reader(Uint8List(0))), isEmpty);
      },
    );
  });
}
