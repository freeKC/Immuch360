// A pinch on a computer's touchpad in the asset viewer (28 November 2026, FreeKC on his Windows laptop: "I cannot zoom
// a photo with two fingers"). The viewer is built as the app builds it, the library and the files opened with the
// program alike: the pages of the photos, AssetPage with its details and its drag down that closes the viewer, the
// desktop zoom over PhotoView, the photo really decoded. Windows sends a pinch with a pan of its own (see
// trackpad_pinch_sequences.dart): the drags of the viewer took it as a scroll before PhotoView saw five per cent of
// zoom, so the details opened, the page turned or the viewer closed, and nothing zoomed. Now a gesture whose scale
// moves is the zoom's, around the pointer, for each way the systems send it; a two finger scroll at fit keeps its
// meaning; zoomed in, two fingers pan the photo every way; Control and the wheel, and a scale signal, zoom too.

import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/window/desktop_photo_zoom.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../desktop/window/trackpad_pinch_sequences.dart';
import '../../../unit/presentation/presentation_context.dart';

class _SeededAssetViewerNotifier extends AssetViewerStateNotifier {
  _SeededAssetViewerNotifier(this._asset);

  final BaseAsset _asset;

  @override
  AssetViewerState build() {
    super.build();
    return AssetViewerState(currentAsset: _asset, showingControls: false);
  }
}

