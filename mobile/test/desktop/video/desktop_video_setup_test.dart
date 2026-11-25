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
  final lister = DesktopGpuDecoders.lister;

  setUp(() {
    loads = 0;
    records = [];
    desktopVideoAvailable = false;
    loadLibmpv = () => loads++;
    // No plugin under flutter test: the background read of the GPU's decoders finds nothing to ask
    DesktopGpuDecoders.prober = null;
    DesktopGpuDecoders.lister = null;
    Logger.root.level = Level.ALL;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    loadLibmpv = loader;
    DesktopGpuDecoders.prober = prober;
    DesktopGpuDecoders.lister = lister;
    DesktopGpuDecoders.forget();
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

  for (final platform in [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) {
    test('${platform.name}: libmpv is loaded at start and the videos play', () {
      debugDefaultTargetPlatformOverride = platform;
      expect(desktopVideoLibraryExpected, isTrue);
      setUpDesktopVideo();
      expect(loads, 1);
      expect(desktopVideoAvailable, isTrue);
    });
  }

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

  group('the Linux family of the package of libmpv', () {
    test('by the ID and ID_LIKE of /etc/os-release', () {
      expect(libmpvFamilyOf('ID=arch\n'), LibmpvFamily.arch);
      expect(libmpvFamilyOf('ID=manjaro\nID_LIKE=arch\n'), LibmpvFamily.arch);
      expect(libmpvFamilyOf('ID="opensuse-tumbleweed"\nID_LIKE="opensuse suse"\n'), LibmpvFamily.suse);
      expect(libmpvFamilyOf('ID="opensuse-leap"\n'), LibmpvFamily.suse);
      expect(libmpvFamilyOf('ID=fedora\n'), LibmpvFamily.other);
      expect(libmpvFamilyOf('ID=debian\n'), LibmpvFamily.other);
      expect(libmpvFamilyOf(''), LibmpvFamily.other);
    });
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

    final osRelease = readOsRelease;
    tearDown(() {
      readOsRelease = osRelease;
      forgetLibmpvFamily();
    });

    Future<void> pumpOn(WidgetTester tester, String text) async {
      readOsRelease = () => text;
      forgetLibmpvFamily();
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await pump(tester);
      debugDefaultTargetPlatformOverride = null;
    }

    testWidgets('on Linux it names the package that brings libmpv', (tester) async {
      await pumpOn(tester, 'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\n');
      expect(find.textContaining('install the libmpv2 package (libmpv1 on Ubuntu 22.04'), findsOneWidget);
    });

    testWidgets('on Arch Linux and the systems built on it, the mpv package through pacman', (tester) async {
      await pumpOn(tester, 'NAME="EndeavourOS"\nID="endeavouros"\nID_LIKE="arch"\n');
      expect(find.textContaining('install the mpv package (sudo pacman -S mpv)'), findsOneWidget);
    });

    testWidgets('on openSUSE, libmpv2 through zypper', (tester) async {
      await pumpOn(tester, 'NAME="openSUSE Tumbleweed"\nID="opensuse-tumbleweed"\nID_LIKE="opensuse suse"\n');
      expect(find.textContaining('sudo zypper install libmpv2'), findsOneWidget);
    });

    testWidgets('elsewhere it says that playback comes later', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await pump(tester);
      expect(find.text('Video playback comes to Immuch360 Desktop in a later version'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
