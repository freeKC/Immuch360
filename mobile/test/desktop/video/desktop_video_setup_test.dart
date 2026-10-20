// The libmpv gate of the computers (desktop_video_setup.dart): Windows and Linux load libmpv at start, macOS has none
// in the app yet; a library that does not load leaves the app running without videos, with the package to install
// named in the log on Linux, and the viewer's placeholder says the same.

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/video/desktop_video_placeholder.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/gpu_decoders.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  late int loads;
  late List<LogRecord> records;
  final loader = loadLibmpv;
  final prober = DesktopGpuDecoders.prober;

  setUp(() {
    loads = 0;
    records = [];
    desktopVideoAvailable = false;
    loadLibmpv = () => loads++;
    // No plugin under flutter test: the background read of the GPU's decoders finds nothing to ask
    DesktopGpuDecoders.prober = null;
    Logger.root.level = Level.ALL;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    loadLibmpv = loader;
    DesktopGpuDecoders.prober = prober;
    desktopVideoAvailable = false;
    Logger.root.level = Level.INFO;
  });

  List<LogRecord> logged(void Function() run) {
    final subscription = Logger('DesktopVideo').onRecord.listen(records.add);
    try {
      run();
    } finally {
      unawaited(subscription.cancel());
    }
    return records;
  }

  test('the loader is media_kit\'s own', () {
    expect(loader, MediaKit.ensureInitialized);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
    test('${platform.name}: libmpv is loaded at start and the videos play', () {
      debugDefaultTargetPlatformOverride = platform;
      expect(desktopVideoLibraryExpected, isTrue);
      setUpDesktopVideo();
      expect(loads, 1);
      expect(desktopVideoAvailable, isTrue);
    });
  }

  test('macOS: no libmpv in the app yet, nothing is loaded', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(desktopVideoLibraryExpected, isFalse);
    final log = logged(setUpDesktopVideo);
    expect(loads, 0);
    expect(desktopVideoAvailable, isFalse);
    expect(log.single.message, contains('No libmpv on this operating system yet'));
  });

  test('Linux without libmpv: the start goes on, and the log names the package', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    loadLibmpv = () => throw Exception('Cannot find libmpv at the usual places.');
    final log = logged(setUpDesktopVideo);
    expect(desktopVideoAvailable, isFalse);
    final record = log.single;
    expect(record.level, Level.SEVERE);
    expect(record.message, contains('Cannot find libmpv'));
    expect(record.message, contains('libmpv2'));
    expect(record.message, contains('mpv-libs'));
  });

  test('Windows without its DLL: the log says where it belongs', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    loadLibmpv = () => throw Exception('Cannot find libmpv-2.dll in your system %PATH%.');
    final log = logged(setUpDesktopVideo);
    expect(desktopVideoAvailable, isFalse);
    expect(log.single.message, contains('next to immuch360.exe'));
  });

  group('the placeholder of the viewer', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        EasyLocalization(
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
              home: const Scaffold(body: DesktopVideoPlaceholder()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('on Linux it names the package that brings libmpv', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await pump(tester);
      expect(find.textContaining('install the libmpv2 package'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('elsewhere it says that playback comes later', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await pump(tester);
      expect(find.text('Video playback comes to Immuch360 Desktop in a later version'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
