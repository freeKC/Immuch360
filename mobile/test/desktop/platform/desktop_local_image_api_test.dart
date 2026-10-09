import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/local_image_codec.dart';
import 'package:immich_mobile/desktop/library/thumbnail_cache.dart';
import 'package:immich_mobile/desktop/platform/desktop_local_image_api.dart';
import 'package:path/path.dart' as p;

import 'local_image_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory library;
  late ThumbnailCache cache;
  late Map<String, File> files;
  late List<String> asked;
  var nextRequest = 1000;

  DesktopLocalImageApi api({int concurrentDecodes = 3}) => DesktopLocalImageApi(
    fileForAsset: (id) async {
      asked.add(id);
      return files[id];
    },
    thumbnails: cache,
    concurrentDecodes: concurrentDecodes,
  );

  /// The bytes of an encoded answer, the buffer freed with malloc as the image request does
  Uint8List takeEncoded(Map<String, int>? answer) {
    expect(answer, isNotNull);
    expect(answer!.keys.toSet(), {'pointer', 'length'}, reason: 'the encoded shape LocalImageRequest reads');
    final pointer = Pointer<Uint8>.fromAddress(answer['pointer']!);
    final bytes = Uint8List.fromList(pointer.asTypedList(answer['length']!));
    malloc.free(pointer);
    return bytes;
  }

  Future<ui.Image> decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  Future<ui.Color> pixel(ui.Image image, int x, int y) async {
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final offset = (y * image.width + x) * 4;
    return ui.Color.fromARGB(255, data.getUint8(offset), data.getUint8(offset + 1), data.getUint8(offset + 2));
  }

  Future<Uint8List> pngOf(int width, int height) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF208040),
    );
    final image = await recorder.endRecording().toImage(width, height);
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    image.dispose();
    return png.buffer.asUint8List();
  }

  File put(String id, String name, List<int> bytes) {
    final file = File(p.join(library.path, name))..writeAsBytesSync(bytes);
    files[id] = file;
    return file;
  }

  Future<Map<String, int>?> request(
    DesktopLocalImageApi api,
    String id, {
    int width = 320,
    int height = 320,
    bool isVideo = false,
    bool preferEncoded = false,
    int? requestId,
  }) => api.requestImage(
    id,
    requestId: requestId ?? nextRequest++,
    width: width,
    height: height,
    isVideo: isVideo,
    preferEncoded: preferEncoded,
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('immuch360-local-images');
    library = Directory(p.join(root.path, 'library'))..createSync();
    cache = ThumbnailCache(directory: () async => Directory(p.join(root.path, 'thumbs')));
    files = {};
    asked = [];
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('thumbnails', () {
    test('a photo turned by its EXIF orientation is cut to cover the box, upright', () async {
      put('f1', 'turned.jpg', rotatedJpeg);
      final images = api();

      final thumbnail = await decode(takeEncoded(await request(images, 'f1')));

      // 400 by 800 once turned, scaled by 0.8 to cover 320 by 320
      expect((thumbnail.width, thumbnail.height), (320, 640));
      final top = await pixel(thumbnail, 160, 40);
      final bottom = await pixel(thumbnail, 160, 600);
      expect(top.r, greaterThan(0.6), reason: 'red on top');
      expect(top.b, lessThan(0.4));
      expect(bottom.b, greaterThan(0.6), reason: 'blue below');
      expect(bottom.r, lessThan(0.4));
      thumbnail.dispose();
      await images.idle();
    });

    test('is made once, then read from the cache folder', () async {
      put('f1', 'green.png', await pngOf(640, 480));
      final images = api();

      final first = takeEncoded(await request(images, 'f1'));
      await images.idle();
      final cached = Directory(p.join(root.path, 'thumbs'))
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith(ThumbnailCache.extension))
          .toList();
      expect(cached, hasLength(1));
      expect(cached.single.readAsBytesSync(), first);
      expect(sniffImageFormat(first), SniffedFormat.jpeg, reason: 'an opaque picture is kept as a JPEG');

      // What the cache holds is what comes back, without decoding the file again
      final marker = await pngOf(7, 5);
      cached.single.writeAsBytesSync(marker);
      expect(takeEncoded(await request(images, 'f1')), marker);
    });

    test('a file edited in place gets a new thumbnail', () async {
      final file = put('f1', 'green.png', await pngOf(640, 480));
      final images = api();
      takeEncoded(await request(images, 'f1'));
      await images.idle();

      file.writeAsBytesSync(await pngOf(500, 500));
      file.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
      final again = await decode(takeEncoded(await request(images, 'f1')));
      expect((again.width, again.height), (320, 320));
      again.dispose();
    });

    test('a picture with transparency keeps it: a PNG rather than a JPEG', () async {
      final recorder = ui.PictureRecorder();
      // A green square in the middle of a transparent 600 by 600 picture
      ui.Canvas(
        recorder,
      ).drawRect(const ui.Rect.fromLTWH(200, 200, 200, 200), ui.Paint()..color = const ui.Color(0xFF208040));
      final drawn = await recorder.endRecording().toImage(600, 600);
      final png = (await drawn.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      drawn.dispose();
      put('t1', 'logo.png', png);
      final images = api();

      final bytes = takeEncoded(await request(images, 't1'));
      expect(sniffImageFormat(bytes), SniffedFormat.png);
      final thumbnail = await decode(bytes);
      final corner = (await thumbnail.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
      expect(corner.getUint8(3), 0, reason: 'the corner stays transparent');
      thumbnail.dispose();
      await images.idle();
    });

    test('the 1024 bucket serves the boxes above the timeline tiles', () async {
      put('f1', 'panorama.png', await pngOf(2560, 1280));
      final images = api();
      final thumbnail = await decode(takeEncoded(await request(images, 'f1', width: 600, height: 400)));
      // Scaled by 0.8 to cover 1024 by 1024
      expect((thumbnail.width, thumbnail.height), (2048, 1024));
      thumbnail.dispose();
      await images.idle();
    });
  });

  group('the file itself', () {
    test('for an unsized request, a large box and an animated image', () async {
      put('f1', 'turned.jpg', rotatedJpeg);
      final images = api();
      expect(takeEncoded(await request(images, 'f1', width: 0, height: 0)), rotatedJpeg);
      expect(takeEncoded(await request(images, 'f1', width: 3200, height: 2000)), rotatedJpeg);
      expect(takeEncoded(await request(images, 'f1', preferEncoded: true)), rotatedJpeg);
      expect(Directory(p.join(root.path, 'thumbs')).existsSync(), isFalse, reason: 'nothing cached for these');
    });
  });

  group('video frames', () {
    DesktopLocalImageApi withFrames(Future<Uint8List?> Function(String path, int box) grab) =>
        DesktopLocalImageApi(fileForAsset: (id) async => files[id], thumbnails: cache, videoFrame: grab);

    test('a video gets a frame of itself, grabbed once and then read from the thumbnail cache', () async {
      final frame = await pngOf(64, 36);
      final file = put('v1', 'clip.mp4', [0, 1, 2, 3]);
      final grabs = <(String, int)>[];
      final images = withFrames((path, box) async {
        grabs.add((path, box));
        return frame;
      });

      expect(takeEncoded(await request(images, 'v1', isVideo: true)), frame);
      await images.idle();
      expect(takeEncoded(await request(images, 'v1', isVideo: true)), frame);
      expect(grabs, [(file.path, 320)], reason: 'the second time from the cache');

      // The viewer's larger request gets the frame of the largest box
      expect(takeEncoded(await request(images, 'v1', isVideo: true, width: 0, height: 0)), frame);
      expect(grabs.last, (file.path, 1024));
      await images.idle();
    });

    test('a video that gives no frame gets the film tile, and is not grabbed again in the session', () async {
      put('v1', 'broken.mp4', [0, 1, 2, 3]);
      var grabs = 0;
      final images = withFrames((path, box) async {
        grabs++;
        return null;
      });
      final tile = takeEncoded(await request(images, 'v1', isVideo: true));
      expect(sniffImageFormat(tile), SniffedFormat.png);
      takeEncoded(await request(images, 'v1', isVideo: true));
      expect(grabs, 1);
      expect(Directory(p.join(root.path, 'thumbs')).existsSync(), isFalse, reason: 'tiles are not cached on disk');
    });
  });

  group('tiles', () {
    test('a video gets the film tile at the size of its bucket, the same for every video', () async {
      put('v1', 'one.mp4', [0, 1, 2]);
      put('v2', 'two.mov', [3, 4, 5]);
      final images = api();

      final first = takeEncoded(await request(images, 'v1', isVideo: true));
      final second = takeEncoded(await request(images, 'v2', isVideo: true));
      expect(second, first);
      final tile = await decode(first);
      expect((tile.width, tile.height), (320, 320));
      tile.dispose();

      final large = await decode(takeEncoded(await request(images, 'v1', isVideo: true, width: 0, height: 0)));
      expect((large.width, large.height), (1024, 1024));
      large.dispose();
    });

    test('a file the engine cannot decode gets the tile of its format, for thumbnails and originals', () async {
      put('h1', 'IMG_0001.HEIC', fakeHeic);
      final images = api();

      final thumbnail = takeEncoded(await request(images, 'h1'));
      expect(sniffImageFormat(thumbnail), SniffedFormat.png);
      final original = await decode(takeEncoded(await request(images, 'h1', width: 0, height: 0)));
      expect((original.width, original.height), (1024, 1024));
      original.dispose();
      await images.idle();
      expect(Directory(p.join(root.path, 'thumbs')).existsSync(), isFalse, reason: 'tiles are not cached on disk');
    });

    test('an empty file gets a tile too', () async {
      put('e1', 'empty.jpg', const []);
      expect(sniffImageFormat(takeEncoded(await request(api(), 'e1'))), SniffedFormat.png);
    });

    test('labels are the extensions in capitals', () {
      expect(formatLabel(r'C:\Photos\IMG_0001.heic'), 'HEIC');
      expect(formatLabel('/photos/raw.dng'), 'DNG');
      expect(formatLabel('/photos/no_extension'), isNull);
    });
  });

  group('nothing to show', () {
    test('an asset without a file, or a file gone since', () async {
      final images = api();
      expect(await request(images, 'unknown'), isNull);
      put('g1', 'gone.jpg', rotatedJpeg).deleteSync();
      expect(await request(images, 'g1'), isNull);
      expect(await request(images, 'g1', width: 0, height: 0), isNull);
    });

    test('a file that cannot be read is no image rather than an error', () async {
      // A folder where the library had a file: the stat says it is no file
      files['d1'] = File(library.path);
      expect(await request(api(), 'd1'), isNull);
    });
  });

  group('cancelling', () {
    test('a request cancelled before its answer gets null and no buffer', () async {
      put('f1', 'turned.jpg', rotatedJpeg);
      final images = api();
      final answer = request(images, 'f1', requestId: 1);
      await images.cancelRequest(1);
      expect(await answer, isNull);
    });

    test('cancelling a request that already ended changes nothing for the next one with that id', () async {
      put('f1', 'turned.jpg', rotatedJpeg);
      final images = api();
      takeEncoded(await request(images, 'f1', requestId: 7));
      await images.cancelRequest(7);
      takeEncoded(await request(images, 'f1', requestId: 7));
      await images.idle();
    });
  });

  group('JPEG thumbnails', () {
    Uint8List pixels(int width, int height, {int alpha = 0xFF}) {
      final rgba = Uint8List(width * height * 4);
      for (var index = 0; index < rgba.length; index += 4) {
        rgba
          ..[index] = 0x20
          ..[index + 1] = 0x80
          ..[index + 2] = 0x40
          ..[index + 3] = alpha;
      }
      return rgba;
    }

    test('an opaque picture becomes a JPEG of its size and colour', () async {
      final jpeg = opaqueJpeg(pixels(40, 30), 40, 30)!;
      expect(sniffImageFormat(jpeg), SniffedFormat.jpeg);
      final image = await decode(jpeg);
      expect((image.width, image.height), (40, 30));
      final colour = await pixel(image, 20, 15);
      expect((colour.r * 255 - 0x20).abs(), lessThan(8));
      expect((colour.g * 255 - 0x80).abs(), lessThan(8));
      expect((colour.b * 255 - 0x40).abs(), lessThan(8));
      image.dispose();
    });

    test('a pixel that is not fully opaque, or pixels that do not match the size, give none', () {
      final rgba = pixels(4, 4);
      rgba[4 * 7 + 3] = 0xFE;
      expect(opaqueJpeg(rgba, 4, 4), isNull);
      expect(opaqueJpeg(pixels(4, 4, alpha: 0), 4, 4), isNull);
      expect(opaqueJpeg(pixels(4, 4), 5, 4), isNull);
    });

    test('pixels starting inside a larger buffer are read from their start', () {
      final whole = Uint8List(16 + 8 * 8 * 4)..setAll(16, pixels(8, 8));
      final view = Uint8List.sublistView(whole, 16);
      expect(sniffImageFormat(opaqueJpeg(view, 8, 8)!), SniffedFormat.jpeg);
    });
  });

  test('cover sizes scale by the larger ratio and never enlarge', () {
    expect(coverSize(800, 400, 320), (640, 320));
    expect(coverSize(400, 800, 320), (320, 640));
    expect(coverSize(300, 200, 320), (300, 200));
    expect(coverSize(10000, 1000, 320), (3200, 320));
    expect(coverSize(0, 0, 320), (0, 0));
  });

  test('the thumbhash answer keeps the decoded shape of the phones', () async {
    final answer = await api().getThumbhash('1QcSHQRnh493V4dIh4eXh1h4kJUI');
    expect(answer.keys.toSet(), {'pointer', 'width', 'height', 'rowBytes'});
    expect(answer['rowBytes'], answer['width']! * 4);
    malloc.free(Pointer<Uint8>.fromAddress(answer['pointer']!));
  });
}
