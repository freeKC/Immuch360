import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import '../../fixtures/raw/insta360.stub.dart';
import 'spherical_probe_fixtures.dart';

/// Files in memory, read by ranges, counting the reads
class _Files {
  final Map<String, Uint8List> files = {};
  final List<(String, int, int)> reads = [];

  /// Fails every read when set
  Exception? failure;

  /// Holds every read until completed, when set
  Completer<void>? gate;

  ByteRangeReader reader(String path) => (offset, length) async {
    reads.add((path, offset, length));
    final gate = this.gate;
    if (gate != null) {
      await gate.future;
    }
    final failure = this.failure;
    if (failure != null) {
      throw failure;
    }
    final bytes = files[path]!;
    final start = math.min(offset, bytes.length);
    return Uint8List.sublistView(bytes, start, math.min(start + length, bytes.length));
  };

  int readsOf(String path) => reads.where((read) => read.$1 == path).length;
}

NetworkEntry _entry(String path, {int? size, DateTime? modified}) => NetworkEntry(
  sourceId: 'nas',
  path: path,
  isDirectory: false,
  size: size,
  modified: modified ?? DateTime.utc(2026, 10, 1),
);

/// A JPEG-like file: the XMP at the head, or at the tail of a file longer than the GPano windows
Uint8List _photo(String xmp, {bool atTail = false}) {
  final xmpBytes = ascii.encode(xmp);
  if (!atTail) {
    return Uint8List.fromList([0xff, 0xd8, ...xmpBytes, ...List.filled(1024, 0)]);
  }
  return Uint8List.fromList([0xff, 0xd8, ...List.filled(300 * 1024, 0), ...xmpBytes]);
}

const _equirectangular = '<rdf:Description GPano:ProjectionType="equirectangular"/>';

// The GPano crop of a VR180 photo: half the width of the full panorama, all of its height
const _vr180Crop =
    '<rdf:Description GPano:ProjectionType="equirectangular" GPano:FullPanoWidthPixels="8000" '
    'GPano:FullPanoHeightPixels="4000" GPano:CroppedAreaLeftPixels="2000" GPano:CroppedAreaTopPixels="0" '
    'GPano:CroppedAreaImageWidthPixels="4000" GPano:CroppedAreaImageHeightPixels="4000"/>';

