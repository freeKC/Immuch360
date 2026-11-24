import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/services/tiff_photos.dart';

/// A TIFF [width] by [height], red on its left half and blue on its right, as the image package writes it
Uint8List tiffOf(int width, int height, {int? orientation}) {
  final image = img.Image(width: width, height: height);
  for (final pixel in image) {
    pixel
      ..r = pixel.x < width / 2 ? 255 : 0
      ..g = 0
      ..b = pixel.x < width / 2 ? 0 : 255;
  }
  if (orientation != null) {
    image.exif.imageIfd.orientation = orientation;
  }
  return img.encodeTiff(image);
}

void main() {
  group('the choice of the decoder on a device without TIFF decoder', () {
    PhotoDecodePath pathOf(String name, {String? mimeType, required bool fromServer}) =>
        photoDecodePath(name, mimeType: mimeType, fromServer: fromServer, platformKeepsTiffPath: false);

    test('a TIFF of the server shows as the server makes it, not from its original', () {
      expect(pathOf('scan.tif', fromServer: true), PhotoDecodePath.serverPreview);
      expect(pathOf('SCAN.TIFF', fromServer: true), PhotoDecodePath.serverPreview);
      // A name without the extension, the type of the server telling
      expect(pathOf('scan', mimeType: 'image/tiff', fromServer: true), PhotoDecodePath.serverPreview);
    });

    test('a TIFF of the device or of a share goes to the Dart decoder', () {
      expect(pathOf('scan.tif', fromServer: false), PhotoDecodePath.dartTiff);
      expect(pathOf('Archive/plan.TIF', fromServer: false), PhotoDecodePath.dartTiff);
      expect(pathOf('plan', mimeType: 'image/x-tiff; charset=binary', fromServer: false), PhotoDecodePath.dartTiff);
    });

    test('a JPEG, a PNG, a HEIF and a video name are unchanged', () {
      for (final name in ['beach.jpg', 'beach.JPEG', 'map.png', 'IMG_1.HEIC', 'clip.mp4', 'tiff.jpg', 'a.tif.jpg']) {
        expect(pathOf(name, fromServer: true), PhotoDecodePath.platform, reason: name);
        expect(pathOf(name, fromServer: false), PhotoDecodePath.platform, reason: name);
      }
    });

    test('a camera raw file built on TIFF is unchanged, even typed image/tiff', () {
      for (final name in ['DSC_0001.NEF', 'IMG_2.CR2', 'photo.dng', 'A7.arw', 'P1.ORF', 'X.raf']) {
        expect(pathOf(name, fromServer: true), PhotoDecodePath.platform, reason: name);
        expect(pathOf(name, mimeType: 'image/tiff', fromServer: false), PhotoDecodePath.platform, reason: name);
      }
    });

    test('a platform that keeps its own TIFF path keeps it', () {
      expect(photoDecodePath('scan.tif', fromServer: true, platformKeepsTiffPath: true), PhotoDecodePath.platform);
      expect(photoDecodePath('scan.tif', fromServer: false, platformKeepsTiffPath: true), PhotoDecodePath.platform);
    });

    test('Android and Linux have no TIFF decoder; iOS, Windows and macOS keep their path', () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      for (final platform in [TargetPlatform.android, TargetPlatform.linux]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(thisPlatformKeepsItsTiffPath, isFalse, reason: '$platform');
        expect(photoDecodePath('scan.tif', fromServer: true), PhotoDecodePath.serverPreview, reason: '$platform');
        expect(photoDecodePath('scan.tif', fromServer: false), PhotoDecodePath.dartTiff, reason: '$platform');
        expect(photoDecodePath('IMG_1.dng', fromServer: false), PhotoDecodePath.platform, reason: '$platform');
      }
      for (final platform in [TargetPlatform.iOS, TargetPlatform.windows, TargetPlatform.macOS]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(thisPlatformKeepsItsTiffPath, isTrue, reason: '$platform');
        expect(photoDecodePath('scan.tif', fromServer: false), PhotoDecodePath.platform, reason: '$platform');
      }
    });

    test('the tiles of the TIFFs of the device: by the providers on Android, by the folder library on Linux', () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(tiffTilesDecodedByProviders, isTrue);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(tiffTilesDecodedByProviders, isFalse);
    });
  });

  group('names, types and signatures', () {
    test('the TIFF names, types and first bytes', () {
      expect(isTiffName('a.tif'), isTrue);
      expect(isTiffName('a.tiff'), isTrue);
      expect(isTiffName('a.tifff'), isFalse);
      expect(isTiffMimeType('image/tiff'), isTrue);
      expect(isTiffMimeType('IMAGE/TIF'), isTrue);
      expect(isTiffMimeType('image/jpeg'), isFalse);
      expect(isTiffMimeType(null), isFalse);
      expect(hasTiffSignature(Uint8List.fromList('II*\u0000'.codeUnits)), isTrue);
      expect(hasTiffSignature(Uint8List.fromList('MM\u0000*'.codeUnits)), isTrue);
      expect(hasTiffSignature(Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xE0])), isFalse);
      expect(hasTiffSignature(tiffOf(4, 4)), isTrue);
    });
  });

  group('the Dart decoder', () {
    test('decodes a TIFF to RGBA pixels, scaled down to the long side asked', () async {
      final small = decodeTiffSync(tiffOf(64, 32), maxSide: 4096);
      expect((small.width, small.height), (64, 32));
      expect(small.rgba.length, 64 * 32 * 4);
      // Red on the left, blue on the right, opaque
      expect(small.rgba.sublist(0, 4), [255, 0, 0, 255]);
      expect(small.rgba.sublist(63 * 4, 64 * 4), [0, 0, 255, 255]);

      final scaled = await decodeTiff(() async => tiffOf(400, 100), maxSide: 100);
      expect((scaled.width, scaled.height), (100, 25));
    });

    test('turns the photo upright as its orientation tag says', () {
      // 6: the camera was turned a quarter clockwise, the photo shows taller than wide
      final turned = decodeTiffSync(tiffOf(64, 32, orientation: 6), maxSide: 4096);
      expect((turned.width, turned.height), (32, 64));
    });

    test('refuses what is no TIFF, and a TIFF larger than it decodes, without decoding it', () async {
      expect(
        () => decodeTiffSync(Uint8List.fromList(List.filled(64, 7)), maxSide: 100),
        throwsA(isA<TiffDecodeException>()),
      );
      // A header that says 20000 x 20000 pixels of 16 bit RGB: 2.4 GB of samples
      final huge = img.Image(width: 1, height: 1);
      final header = img.encodeTiff(huge);
      final bytes = Uint8List.fromList(header);
      final view = ByteData.sublistView(bytes);
      // Its width (256), height (257) and bits per sample (258) entries rewritten in the first IFD
      final endian = bytes[0] == 0x4D ? Endian.big : Endian.little;
      final ifd = view.getUint32(4, endian);
      final count = view.getUint16(ifd, endian);
      for (var index = 0; index < count; index++) {
        final entry = ifd + 2 + index * 12;
        final tag = view.getUint16(entry, endian);
        final type = view.getUint16(entry + 2, endian);
        if (tag == 256 || tag == 257) {
          if (type == 3) {
            view.setUint16(entry + 8, 20000, endian);
          } else {
            view.setUint32(entry + 8, 20000, endian);
          }
        }
        if (tag == 258 && type == 3) {
          view.setUint16(entry + 8, 16, endian);
        }
      }
      expect(
        () => decodeTiffSync(bytes, maxSide: 100),
        throwsA(isA<TiffDecodeException>().having((error) => error.reason, 'reason', contains('20000 x 20000'))),
      );
      await expectLater(decodeTiff(() async => bytes, maxSide: 100), throwsA(isA<TiffDecodeException>()));
    });
  });

  group('what the decoder takes of the device', () {
    tearDown(() => TiffBudget.current = TiffBudget.large);

    test('a TV, a device low on memory or of less than 3 GB get the small budget, 6 GB the large one', () {
      const gigabyte = 1 << 30;
      TiffBudget of({bool tv = false, bool lowRam = false, int? memory}) =>
          TiffBudget.forDevice(isTelevision: tv, isLowRamDevice: lowRam, totalMemoryBytes: memory);
      expect(of(tv: true, memory: 8 * gigabyte), TiffBudget.small);
      expect(of(lowRam: true, memory: 4 * gigabyte), TiffBudget.small);
      expect(of(memory: 2 * gigabyte), TiffBudget.small);
      expect(of(memory: 4 * gigabyte), TiffBudget.medium);
      expect(of(), TiffBudget.medium, reason: 'unknown memory');
      // A Meta Quest 3 tells about 7.3 GB, a phone of 6 GB about 5.6
      expect(of(memory: (7.3 * gigabyte).round()), TiffBudget.large);
      expect(of(memory: (5.6 * gigabyte).round()), TiffBudget.large);
      expect(TiffBudget.small.maxConcurrentDecodes, 1);
      expect(TiffBudget.small.maxDecodedBytes, 96 << 20);
      expect(TiffBudget.large.maxConcurrentDecodes, 2);
    });

    test('reads the memory of the device as Linux and Android tell it', () async {
      final folder = Directory.systemTemp.createTempSync('meminfo_');
      addTearDown(() => folder.deleteSync(recursive: true));
      final meminfo = File('${folder.path}/meminfo')
        ..writeAsStringSync('MemTotal:        7652684 kB\nMemFree:          212844 kB\n');
      expect(await readTotalMemoryBytes(path: meminfo.path), 7652684 * 1024);
      expect(await readTotalMemoryBytes(path: '${folder.path}/none'), isNull);
    });

    test('a file larger than the budget is refused, and less on a small device', () async {
      TiffBudget.current = TiffBudget.small;
      expect(() => checkTiffFileLength(129 << 20), throwsA(isA<TiffDecodeException>()));
      checkTiffFileLength(128 << 20);
      // A small TIFF still decodes, at most the side of a viewer of the device
      final pixels = await decodeTiff(() async => tiffOf(5000, 10), maxSide: TiffBudget.current.maxViewerSide);
      expect(pixels.width, 4096);
    });
  });

  group('the turns of the decoder', () {
    tearDown(() => TiffBudget.current = TiffBudget.large);

    /// A job that says when it starts and ends when [release] completes
    Future<String> job(String name, List<String> started, Completer<void> release) async {
      started.add(name);
      await release.future;
      return name;
    }

    test(
      'three queued, the first two cancelled: the third starts at once when a turn comes, the two never run',
      () async {
        TiffBudget.current = TiffBudget.small;
        final started = <String>[];
        final running = Completer<void>();
        final first = inTiffTurn(() => job('running', started, running));
        final cancels = [TiffCancel(), TiffCancel(), TiffCancel()];
        final releases = [Completer<void>(), Completer<void>(), Completer<void>()];
        final queued = [
          for (var index = 0; index < 3; index++)
            inTiffTurn(() => job('queued $index', started, releases[index]), cancel: cancels[index]),
        ];
        await Future<void>.delayed(Duration.zero);
        expect(started, ['running']);
        expect(tiffTurns, (running: 1, waiting: 3));

        cancels[0].cancel();
        cancels[1].cancel();
        // Out of the queue at once, with the error that tells it was given up
        await expectLater(queued[0], throwsA(isA<TiffDecodeCancelled>()));
        await expectLater(queued[1], throwsA(isA<TiffDecodeCancelled>()));
        expect(tiffTurns, (running: 1, waiting: 1));

        running.complete();
        expect(await first, 'running');
        await Future<void>.delayed(Duration.zero);
        expect(started, ['running', 'queued 2']);
        releases[2].complete();
        expect(await queued[2], 'queued 2');
        expect(tiffTurns, (running: 0, waiting: 0));
      },
    );

    test('the photo on screen goes before the tiles, and a waiting job reads nothing until its turn', () async {
      TiffBudget.current = TiffBudget.small;
      final started = <String>[];
      final running = Completer<void>();
      final first = inTiffTurn(() => job('tile 0', started, running), work: TiffWork.tile);
      var reads = 0;
      final tile = decodeTiff(
        () async {
          reads++;
          started.add('tile 1');
          return tiffOf(8, 8);
        },
        maxSide: 8,
        work: TiffWork.tile,
      );
      final viewer = decodeTiff(() async {
        reads++;
        started.add('viewer');
        return tiffOf(8, 8);
      }, maxSide: 8);
      await Future<void>.delayed(Duration.zero);
      expect(reads, 0, reason: 'their files are read when their turn comes');

      running.complete();
      await first;
      await viewer;
      await tile;
      expect(started, ['tile 0', 'viewer', 'tile 1']);
    });

    test('a decode that fails ends its turn, and the next one runs', () async {
      TiffBudget.current = TiffBudget.small;
      final broken = decodeTiff(() async => Uint8List.fromList(List.filled(64, 7)), maxSide: 8);
      final good = decodeTiff(() async => tiffOf(8, 8), maxSide: 8);
      await expectLater(broken, throwsA(isA<TiffDecodeException>()));
      expect((await good).width, 8);
      expect(tiffTurns, (running: 0, waiting: 0));
    });
  });

  group('the failures of the session', () {
    setUp(UndecodablePhotos.instance.clear);

    test('remembers a failure until cleared, the oldest dropped beyond its size', () {
      final photos = UndecodablePhotos.instance;
      expect(photos.failureOf('share:/a.tif'), isNull);
      photos.remember('share:/a.tif', const TiffDecodeException('broken'));
      expect(photos.failureOf('share:/a.tif'), isA<TiffDecodeException>());
      for (var index = 0; index < UndecodablePhotos.maxEntries; index++) {
        photos.remember('share:/$index.tif', const TiffDecodeException('broken'));
      }
      expect(photos.failureOf('share:/a.tif'), isNull);
      expect(photos.failureOf('share:/0.tif'), isNotNull);
      photos.clear();
      expect(photos.failureOf('share:/0.tif'), isNull);
    });
  });

  group('the head of a TIFF and the side to decode it to', () {
    test('the size of the first image, upright, and an RGB TIFF is no raw file', () {
      final head = readTiffHead(tiffOf(60, 20))!;
      expect((head.width, head.height), (60, 20));
      expect(head.cameraRaw, isFalse);
      final turned = readTiffHead(tiffOf(60, 20, orientation: 6))!;
      expect((turned.width, turned.height), (20, 60), reason: 'orientation 6 turns it a quarter');
    });

    test('the fixtures of the decoder read, the 16 bit, tiled and planar ones too', () {
      for (final name in ['rgb8_lzw_pred.tif', 'rgb16_tiled_lzw_pred.tif', 'gray16_lzw_pred.tif', 'cmyk8_lzw.tif']) {
        final head = readTiffHead(File('test/fixtures/tiff/$name').readAsBytesSync());
        expect(head, isNotNull, reason: name);
        expect(head!.cameraRaw, isFalse, reason: name);
        expect(head.width, greaterThan(0), reason: name);
      }
      expect(readTiffHead(File('test/fixtures/tiff/cmyk8_lzw.tif').readAsBytesSync())!.iccProfile, isNull);
    });

    test('a camera raw file by its DNGVersion tag or a reduced first image, and bytes that are no TIFF', () {
      expect(
        readTiffHead(
          _tiffStructure(const [
            (50706, 4, [0x01040000]),
          ]),
        )!.cameraRaw,
        isTrue,
        reason: 'DNG',
      );
      expect(
        readTiffHead(
          _tiffStructure(const [
            (254, 4, [1]),
          ]),
        )!.cameraRaw,
        isTrue,
        reason: 'a preview first',
      );
      expect(readTiffHead(_tiffStructure(const []))!.cameraRaw, isFalse);
      expect(readTiffHead(Uint8List.fromList(List.filled(64, 7))), isNull);
    });

    test('the side covers a box, keeps a width cap, and never enlarges', () {
      const head = TiffHead(width: 6000, height: 4000, cameraRaw: false);
      expect(tiffDecodeSide(head), 6000);
      expect(tiffDecodeSide(head, cover: 320), 480, reason: 'the short side 320');
      expect(tiffDecodeSide(head, maxWidth: 3000), 3000);
      expect(tiffDecodeSide(head, maxWidth: 8000), 6000);
      const portrait = TiffHead(width: 2000, height: 4000, cameraRaw: false);
      expect(tiffDecodeSide(portrait, maxWidth: 1000), 2000, reason: 'the long side of a portrait 1000 wide');
      expect(tiffDecodeSide(const TiffHead(width: 100, height: 50, cameraRaw: false), cover: 320), 100);
    });

    test('decodeTiffFitting decodes to the side asked and refuses a raw file', () async {
      final (pixels, head) = await decodeTiffFitting(() async => tiffOf(400, 200), cover: 50);
      expect((pixels.width, pixels.height), (100, 50));
      expect((head.width, head.height), (400, 200));
      await expectLater(
        decodeTiffFitting(
          () async => _tiffStructure(const [
            (50706, 4, [0x01040000]),
          ]),
        ),
        throwsA(isA<TiffDecodeException>()),
      );
    });
  });
}

