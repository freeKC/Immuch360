// The viewer on a TIFF on Android (fix-tiff-android): a TIFF of the server shows as the JPEG the server made of it,
// with no error and a notice once in the session, and a line in the details; a JPEG says nothing. A TIFF of the device
// is decoded in Dart, said while it decodes, and "This device cannot decode this TIFF" in its place when it does not.

import 'dart:async';
import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details/technical_details.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_page.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';

import '../../../unit/presentation/presentation_context.dart';

const _notice = "Shown as the server's preview: this device does not decode TIFF";

/// A timeline of [asset] alone
class _OneAssetTimeline extends TimelineService {
  _OneAssetTimeline(this.asset)
    : super((
        assetSource: (_, _) async => [],
        bucketSource: () => Stream.value(const [Bucket(assetCount: 1)]),
        origin: TimelineOrigin.main,
      ));

  final BaseAsset asset;

  @override
  int get totalAssets => 1;

  @override
  BaseAsset? getAssetSafe(int index) => index == 0 ? asset : null;
}

class _Viewer extends AssetViewerStateNotifier {
  _Viewer(this.asset);

  final BaseAsset asset;

  @override
  AssetViewerState build() {
    super.build();
    return AssetViewerState(currentAsset: asset);
  }
}

RemoteAsset _serverPhoto(String id, String name) => RemoteAsset(
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
  const requestImage = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  const cancelRequest = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.cancelRequest',
    RemoteImageApi.pigeonChannelCodec,
  );
  late PresentationContext context;
  late List<String> requested;
  Uint8List? png;

  setUp(() async {
    context = await PresentationContext.create();
    await SettingsRepository.instance.write(SettingsKey.imageLoadOriginal, true);
    UndecodablePhotos.instance.clear();
    serverJpegNoticesShown.clear();
    requested = [];
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockDecodedMessageHandler(requestImage, null)
      ..setMockDecodedMessageHandler(cancelRequest, null);
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await context.dispose();
  });

  /// The server: a PNG for the thumbnail, the preview and the full size JPEG, a TIFF for the original
  Future<void> serve(WidgetTester tester) async {
    png ??= await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 64, 32), Paint()..color = const Color(0xFF3366CC));
      final image = await recorder.endRecording().toImage(64, 32);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    final tiff = Uint8List.fromList(img.encodeTiff(img.Image(width: 64, height: 32)));
    tester.binding.defaultBinaryMessenger
      ..setMockDecodedMessageHandler<Object?>(requestImage, (message) async {
        final url = (message! as List<Object?>).first! as String;
        requested.add(url);
        final bytes = url.contains('/original') ? tiff : png!;
        final pointer = malloc<Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
        return <Object?>[
          <Object?, Object?>{'pointer': pointer.address, 'length': bytes.length},
        ];
      })
      ..setMockDecodedMessageHandler<Object?>(cancelRequest, (_) async => const <Object?>[null]);
  }

  Widget app(ProviderContainer container, Widget home) => UncontrolledProviderScope(
    container: container,
    child: EasyLocalization(
      supportedLocales: locales.values.toList(),
      path: translationsPath,
      startLocale: locales.values.first,
      fallbackLocale: locales.values.first,
      saveLocale: false,
      useFallbackTranslations: true,
      assetLoader: const CodegenLoader(),
      child: Builder(
        builder: (context) => MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          home: Scaffold(body: home),
        ),
      ),
    ),
  );

  Future<ProviderContainer> pumpPage(WidgetTester tester, BaseAsset asset) async {
    await serve(tester);
    final container = ProviderContainer(
      overrides: [
        ...context.overrides,
        timelineServiceProvider.overrideWithValue(_OneAssetTimeline(asset)),
        assetViewerProvider.overrideWith(() => _Viewer(asset)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(app(container, const AssetPage(index: 0, heroOffset: 0)));
    // The platform answers and the engine decodes for real
    for (var turn = 0; turn < 20; turn++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    return container;
  }

  bool showsDecodedPhoto() =>
      find.byWidgetPredicate((widget) => widget is RawImage && widget.image != null).evaluate().isNotEmpty;

  testWidgets('a TIFF of the server shows as its JPEG, without an error, with a notice once in the session', (
    tester,
  ) async {
    final tiff = _serverPhoto('tiff1', 'scan.tif');
    await pumpPage(tester, tiff);

    final view = tester.widget<PhotoView>(find.byType(PhotoView));
    expect(showsDecodedPhoto(), isTrue);
    expect(find.byType(Thumbnail), findsNothing, reason: 'no fallback of an image that failed');
    expect(view.imageProvider, isNotNull);
    expect(requested.where((url) => url.contains('size=fullsize')), hasLength(1));
    expect(requested.where((url) => url.contains('/original')), isEmpty, reason: 'the original is never decoded');
    expect(find.text(_notice), findsOneWidget);

    // The line goes away by itself, and is not said again for the same photo in the session
    for (var step = 0; step < 12; step++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text(_notice), findsNothing);
    await pumpPage(tester, tiff);
    expect(find.text(_notice), findsNothing);
    expect(serverJpegNoticesShown, {'tiff1'});
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a JPEG of the server loads its original and says nothing', (tester) async {
    await pumpPage(tester, _serverPhoto('jpeg1', 'beach.jpg'));

    expect(showsDecodedPhoto(), isTrue);
    expect(requested.where((url) => url.contains('/assets/jpeg1/original')), hasLength(1));
    expect(find.text(_notice), findsNothing);
    final provider = tester.widget<PhotoView>(find.byType(PhotoView)).imageProvider;
    expect(provider is! RemoteFullImageProvider || !provider.serverJpegForOriginal, isTrue);
  });

  testWidgets('the details of a TIFF of the server say it shows as the server made it, not those of a JPEG', (
    tester,
  ) async {
    for (final (asset, said) in [(_serverPhoto('tiff2', 'plan.TIFF'), true), (_serverPhoto('jpeg2', 'a.jpg'), false)]) {
      final container = ProviderContainer(overrides: context.overrides);
      addTearDown(container.dispose);
      await tester.pumpWidget(app(container, SingleChildScrollView(child: TechnicalDetails(asset: asset))));
      await tester.pump();

      expect(find.byKey(const Key('asset_details_tiff_server_preview')), said ? findsOneWidget : findsNothing);
      expect(find.text(_notice), said ? findsOneWidget : findsNothing, reason: asset.name);
    }
  });

  group('a TIFF of the device', () {
    const localRequest = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.immich_mobile.LocalImageApi.requestImage',
      LocalImageApi.pigeonChannelCodec,
    );
    const localCancel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.immich_mobile.LocalImageApi.cancelRequest',
      LocalImageApi.pigeonChannelCodec,
    );
    final scan = LocalAsset(
      id: '51',
      name: 'scan.tif',
      type: AssetType.image,
      createdAt: DateTime(2026, 10, 31),
      updatedAt: DateTime(2026, 10, 31),
      width: 64,
      height: 32,
      playbackStyle: AssetPlaybackStyle.image,
      isEdited: false,
    );

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockDecodedMessageHandler(localRequest, null)
        ..setMockDecodedMessageHandler(localCancel, null);
    });

    /// The platform gives [file] when asked for the encoded file, after [held] when given, and refuses to decode it
    void serveFile(WidgetTester tester, Uint8List file, {Completer<void>? held}) {
      tester.binding.defaultBinaryMessenger
        ..setMockDecodedMessageHandler<Object?>(localRequest, (message) async {
          final [_, _, _, _, _, encoded, ...] = message! as List<Object?>;
          if (encoded != true) {
            return <Object?>['DecodeException', 'Failed to create image decoder', null];
          }
          await held?.future;
          final pointer = malloc<Uint8>(file.length)..asTypedList(file.length).setAll(0, file);
          return <Object?>[
            <Object?, Object?>{'pointer': pointer.address, 'length': file.length},
          ];
        })
        ..setMockDecodedMessageHandler<Object?>(localCancel, (_) async => const <Object?>[null]);
    }

    testWidgets('shows decoded on the device, said while it decodes', (tester) async {
      final held = Completer<void>();
      serveFile(tester, Uint8List.fromList(img.encodeTiff(img.Image(width: 64, height: 32))), held: held);
      await pumpPage(tester, scan);

      expect(find.text('Decoding the TIFF on this device'), findsOneWidget);

      held.complete();
      for (var turn = 0; turn < 20 && !showsDecodedPhoto(); turn++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(showsDecodedPhoto(), isTrue);
      expect(find.text('Decoding the TIFF on this device'), findsNothing);
      expect(find.text(_notice), findsNothing, reason: 'a TIFF of the device is shown itself');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('one that does not decode says so in its place, not an error of the engine', (tester) async {
      serveFile(tester, Uint8List.fromList([0x49, 0x49, 0x2A, 0x00, ...List.filled(100, 0x41)]));
      await pumpPage(tester, scan);

      expect(find.text('This device cannot decode this TIFF'), findsOneWidget);
      expect(find.byType(Thumbnail), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