void main() {
  late PresentationContext context;
  RemoteAsset photo(String id) => RemoteAsset(
    id: id,
    name: '$id.jpg',
    ownerId: 'owner',
    checksum: 'checksum-$id',
    type: AssetType.image,
    createdAt: DateTime(2026, 11, 28),
    updatedAt: DateTime(2026, 11, 28),
    width: 4000,
    height: 2000,
    isEdited: false,
  );
  final photos = <BaseAsset>[photo('p1'), photo('p2'), photo('p3')];
  const requestImage = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.requestImage',
    RemoteImageApi.pigeonChannelCodec,
  );
  const cancelRequest = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.immich_mobile.RemoteImageApi.cancelRequest',
    RemoteImageApi.pigeonChannelCodec,
  );
  Uint8List? png;
  // His laptop: 1600 x 1000 logical at 200 %, the window maximised
  const window = Size(1600, 960);
  final middle = Offset(window.width / 2, window.height / 2);
  final lower = Offset(window.width / 2, window.height * 0.8);

  setUp(() async {
    // The pigeon API of the phones, made before the platform is said to be a computer, so that its channel answers
    expect(remoteImageApi, isA<RemoteImageApi>());
    context = await PresentationContext.create();
    when(() => context.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      null,
    );
    await context.dispose();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// The photos of the server, decoded for real: a picture of 1600 x 800
  Future<void> serve(WidgetTester tester) async {
    png ??= await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 1600, 800), Paint()..color = const Color(0xFF3366CC));
      final image = await recorder.endRecording().toImage(1600, 800);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    tester.binding.defaultBinaryMessenger
      ..setMockDecodedMessageHandler<Object?>(requestImage, (message) async {
        final bytes = png!;
        final pointer = malloc<Uint8>(bytes.length)..asTypedList(bytes.length).setAll(0, bytes);
        return <Object?>[
          <Object?, Object?>{'pointer': pointer.address, 'length': bytes.length},
        ];
      })
      ..setMockDecodedMessageHandler<Object?>(cancelRequest, (_) async => const <Object?>[null]);
    // The cancel stays answered: the requests of a test end after its tear down
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(requestImage, null);
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    });
  }

  Future<(ProviderContainer, PhotoViewZoomTarget)> pumpViewer(WidgetTester tester) async {
    await serve(tester);
    tester.view.physicalSize = window * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final timeline = TimelineService((
      assetSource: (index, count) async => photos.skip(index).take(count).toList(),
      bucketSource: () => Stream.value([Bucket(assetCount: photos.length)]),
      origin: TimelineOrigin.main,
    ));
    addTearDown(timeline.dispose);
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: ProviderScope(
          overrides: [
            ...context.overrides,
            tvModeProvider.overrideWithValue(false),
            assetViewerProvider.overrideWith(() => _SeededAssetViewerNotifier(photos[0])),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Material(child: AssetViewerPage(initialIndex: 0, timelineService: timeline)),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
    // The picture decodes outside the fake clock
    for (var turn = 0; turn < 20; turn++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      find.byWidgetPredicate((widget) => widget is RawImage && widget.image != null),
      findsWidgets,
      reason: 'the photo is decoded: PhotoView reads no pinch while it loads',
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
    final zoom = tester.widget<DesktopPhotoZoom>(find.byType(DesktopPhotoZoom).first).target as PhotoViewZoomTarget;
    expect(zoom.frame, isNotNull);
    return (container, zoom);
  }

  Future<void> on(TargetPlatform platform, WidgetTester tester, Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
      // Nothing of the viewer left for the next test (its timers, its ticker)
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  double zoomOf(PhotoViewZoomTarget zoom) => zoom.scale / zoom.frame!.fitScale;

  /// Where a pinch of [steps] around [at] (window coordinates) leaves the photo, from [scale] and [position]: each
  /// report zooms around that point as the wheel does, the photo kept in the middle on an axis it does not fill yet
  Offset around(PhotoViewZoomTarget zoom, Offset at, List<PanZoomStep> steps, {double? scale, Offset? position}) {
    final frame = zoom.frame!;
    final focal = at - frame.viewport.center(Offset.zero);
    var shown = (scale: scale ?? frame.fitScale, position: position ?? Offset.zero);
    var previous = 1.0;
    for (final step in steps) {
      shown = desktopZoomAround(frame, shown.scale, shown.position, shown.scale * step.scale / previous, focal);
      previous = step.scale;
    }
    return shown.position;
  }

  double pageOf(WidgetTester tester) => tester.widget<PageView>(find.byType(PageView)).controller!.page!;

  /// The viewer as a pinch must leave it: open, on its first photo, without its details, opaque
  void expectViewerStill(WidgetTester tester, ProviderContainer container) {
    expect(find.byType(AssetViewer), findsOneWidget, reason: 'the viewer is still open');
    expect(pageOf(tester), 0, reason: 'no page turned');
    final state = container.read(assetViewerProvider);
    expect(state.showingDetails, isFalse, reason: 'the details did not open');
    expect(state.backgroundOpacity, 1.0, reason: 'no drag down to close the viewer started');
  }

  group('Windows, a precision touchpad: the pinch comes with the pan of DirectManipulation', () {
    testWidgets('a pinch in the middle zooms two times around the pointer, and nothing else moves', (tester) async {
      await on(TargetPlatform.windows, tester, () async {
        final (container, zoom) = await pumpViewer(tester);
        await sendPanZoom(tester, middle, windowsPinch(2, middle));
        await settle(tester);
        expect(zoomOf(zoom), closeTo(2, 0.01));
        expect(zoom.position.distance, lessThan(1), reason: 'the point under the pointer stays under it');
        expectViewerStill(tester, container);
      });
    });

    testWidgets('a pinch low in the window zooms around that point, the details do not open', (tester) async {
      await on(TargetPlatform.windows, tester, () async {
        final (container, zoom) = await pumpViewer(tester);
        final pinch = windowsPinch(2, lower);
        await sendPanZoom(tester, lower, pinch);
        await settle(tester);
        expect(zoomOf(zoom), closeTo(2, 0.01));
        // Around the pointer, 288 px below the middle: the photo goes up as it grows past the window's height
        final expected = around(zoom, lower, pinch);
        expect(expected.dy, lessThan(-150));
        expect(zoom.position.dx, closeTo(0, 1));
        expect(zoom.position.dy, closeTo(expected.dy, 1));
        expectViewerStill(tester, container);
      });
    });

    testWidgets('a pinch whose fingers drift sideways does not turn the page', (tester) async {
      await on(TargetPlatform.windows, tester, () async {
        final (container, zoom) = await pumpViewer(tester);
        await sendPanZoom(tester, middle, windowsPinch(2, middle, drift: const Offset(40, 6)));
        await settle(tester);
        expect(zoomOf(zoom), closeTo(2, 0.01));
        expectViewerStill(tester, container);
      });
    });

    testWidgets('fast fingers, 4 % of zoom in the first report, zoom as well', (tester) async {
      await on(TargetPlatform.windows, tester, () async {
        final (container, zoom) = await pumpViewer(tester);
        await sendPanZoom(tester, lower, fastWindowsPinch(2, lower));
        await settle(tester);
        expect(zoomOf(zoom), closeTo(2, 0.01));
        expectViewerStill(tester, container);
      });
    });

    testWidgets('fingers that close at fit leave the photo whole and the viewer open', (tester) async {
      await on(TargetPlatform.windows, tester, () async {
        final (container, zoom) = await pumpViewer(tester);
        await sendPanZoom(tester, middle, windowsPinch(0.5, middle));
        await settle(tester);
        expect(zoomOf(zoom), closeTo(1, 1e-6));
        expectViewerStill(tester, container);
      });
    });

    testWidgets('zoomed in, a pinch goes on around the pointer and two fingers pan every way', (tester) async {
      await on(TargetPlatform.windows, tester, () async {
        final (container, zoom) = await pumpViewer(tester);
        await sendPanZoom(tester, middle, windowsPinch(2, middle));
        await settle(tester);
        await sendPanZoom(tester, lower, windowsPinch(1.5, lower));
        await settle(tester);
        expect(zoomOf(zoom), closeTo(3, 0.02));
        // From (0, 0) at 2: the point 288 px below the middle stays, y = 288 - 288 * 1.5; the first reports, before
        // the scale says it is a pinch, pan the zoomed photo by the 2 px of their pan
        expect(zoom.position.dy, closeTo(-144, 3));
        final before = zoom.position;
        await sendPanZoom(tester, middle, scroll(const Offset(0, -100)));
        await settle(tester);
        expect(zoom.position.dy, closeTo(before.dy - 100, 1), reason: 'up');
        await sendPanZoom(tester, middle, scroll(const Offset(0, 100)));
        await settle(tester);
        expect(zoom.position.dy, closeTo(before.dy, 1), reason: 'down, no drag that closes the viewer');
        await sendPanZoom(tester, middle, scroll(const Offset(-100, 0)));
        await settle(tester);
        expect(zoom.position.dx, closeTo(before.dx - 100, 1), reason: 'left');
        expect(zoomOf(zoom), closeTo(3, 0.02));
        expectViewerStill(tester, container);
      });
    });

    testWidgets('at fit two fingers that scroll keep their meaning: left turns the page', (tester) async {
      await on(TargetPlatform.windows, tester, () async {
        final (_, zoom) = await pumpViewer(tester);
        await sendPanZoom(tester, middle, scroll(const Offset(-300, 0)));
        await settle(tester);
        expect(pageOf(tester), 1);
        expect(zoomOf(zoom), closeTo(1, 1e-6));
      });
    });

    testWidgets('at fit two fingers that scroll keep their meaning: up opens the details', (tester) async {
      await on(TargetPlatform.windows, tester, () async {
        final (container, _) = await pumpViewer(tester);
        await sendPanZoom(tester, middle, scroll(const Offset(0, -200)));
        await settle(tester);
        expect(container.read(assetViewerProvider).showingDetails, isTrue);
      });
    });

    testWidgets('at fit two fingers that scroll keep their meaning: down drags the viewer to close it', (tester) async {
      await on(TargetPlatform.windows, tester, () async {
        final (container, _) = await pumpViewer(tester);
        final pad = TestPointer(77, PointerDeviceKind.trackpad);
        await tester.sendEventToBinding(pad.panZoomStart(middle));
        // 60 px, under what closes it (the test has no router to close it with)
        for (var i = 1; i <= 6; i++) {
          await tester.sendEventToBinding(pad.panZoomUpdate(middle, pan: Offset(0, 10.0 * i)));
          await tester.pump(const Duration(milliseconds: 8));
        }
        expect(container.read(assetViewerProvider).backgroundOpacity, lessThan(1));
        await tester.sendEventToBinding(pad.panZoomEnd());
        await settle(tester);
      });
    });

    testWidgets('a touchpad without a precision driver: Control and the wheel zoom around the pointer', (tester) async {
      await on(TargetPlatform.windows, tester, () async {
        final (container, zoom) = await pumpViewer(tester);
        final mouse = TestPointer(61, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(mouse.hover(lower));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        for (var i = 0; i < 8; i++) {
          await tester.sendEventToBinding(mouse.scroll(const Offset(0, -15)));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await settle(tester);
        expect(zoomOf(zoom), greaterThan(1.2));
        expect(zoom.position.dy, lessThan(0), reason: 'around the pointer, below the middle');
        expectViewerStill(tester, container);
      });
    });

    testWidgets('a pinch sent as a scale signal zooms', (tester) async {
      await on(TargetPlatform.windows, tester, () async {
        final (container, zoom) = await pumpViewer(tester);
        final pad = TestPointer(62, PointerDeviceKind.trackpad);
        await tester.sendEventToBinding(pad.hover(middle));
        await tester.sendEventToBinding(pad.scale(1.5));
        await settle(tester);
        expect(zoomOf(zoom), closeTo(1.5, 0.01));
        expectViewerStill(tester, container);
      });
    });
  });

  testWidgets('macOS: a pinch with the drift of the fingers zooms two times, all of it', (tester) async {
    await on(TargetPlatform.macOS, tester, () async {
      final (container, zoom) = await pumpViewer(tester);
      await sendPanZoom(tester, middle, macPinch(2));
      await settle(tester);
      expect(zoomOf(zoom), closeTo(2, 0.01));
      expectViewerStill(tester, container);
    });
  });

  testWidgets('Linux: a pinch of the scale alone, placed at the last click, zooms around the pointer', (tester) async {
    await on(TargetPlatform.linux, tester, () async {
      final (container, zoom) = await pumpViewer(tester);
      // The pointer rests low in the window; GTK puts the pinch where the viewer was opened (the middle)
      final mouse = TestPointer(63, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(lower));
      final pinch = linuxPinch(2);
      await sendPanZoom(tester, middle, pinch);
      await settle(tester);
      expect(zoomOf(zoom), closeTo(2, 0.01));
      final expected = around(zoom, lower, pinch);
      expect(expected.dy, lessThan(-150));
      expect(zoom.position.dy, closeTo(expected.dy, 1));
      expectViewerStill(tester, container);
    });
  });
}
