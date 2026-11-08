// The full image of a server photo on Android with "Load original image" on, when the original is a HEIF (or AVIF, or a
// raw file) the native decoder could not decode, as on a Quest short of memory (crash M1 of the Meta Quest store,
// 8 November 2026): its encoded bytes used to go to the engine, whose fallback decoder aborted the app. Now the
// preview stays on screen, without an error, and the original is remembered for the session, not asked again.

import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';

import '../../../unit/presentation/presentation_context.dart';

RemoteAsset _serverPhoto(String id, String name) => RemoteAsset(
  id: id,
  name: name,
  ownerId: 'owner',
  checksum: 'checksum-$id',
  type: AssetType.image,
  createdAt: DateTime(2026, 11, 8),
  updatedAt: DateTime(2026, 11, 8),
  width: 64,
  height: 32,
  isEdited: false,
);

/// A HEIC of an iPhone
final _heic = File('test/fixtures/ai_immersive/codec/display_p3.heic').readAsBytesSync();

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
  late List<int> engineLengths;
  // What the platform answers for an original: the bytes of a file, encoded, or its error
  late Object? Function() original;

  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(const ui.Rect.fromLTWH(0, 0, 64, 32), ui.Paint()..color = const ui.Color(0xFF3366CC));
    final image = await recorder.endRecording().toImage(64, 32);
    png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    image.dispose();
  });

  List<Object?> encoded(Uint8List bytes) {
    final pointer = malloc<Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
    return <Object?>[
      <Object?, Object?>{'pointer': pointer.address, 'length': bytes.length},
    ];
  }

  setUp(() async {
    context = await PresentationContext.create();
    await SettingsRepository.instance.write(SettingsKey.imageLoadOriginal, true);
    UndecodablePhotos.instance.clear();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    requested = [];
    engineLengths = [];
    ImageRequest.describeEncoded = (buffer) {
      engineLengths.add(buffer.length);
      return ui.ImageDescriptor.encoded(buffer);
    };
    original = () => encoded(_heic);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(
      cancel,
      (_) async => const <Object?>[null],
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockDecodedMessageHandler(channel, (
      message,
    ) async {
      final url = (message! as List<Object?>).first! as String;
      requested.add(url);
      return url.contains('/original') ? original() : encoded(png);
    });
  });

  tearDown(() async {
    ImageRequest.describeEncoded = ui.ImageDescriptor.encoded;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockDecodedMessageHandler(channel, null)
      ..setMockDecodedMessageHandler(cancel, null);
    await context.dispose();
  });

  /// Shows [provider] until its last image: the number of images it gave and its error, if any
  Future<({int images, Object? error})> load(ImageProvider provider) async {
    var images = 0;
    Object? error;
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        images++;
        info.dispose();
      },
      onError: (exception, _) => error = exception,
    );
    stream.addListener(listener);
    // The loads end within a few event loop turns: the platform answers at once
    for (var turn = 0; turn < 50 && error == null; turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    stream.removeListener(listener);
    return (images: images, error: error);
  }

  Future<void> showsPreviewOnlyTwice(RemoteAsset photo) async {
    final first = await load(getFullImageProvider(photo));
    expect(first.error, isNull, reason: 'the preview stays on screen');
    expect(first.images, greaterThanOrEqualTo(1));
    expect(requested.where((url) => url.contains('/original')), hasLength(1));
    expect(
      UndecodablePhotos.instance.failureOf(RemoteFullImageProvider.undecodableKey(photo.id, edited: true)),
      isA<ImageDecodeException>(),
    );

    // Shown again after the cache let it go (another page, a new density): the preview only
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    final second = await load(getFullImageProvider(photo));
    expect(second.error, isNull);
    expect(second.images, greaterThanOrEqualTo(1));
    expect(requested.where((url) => url.contains('/original')), hasLength(1), reason: 'never asked a second time');
    expect(requested.where((url) => url.contains('size=preview')), hasLength(2));
  }

  test('a HEIC original handed back encoded keeps the preview, never reaches the engine, is not asked again', () async {
    await showsPreviewOnlyTwice(_serverPhoto('heic1', 'IMG_0001.HEIC'));

    // The thumbnail and the preview, PNG here, went to the engine; the HEIC did not
    expect(engineLengths, isNotEmpty);
    expect(engineLengths, everyElement(png.length));
    expect(engineLengths, isNot(contains(_heic.length)));
  });

  test('an original the native decoder failed on keeps the preview and is not asked again', () async {
    original = () => <Object?>[
      undecodableImageCode,
      'java.lang.OutOfMemoryError: OOM allocating Bitmap with dimensions 32768 x 16384',
      null,
    ];

    await showsPreviewOnlyTwice(_serverPhoto('pano1', 'pano.avif'));
  });
}
