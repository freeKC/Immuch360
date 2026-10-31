// The full image of a server photo on Android when this device does not decode its original: a TIFF loads the
// largest JPEG the server makes of it (size=fullsize) instead of its original, with "load original" on; any other
// photo keeps its original; an original that does not decode is read once in the session, its preview staying.

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
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';

import '../../../unit/presentation/presentation_context.dart';

RemoteAsset serverPhoto(String id, String name) => RemoteAsset(
  id: id,
  name: name,
  ownerId: 'owner',
  checksum: 'checksum-$id',
  type: AssetType.image,
  createdAt: DateTime(2026, 10, 31),
  updatedAt: DateTime(2026, 10, 31),
  width: 64,
  height: 32,
  isEdited: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  const cancel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.cancelRequest',
    RemoteImageApi.pigeonChannelCodec,
  );
  late PresentationContext context;
  late List<String> requested;
  late Uint8List png;
  // What the server answers for an original: a TIFF, or for the JPEG named photo bytes no decoder reads
  late Uint8List Function(String url) original;

  setUpAll(() async {
    final image = await _testImage();
    png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    image.dispose();
  });

  setUp(() async {
    context = await PresentationContext.create();
    await SettingsRepository.instance.write(SettingsKey.imageLoadOriginal, true);
    UndecodablePhotos.instance.clear();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    requested = [];
    original = (_) => png;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(
      cancel,
      (_) async => const <Object?>[null],
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, (
      message,
    ) async {
      final url = (message! as List<Object?>).first! as String;
      requested.add(url);
      final bytes = url.contains('/original') ? original(url) : png;
      final pointer = malloc<Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
      return <Object?>[
        <Object?, Object?>{'pointer': pointer.address, 'length': bytes.length},
      ];
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockDecodedMessageHandler(channel, null)
      ..setMockDecodedMessageHandler(cancel, null);
    await context.dispose();
  });

  /// Shows [provider] until its last image, the number of images it gave and its error, if any
  Future<({int images, Object? error})> load(ImageProvider provider) async {
    var images = 0;
    Object? error;
    final done = Completer<void>();
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        images++;
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
    // The loads end within a few event loop turns: the platform answers at once
    for (var turn = 0; turn < 50 && !done.isCompleted; turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    stream.removeListener(listener);
    return (images: images, error: error);
  }

  test('a TIFF of the server loads its preview, then the largest JPEG of the server, never its original', () async {
    final tiff = serverPhoto('tiff1', 'scan.tif');
    original = (_) => Uint8List.fromList(img.encodeTiff(img.Image(width: 64, height: 32)));

    final provider = getFullImageProvider(tiff);
    expect(provider, isA<RemoteFullImageProvider>());
    expect((provider as RemoteFullImageProvider).serverJpegForOriginal, isTrue);
    final result = await load(provider);

    expect(result.error, isNull);
    expect(result.images, greaterThanOrEqualTo(2), reason: 'the preview, then the JPEG of the server');
    expect(requested.where((url) => url.contains('size=preview')), hasLength(1));
    expect(requested.where((url) => url.contains('size=fullsize')), hasLength(1));
    expect(requested.where((url) => url.contains('/original')), isEmpty);
  });

  test('a JPEG and a camera raw file of the server keep their original', () async {
    for (final asset in [serverPhoto('jpeg1', 'beach.jpg'), serverPhoto('raw1', 'DSC_0001.NEF')]) {
      requested.clear();
      final provider = getFullImageProvider(asset) as RemoteFullImageProvider;
      expect(provider.serverJpegForOriginal, isFalse, reason: asset.name);
      final result = await load(provider);

      expect(result.error, isNull, reason: asset.name);
      expect(requested.where((url) => url.contains('/assets/${asset.id}/original')), hasLength(1), reason: asset.name);
      expect(requested.where((url) => url.contains('size=fullsize')), isEmpty, reason: asset.name);
    }
  });

  test('an original that does not decode is read once in the session, its preview staying, without an error', () async {
    final broken = serverPhoto('broken1', 'damaged.jpg');
    original = (_) => Uint8List.fromList(List.filled(256, 7));

    final first = await load(getFullImageProvider(broken));
    expect(first.error, isNull, reason: 'the preview stays on screen');
    expect(first.images, greaterThanOrEqualTo(1));
    expect(requested.where((url) => url.contains('/original')), hasLength(1));
    expect(
      UndecodablePhotos.instance.failureOf(RemoteFullImageProvider.undecodableKey('broken1', edited: true)),
      isNotNull,
    );

    // Shown again after the cache let it go (another page, a new density): the preview only
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    final second = await load(getFullImageProvider(broken));
    expect(second.error, isNull);
    expect(second.images, greaterThanOrEqualTo(1));
    expect(requested.where((url) => url.contains('/original')), hasLength(1), reason: 'never read a second time');
    expect(requested.where((url) => url.contains('size=preview')), hasLength(2));
  });

  test('the immersive viewer reads the JPEG of the server for a TIFF, the original for any other photo', () {
    expect(immersiveMediaUrl(serverPhoto('tiff2', 'plan.TIFF')), contains('/assets/tiff2/thumbnail?size=fullsize'));
    expect(immersiveMediaUrl(serverPhoto('tiff2', 'plan.TIFF')), contains('edited=false'));
    expect(immersiveMediaUrl(serverPhoto('jpeg2', 'beach.jpg')), contains('/assets/jpeg2/original'));
    expect(immersiveMediaUrl(serverPhoto('raw2', 'photo.dng')), contains('/assets/raw2/original'));
  });
}

Future<ui.Image> _testImage() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(const ui.Rect.fromLTWH(0, 0, 64, 32), ui.Paint()..color = const ui.Color(0xFF3366CC));
  return recorder.endRecording().toImage(64, 32);
}
