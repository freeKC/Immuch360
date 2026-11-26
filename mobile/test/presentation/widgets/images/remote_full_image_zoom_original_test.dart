// Immuch360 Desktop (release 53): a server photo zoomed in on a computer, "Load original image" off, gets its original
// after all (RemoteFullImageProvider.zoomOriginal), the preview on screen staying while it comes; an original that does
// not come leaves the preview, without an error. The phones never ask for it (getFullImageProvider's zoomOriginal is
// set by the desktop zoom only), and with "Load original image" on nothing changes.

import 'dart:ffi';
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
    await SettingsRepository.instance.write(SettingsKey.imageLoadOriginal, false);
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
    original = () => encoded(png);
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
    final listener = ImageStreamListener((info, _) {
      images++;
      info.dispose();
    }, onError: (exception, _) => error = exception);
    stream.addListener(listener);
    // The loads end within a few event loop turns: the platform answers at once
    for (var turn = 0; turn < 50 && error == null; turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    stream.removeListener(listener);
    return (images: images, error: error);
  }

  test('zoomed in, the original comes after the preview, which stays meanwhile', () async {
    final photo = _serverPhoto('zoom1', 'IMG_0002.JPG');
    final shown = getFullImageProvider(photo);
    expect(shown, isA<RemoteFullImageProvider>().having((p) => p.zoomOriginal, 'zoomOriginal', isFalse));
    // The preview on screen, as the viewer shows it before the zoom
    final stream = shown.resolve(ImageConfiguration.empty);
    final keep = ImageStreamListener((info, _) => info.dispose());
    stream.addListener(keep);
    for (var turn = 0; turn < 20; turn++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(requested.where((url) => url.contains('/original')), isEmpty, reason: '"Load original image" is off');
    final previews = requested.where((url) => url.contains('size=preview')).length;

    final zoomed = getFullImageProvider(photo, zoomOriginal: true);
    expect(zoomed, isNot(shown));
    final result = await load(zoomed);
    expect(result.error, isNull);
    expect(result.images, 2, reason: 'the preview first, then the original');
    expect(requested.where((url) => url.contains('/original')), hasLength(1));
    expect(requested.where((url) => url.contains('size=preview')), hasLength(previews), reason: 'no second preview');
    stream.removeListener(keep);
  });

  test('an original that does not come leaves the preview, without an error', () async {
    original = () => <Object?>[undecodableImageCode, 'java.lang.OutOfMemoryError', null];
    final result = await load(getFullImageProvider(_serverPhoto('zoom2', 'big.jpg'), zoomOriginal: true));
    expect(result.error, isNull);
    expect(result.images, greaterThanOrEqualTo(1));
  });

  test('with "Load original image" on, the provider is the usual one', () async {
    await SettingsRepository.instance.write(SettingsKey.imageLoadOriginal, true);
    final photo = _serverPhoto('zoom3', 'IMG_0003.JPG');
    expect(getFullImageProvider(photo, zoomOriginal: true), getFullImageProvider(photo));
  });
}
