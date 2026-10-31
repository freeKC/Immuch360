// A TIFF of the device on Android: the platform gives its file, the app decodes it in Dart, for the viewer and the
// tile, once in the session when it does not decode; a JPEG keeps the decoder of the platform.

import 'dart:async';
import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/file_tiff_image.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/local_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';

import '../../../unit/presentation/presentation_context.dart';

LocalAsset devicePhoto(String id, String name) => LocalAsset(
  id: id,
  name: name,
  type: AssetType.image,
  createdAt: DateTime(2026, 10, 31),
  updatedAt: DateTime(2026, 10, 31),
  width: 600,
  height: 300,
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const requestImage = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.LocalImageApi.requestImage',
    LocalImageApi.pigeonChannelCodec,
  );
  const cancelRequest = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.LocalImageApi.cancelRequest',
    LocalImageApi.pigeonChannelCodec,
  );
  late PresentationContext context;
  // What the platform was asked: the asset and whether it gave the encoded file
  late List<({String id, bool encoded})> asked;
  late Map<String, Uint8List> files;
  // What the platform answers instead of a file: the code of the error it throws, by asset
  late Map<String, String> platformErrors;
  // Holds the answer for an asset until completed
  late Map<String, Completer<void>> held;

  setUp(() async {
    context = await PresentationContext.create();
    UndecodablePhotos.instance.clear();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    asked = [];
    files = {};
    platformErrors = {};
    held = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockDecodedMessageHandler(requestImage, (message) async {
        final [id, _, _, _, _, encoded, ...] = message! as List<Object?>;
        asked.add((id: id! as String, encoded: encoded! as bool));
        await held[id]?.future;
        final error = platformErrors[id];
        if (error != null) {
          return <Object?>[error, 'refused by the platform', null];
        }
        final bytes = files[id];
        if (bytes == null || encoded != true) {
          // The decoder of the platform refuses a TIFF, as ImageDecoder does on Android
          return <Object?>['DecodeException', 'Failed to create image decoder with message invalid input', null];
        }
        final pointer = malloc<Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
        return <Object?>[
          <Object?, Object?>{'pointer': pointer.address, 'length': bytes.length},
        ];
      })
      ..setMockDecodedMessageHandler(cancelRequest, (_) async => const <Object?>[null]);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockDecodedMessageHandler(requestImage, null)
      ..setMockDecodedMessageHandler(cancelRequest, null);
    await context.dispose();
  });

  /// The last image of [provider] (its size) and its error, if any
  Future<({(int, int)? size, Object? error})> load(ImageProvider provider) async {
    (int, int)? size;
    Object? error;
    final done = Completer<void>();
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        size = (info.image.width, info.image.height);
        info.dispose();
      },
      onError: (exception, _) {
        error = exception;
        if (!done.isCompleted) {
          done.complete();
        }
      },
    );
    stream.addListener(listener);
    for (var turn = 0; turn < 100 && !done.isCompleted && size == null; turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    stream.removeListener(listener);
    return (size: size, error: error);
  }

  test('the viewer and the tile of a TIFF of the device decode its file in Dart', () async {
    final tiff = devicePhoto('41', 'scan.tif');
    files['41'] = Uint8List.fromList(img.encodeTiff(img.Image(width: 600, height: 300)));

    final full = getFullImageProvider(tiff);
    expect(full, isA<LocalFullImageProvider>());
    expect((full as LocalFullImageProvider).decodeInDart, isTrue);
    final shown = await load(full);
    expect(shown.error, isNull);
    expect(shown.size, (600, 300));
    expect(asked, [(id: '41', encoded: true)], reason: 'one read of the file, no decode asked of the platform');

    PaintingBinding.instance.imageCache.clear();
    final tile = getThumbnailImageProvider(tiff);
    expect(tile, isA<LocalThumbProvider>());
    expect((tile! as LocalThumbProvider).decodeInDart, isTrue);
    final thumbnail = await load(tile);
    expect(thumbnail.error, isNull);
    final (width, height) = thumbnail.size!;
    expect(width, lessThanOrEqualTo(600));
    expect(height, width ~/ 2);
  });

  test('a TIFF of the device that does not decode says so, and its file is read once in the session', () async {
    final broken = devicePhoto('42', 'damaged.TIF');
    files['42'] = Uint8List.fromList([0x49, 0x49, 0x2A, 0x00, ...List.filled(100, 0x41)]);

    final first = await load(getFullImageProvider(broken));
    expect(first.error, isA<TiffDecodeException>());
    expect(asked, hasLength(1));

    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    final again = await load(getFullImageProvider(broken));
    expect(again.error, isA<TiffDecodeException>());
    final tile = await load(getThumbnailImageProvider(broken)!);
    expect(tile.error, isA<TiffDecodeException>());
    expect(asked, hasLength(1), reason: 'never read again in the session');
  });

  test('a JPEG and a camera raw file of the device keep the decoder of the platform', () {
    for (final name in ['beach.jpg', 'DSC_0001.NEF', 'IMG_1.HEIC']) {
      final asset = devicePhoto('43', name);
      expect((getFullImageProvider(asset) as LocalFullImageProvider).decodeInDart, isFalse, reason: name);
      expect((getThumbnailImageProvider(asset)! as LocalThumbProvider).decodeInDart, isFalse, reason: name);
    }
  });

  test('a TIFF opened with "Open with" is decoded in Dart, any other file by the engine', () {
    final asset = devicePhoto('44', 'scan.tif');
    expect(getFullImageProvider(asset, localFilePath: '/storage/emulated/0/Download/scan.tif'), isA<FileTiffImage>());
    expect(getFullImageProvider(asset, localFilePath: '/storage/emulated/0/Download/a.jpg'), isA<FileImage>());
  });

  test('a TIFF of the device that the server has too shows as the JPEG the server made, not its file decoded', () {
    final both = LocalAsset(
      id: '45',
      remoteId: 'remote-45',
      name: 'scan.tif',
      type: AssetType.image,
      createdAt: DateTime(2026, 10, 31),
      updatedAt: DateTime(2026, 10, 31),
      width: 600,
      height: 300,
      playbackStyle: AssetPlaybackStyle.image,
      isEdited: false,
    );
    final full = getFullImageProvider(both);
    expect(full, isA<RemoteFullImageProvider>());
    expect((full as RemoteFullImageProvider).serverJpegForOriginal, isTrue);
    expect(getThumbnailImageProvider(both), isA<RemoteImageProvider>());
    expect(photoDecodePathOfAsset(both), PhotoDecodePath.serverPreview);
    // A JPEG on both keeps the file of the device
    final jpeg = LocalAsset(
      id: '46',
      remoteId: 'remote-46',
      name: 'beach.jpg',
      type: AssetType.image,
      createdAt: DateTime(2026, 10, 31),
      updatedAt: DateTime(2026, 10, 31),
      width: 600,
      height: 300,
      playbackStyle: AssetPlaybackStyle.image,
      isEdited: false,
    );
    expect(getFullImageProvider(jpeg), isA<LocalFullImageProvider>());
    expect(asked, isEmpty);
  });

  test('a file the platform finds too large for the device says so once, its file not asked again', () async {
    final big = devicePhoto('47', 'big.tif');
    platformErrors['47'] = 'EncodedImageTooLargeException';

    final first = await load(getFullImageProvider(big));
    expect(first.error, isA<TiffDecodeException>());
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    final again = await load(getFullImageProvider(big));
    expect(again.error, isA<TiffDecodeException>());
    expect(asked, hasLength(1));
  });

  test('a tile cancelled while it waits for the decoder never asks the platform for its file', () async {
    addTearDown(() => TiffBudget.current = TiffBudget.large);
    TiffBudget.current = TiffBudget.small;
    files['48'] = Uint8List.fromList(img.encodeTiff(img.Image(width: 8, height: 8)));
    files['49'] = files['48']!;
    final release = held['48'] = Completer<void>();
    Future<ui.Codec> noDecode(ui.ImmutableBuffer buffer, {ui.TargetImageSizeCallback? getTargetSize}) =>
        throw UnimplementedError('decoded in Dart');

    final shown = LocalTiffImageRequest(localId: '48', maxSide: 8);
    final tile = LocalTiffImageRequest(localId: '49', maxSide: 8, work: TiffWork.tile);
    final showing = shown.load(noDecode);
    final waiting = tile.load(noDecode);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(tiffTurns, (running: 1, waiting: 1));

    tile.cancel();
    expect(await waiting, isNull);
    release.complete();
    final image = await showing;
    expect(image?.image.width, 8);
    image?.dispose();
    expect(asked.map((request) => request.id), ['48'], reason: 'the cancelled tile read nothing');
  });
}