void main() {
  late _Files files;

  setUp(() {
    files = _Files();
  });

  Future<NetworkMediaInfo?> detect(
    NetworkMediaService service,
    String path, {
    Uint8List? bytes,
    bool thorough = false,
    bool Function()? isWanted,
    DateTime? modified,
  }) {
    if (bytes != null) {
      files.files[path] = bytes;
    }
    final size = files.files[path]?.length;
    return service.detect(
      _entry(path, size: size, modified: modified),
      files.reader(path),
      thorough: thorough,
      isWanted: isWanted,
    );
  }

  group('photos', () {
    test('a photo whose GPano XMP declares an equirectangular projection is 360°', () async {
      final info = await detect(NetworkMediaService(), '/pano.jpg', bytes: _photo(_equirectangular));

      expect(info?.is360, isTrue);
      expect(info?.probe, isNull);
      expect(info?.declaresStereo, isFalse);
      expect(info?.sphereView('pano.jpg', width: 4000, height: 2000).layout, StereoLayout.mono);
    });

    test('finds the GPano XMP at the tail of the file', () async {
      final info = await detect(NetworkMediaService(), '/pano.webp', bytes: _photo(_equirectangular, atTail: true));

      expect(info?.is360, isTrue);
      expect(files.readsOf('/pano.webp'), 2, reason: 'the head, then the tail');
    });

    test('a photo without GPano tags, or with another projection, is flat', () async {
      final service = NetworkMediaService();

      expect((await detect(service, '/flat.jpg', bytes: _photo('no tags')))?.is360, isFalse);
      expect(
        (await detect(
          service,
          '/cylinder.jpg',
          bytes: _photo('<rdf:Description GPano:ProjectionType="cylindrical"/>'),
        ))?.is360,
        isFalse,
      );
    });

    test('the GPano crop of a VR180 photo makes it a half sphere', () async {
      final info = await detect(NetworkMediaService(), '/vr180.jpg', bytes: _photo(_vr180Crop));

      expect(info?.is360, isTrue);
      expect(info?.gpano?.crop, const Rect.fromLTWH(0.25, 0, 0.5, 1));
      expect(info?.sphereView('vr180.jpg', width: 4000, height: 4000).coverage, SphereCoverage.half);
    });

    test('a photo of unknown size is read at its head only', () async {
      files.files['/pano.jpg'] = _photo(_equirectangular);
      final info = await NetworkMediaService().detect(_entry('/pano.jpg'), files.reader('/pano.jpg'));

      expect(info?.is360, isTrue);
      expect(files.reads, [('/pano.jpg', 0, 131072)]);
    });
  });

  group('videos', () {
    test('a video declaring a spherical projection is 360°, with the layout of its eyes', () async {
      final service = NetworkMediaService();
      final mono = await detect(
        service,
        '/mono.mp4',
        bytes: mp4File(
          mp4Moov([
            mp4VideoTrack([mp4Sv3dEquirectangular()]),
          ]),
        ),
      );
      final stereo = await detect(
        service,
        '/tb.mp4',
        bytes: mp4File(
          mp4Moov([
            mp4VideoTrack([mp4St3d(1), mp4Sv3dEquirectangular()]),
          ]),
          moovAtEnd: true,
        ),
      );

      expect(mono?.is360, isTrue);
      expect(mono?.declaresStereo, isFalse);
      expect(mono?.sphereView('mono.mp4').coverage, SphereCoverage.full);
      expect(stereo?.is360, isTrue);
      expect(stereo?.declaresStereo, isTrue);
      expect(stereo?.sphereView('tb.mp4').layout, StereoLayout.topBottom);
    });

    test('a VR180 video declares the front half of the sphere', () async {
      final info = await detect(
        NetworkMediaService(),
        '/vr180.mp4',
        bytes: mp4File(
          mp4Moov([
            mp4VideoTrack([mp4St3d(2), mp4Sv3dEquirectangular(left: 0.25, right: 0.25)]),
          ]),
        ),
      );

      expect(info?.is360, isTrue);
      expect(info?.sphereView('vr180.mp4').coverage, SphereCoverage.half);
      expect(info?.sphereView('vr180.mp4').layout, StereoLayout.leftRight);
    });

    test('a video without spherical metadata is flat', () async {
      final info = await detect(
        NetworkMediaService(),
        '/flat.mp4',
        bytes: mp4File(mp4Moov([mp4VideoTrack(const []), mp4AudioTrack()])),
      );

      expect(info, isNotNull);
      expect(info?.is360, isFalse);
      expect(info?.declaresStereo, isFalse);
    });

    test('the browser reads the head of the moov box, a viewer all of it when that found nothing', () async {
      // An audio track with large tables before the video track, and a large box at the head of the video track: its
      // spherical metadata is past the head, and past the first 256 KiB of the track that the quick probe reads too
      final bytes = mp4File(
        mp4Moov([
          mp4Track(mp4FullBox('stsd', [...mp4Uint32(1), ...mp4Box('mp4a', mp4Zeros(4000))])),
          mp4VideoTrack([mp4Sv3dEquirectangular()], trackBoxes: [mp4Box('free', mp4Zeros(300 * 1024))]),
        ]),
      );
      final service = NetworkMediaService(quickMoovLength: 1024);

      expect((await detect(service, '/late.mp4', bytes: bytes))?.is360, isFalse);
      expect(service.cached(_entry('/late.mp4', size: bytes.length))?.is360, isFalse);
      expect((await detect(service, '/late.mp4', thorough: true))?.is360, isTrue);

      // Known now: neither asks again
      final reads = files.reads.length;
      expect((await detect(service, '/late.mp4'))?.is360, isTrue);
      expect((await detect(service, '/late.mp4', thorough: true))?.is360, isTrue);
      expect(files.reads.length, reads);
    });

    test('a thorough read found nothing: the file is not read again', () async {
      final service = NetworkMediaService();
      final bytes = mp4File(mp4Moov([mp4VideoTrack(const [])]));

      await detect(service, '/flat.mp4', bytes: bytes, thorough: true);
      final reads = files.reads.length;
      await detect(service, '/flat.mp4');
      await detect(service, '/flat.mp4', thorough: true);

      expect(files.reads.length, reads);
    });
  });

  group('raw files of 360° cameras', () {
    // An X3 photo longer than the GPano windows: the JPEG, then the trailer of the camera
    Uint8List rawPhoto() => insta360File(
      [insta360Record(1, x3Metadata(), format: 1)],
      body: [0xff, 0xd8, ...List.filled(300 * 1024, 0), 0xff, 0xd9],
    );

    test('a photo named .insp is a raw photo, 360° once stitched', () async {
      final info = await detect(NetworkMediaService(), '/IMG_001.insp', bytes: rawPhoto());

      expect(info?.rawKind, RawMediaKind.insta360Photo);
      expect(info?.is360, isTrue);
      expect(info?.cameraEquirect, isFalse);
      expect(info?.sphereView('IMG_001.insp', width: 11968, height: 5984), raw360SphereView);
    });

    test('a photo renamed from .insp is found by its trailer, with no read more than for its GPano tags', () async {
      final info = await detect(NetworkMediaService(), '/IMG_001.jpg', bytes: rawPhoto());

      expect(info?.rawKind, RawMediaKind.insta360Photo);
      expect(info?.is360, isTrue);
      expect(files.readsOf('/IMG_001.jpg'), 2);
    });

    test('a photo whose trailer says the camera stitched it is a 360° photo as it is, unless named .insp', () async {
      // Field 129 of the metadata: 6 an equirect picture stitched in the camera, 2 a double fisheye
      Uint8List photo(int imageCategory) => insta360File(
        [insta360Record(1, x5Metadata(imageCategory: imageCategory), format: 1)],
        body: [0xff, 0xd8, ...List.filled(300 * 1024, 0), 0xff, 0xd9],
      );

      final stitched = await detect(NetworkMediaService(), '/IMG_002.jpg', bytes: photo(6));
      final fisheye = await detect(NetworkMediaService(), '/IMG_003.jpg', bytes: photo(2));
      final named = await detect(NetworkMediaService(), '/IMG_004.insp', bytes: photo(6));

      expect(stitched?.rawKind, isNull);
      expect(stitched?.cameraEquirect, isTrue);
      expect(stitched?.is360, isTrue);
      expect(stitched?.sphereView('IMG_002.jpg', width: 11904, height: 5952).coverage, SphereCoverage.full);
      expect(files.readsOf('/IMG_002.jpg'), 2, reason: 'the trailer is in the tail read for the GPano tags');
      expect(fisheye?.rawKind, RawMediaKind.insta360Photo);
      expect(fisheye?.cameraEquirect, isFalse);
      expect(named?.rawKind, RawMediaKind.insta360Photo, reason: 'a .insp is raw by its name');
    });

    test('a photo without the trailer is not raw, and its EXIF costs no read more', () async {
      final info = await detect(NetworkMediaService(), '/IMG_001.jpg', bytes: _photo('', atTail: true));

      expect(info?.rawKind, isNull);
      expect(info?.cameraEquirect, isFalse);
      expect(info?.is360, isFalse);
      expect(files.readsOf('/IMG_001.jpg'), 2, reason: 'the head and the tail of its GPano tags');
    });

    test('a video named .insv, .360 or .osv is raw by its name, whatever its frame, with its tracks listed', () async {
      Uint8List video(int width, int height) => mp4File(mp4Moov([mp4VideoTrack([], width: width, height: height)]));

      final sideBySide = await detect(NetworkMediaService(), '/VID_00_002.insv', bytes: video(5760, 2880));
      final split = await detect(NetworkMediaService(), '/VID_10_002.insv', bytes: video(2880, 2880));
      final goPro = await detect(NetworkMediaService(), '/GS010013.360', bytes: video(4096, 1344));
      final dji = await detect(NetworkMediaService(), '/CAM_20250715191201_0003_D.OSV', bytes: video(3840, 3840));
      final flat = await detect(NetworkMediaService(), '/VID_002.mp4', bytes: video(5760, 2880));

      expect(sideBySide?.rawKind, RawMediaKind.insta360Video);
      expect(split?.rawKind, RawMediaKind.insta360Video);
      expect(goPro?.rawKind, RawMediaKind.goProVideo);
      expect(dji?.rawKind, RawMediaKind.djiVideo);
      for (final info in [sideBySide, split, goPro, dji]) {
        expect(info?.is360, isTrue);
        expect(info?.sphereView('x', width: 2880, height: 2880), raw360SphereView);
        expect(info?.probe?.videoTracks, hasLength(1));
      }
      expect(flat?.rawKind, isNull);
      expect(flat?.is360, isFalse);
    });

    test('a .36p photo of the GoPro MAX 2 is a 360° photo by its name, not raw', () async {
      final info = await detect(NetworkMediaService(), '/GS__0001.36P', bytes: _photo('', atTail: true));

      expect(info?.cameraEquirect, isTrue);
      expect(info?.rawKind, isNull);
      expect(info?.is360, isTrue);
      expect(info?.sphereView('GS__0001.36P', width: 7680, height: 3840).coverage, SphereCoverage.full);
    });

    test('a 2:1 JPEG of a 360° camera without GPano tags is a 360° photo by its EXIF', () async {
      // The fixture writes every text out of its EXIF entry: a make of more than 3 letters ("DJI" fits in the entry)
      Uint8List jpeg(String make, String model, int width, int height) => Uint8List.fromList([
        ...insta360PhotoHead(make: make, model: model, pixelWidth: width, pixelHeight: height),
        ...List.filled(1024, 0),
      ]);

      final dji = await detect(NetworkMediaService(), '/DJI_0001.JPG', bytes: jpeg('DJI Ltd', 'Osmo 360', 15520, 7760));
      final goPro = await detect(NetworkMediaService(), '/GS_0001.JPG', bytes: jpeg('GoPro', 'GoPro Max', 5760, 2880));
      final single = await detect(
        NetworkMediaService(),
        '/DJI_0002.JPG',
        bytes: jpeg('DJI Ltd', 'Osmo 360', 6400, 4800),
      );
      final phone = await detect(NetworkMediaService(), '/IMG_0003.JPG', bytes: jpeg('Apple', 'iPhone', 8000, 4000));

      expect(dji?.cameraEquirect, isTrue);
      expect(dji?.is360, isTrue);
      expect(goPro?.cameraEquirect, isTrue);
      expect(single?.cameraEquirect, isFalse, reason: 'a single lens photo is 4:3');
      expect(phone?.cameraEquirect, isFalse);
      expect(phone?.is360, isFalse);
      expect(files.readsOf('/DJI_0001.JPG'), 1, reason: 'the EXIF is in the head read for the GPano tags');
    });
  });

  group('cache', () {
    test('reads a file once, and again once its size or its date changed', () async {
      final service = NetworkMediaService();
      await detect(service, '/pano.jpg', bytes: _photo(_equirectangular));
      await detect(service, '/pano.jpg');
      expect(files.readsOf('/pano.jpg'), 1);

      await detect(service, '/pano.jpg', modified: DateTime.utc(2026, 10, 2));
      expect(files.readsOf('/pano.jpg'), 2);

      await detect(service, '/pano.jpg', bytes: _photo(_equirectangular, atTail: true));
      expect(files.readsOf('/pano.jpg'), 4, reason: 'a new size, longer than a window: the head, then the tail');
    });

    test('forgets the files read first past its size', () async {
      final service = NetworkMediaService(maxEntries: 2);
      for (final name in ['a', 'b', 'c']) {
        await detect(service, '/$name.jpg', bytes: _photo(_equirectangular));
      }

      expect(service.cached(_entry('/a.jpg', size: files.files['/a.jpg']!.length)), isNull);
      expect(service.cached(_entry('/c.jpg', size: files.files['/c.jpg']!.length))?.is360, isTrue);
    });

    test('shares a read under way between the callers', () async {
      final service = NetworkMediaService();
      files.files['/pano.jpg'] = _photo(_equirectangular);
      files.gate = Completer<void>();
      final first = detect(service, '/pano.jpg');
      final second = detect(service, '/pano.jpg');
      files.gate!.complete();

      expect((await first)?.is360, isTrue);
      expect((await second)?.is360, isTrue);
      expect(files.readsOf('/pano.jpg'), 1);
    });

    test('a failed read gives null and is tried again next time', () async {
      final service = NetworkMediaService();
      files.files['/pano.jpg'] = _photo(_equirectangular);
      files.failure = Exception('share gone');

      expect(await detect(service, '/pano.jpg'), isNull);

      files.failure = null;
      expect((await detect(service, '/pano.jpg'))?.is360, isTrue);
    });

    test('a read that takes too long gives null', () async {
      final service = NetworkMediaService(timeout: const Duration(milliseconds: 20));
      files.files['/pano.jpg'] = _photo(_equirectangular);
      files.gate = Completer<void>();

      expect(await detect(service, '/pano.jpg'), isNull);
      files.gate!.complete();
    });

    test('a file that is no photo or video, or a folder, is not read', () async {
      final service = NetworkMediaService();

      expect(await service.detect(_entry('/notes.txt', size: 10), files.reader('/notes.txt')), isNull);
      expect(
        await service.detect(
          const NetworkEntry(sourceId: 'nas', path: '/photos.jpg', isDirectory: true),
          files.reader('/photos.jpg'),
        ),
        isNull,
      );
      expect(files.reads, isEmpty);
    });
  });

  group('turns', () {
    test('the browser reads a few files at once, the viewers right away', () async {
      final service = NetworkMediaService(maxConcurrent: 1);
      for (final name in ['a', 'b', 'v']) {
        files.files['/$name.jpg'] = _photo(_equirectangular);
      }
      files.gate = Completer<void>();

      final a = detect(service, '/a.jpg');
      final b = detect(service, '/b.jpg');
      final viewer = detect(service, '/v.jpg', thorough: true);
      await pumpEventQueue();

      expect(files.reads.map((read) => read.$1), unorderedEquals(['/a.jpg', '/v.jpg']), reason: '/b.jpg waits');

      files.gate!.complete();
      expect((await a)?.is360, isTrue);
      expect((await b)?.is360, isTrue);
      expect((await viewer)?.is360, isTrue);
      expect(files.readsOf('/b.jpg'), 1);
    });

    test('a file no longer wanted when its turn comes is not read, unless another caller still wants it', () async {
      final service = NetworkMediaService(maxConcurrent: 1);
      for (final name in ['a', 'b', 'c']) {
        files.files['/$name.jpg'] = _photo(_equirectangular);
      }
      files.gate = Completer<void>();
      var bWanted = true;

      final a = detect(service, '/a.jpg');
      final b = detect(service, '/b.jpg', isWanted: () => bWanted);
      final c = detect(service, '/c.jpg', isWanted: () => false);
      final cAgain = detect(service, '/c.jpg', isWanted: () => true);
      await pumpEventQueue();
      bWanted = false;
      files.gate!.complete();

      expect((await a)?.is360, isTrue);
      expect(await b, isNull);
      expect((await c)?.is360, isTrue, reason: 'the second caller still wants it');
      expect((await cAgain)?.is360, isTrue);
      expect(files.readsOf('/b.jpg'), 0);

      // Not remembered as anything: read when wanted again
      expect((await detect(service, '/b.jpg'))?.is360, isTrue);
    });
  });

  test('networkMediaKey tells files apart by source, path, size and date', () {
    final entry = _entry('/a.jpg', size: 10);

    expect(networkMediaKey(entry), networkMediaKey(_entry('/a.jpg', size: 10)));
    expect(networkMediaKey(entry), isNot(networkMediaKey(_entry('/a.jpg', size: 11))));
    expect(networkMediaKey(entry), isNot(networkMediaKey(_entry('/b.jpg', size: 10))));
    expect(networkMediaKey(entry), isNot(networkMediaKey(_entry('/a.jpg', size: 10, modified: DateTime.utc(2027)))));
  });

  group('what is read is told, for the 360° list', () {
    test('a 360° photo and a flat one are told once each, a cached answer not again', () async {
      final told = <(String, bool)>[];
      final service = NetworkMediaService(onRead: (entry, {required is360}) => told.add((entry.path, is360)));

      await detect(service, '/pano.jpg', bytes: _photo(_equirectangular));
      await detect(service, '/flat.jpg', bytes: _photo('no tags'));
      await detect(service, '/pano.jpg');

      expect(told, [('/pano.jpg', true), ('/flat.jpg', false)]);
    });

    test('a quick read of a video that finds nothing tells nothing: the end of its header was not read', () async {
      final told = <(String, bool)>[];
      final service = NetworkMediaService(onRead: (entry, {required is360}) => told.add((entry.path, is360)));

      await detect(service, '/clip.mp4', bytes: Uint8List(4096));

      expect(told, isEmpty);
    });

    test('a failing listener does not fail the read', () async {
      final service = NetworkMediaService(onRead: (_, {required is360}) => throw StateError('no store'));

      final info = await detect(service, '/pano.jpg', bytes: _photo(_equirectangular));

      expect(info?.is360, isTrue);
    });
  });
}