/// A little endian TIFF of one 4 by 2 image of 8 bit RGB samples, uncompressed, with [extra] fields in its IFD
Uint8List _tiffStructure(List<(int, int, List<int>)> extra) {
  final fields = <(int, int, List<int>)>[
    (254, 4, const [0]),
    (256, 3, const [4]),
    (257, 3, const [2]),
    (258, 3, const [8]),
    (259, 3, const [1]),
    (262, 3, const [2]),
    (273, 4, const [0]),
    (277, 3, const [3]),
    (278, 3, const [2]),
    (279, 4, const [24]),
  ];
  for (final field in extra) {
    fields.removeWhere((known) => known.$1 == field.$1);
    fields.add(field);
  }
  fields.sort((a, b) => a.$1.compareTo(b.$1));
  final ifdSize = 2 + fields.length * 12 + 4;
  final dataAt = 8 + ifdSize;
  final out = ByteData(dataAt + 24);
  out
    ..setUint8(0, 0x49)
    ..setUint8(1, 0x49)
    ..setUint16(2, 42, Endian.little)
    ..setUint32(4, 8, Endian.little)
    ..setUint16(8, fields.length, Endian.little);
  for (var index = 0; index < fields.length; index++) {
    final (tag, type, values) = fields[index];
    final at = 10 + index * 12;
    out
      ..setUint16(at, tag, Endian.little)
      ..setUint16(at + 2, type, Endian.little)
      ..setUint32(at + 4, values.length, Endian.little);
    final value = tag == 273 ? dataAt : values.first;
    if (type == 3) {
      out.setUint16(at + 8, value, Endian.little);
    } else {
      out.setUint32(at + 8, value, Endian.little);
    }
  }
  for (var index = 0; index < 24; index++) {
    out.setUint8(dataAt + index, index * 10);
  }
  return out.buffer.asUint8List();
}
