// The widgets of the headset view (lib/desktop/video/xr): the button and its menus in a 360 page and a flat page, the
// 3D layout marked from the file name, the setting row on every system and runtime, the text of every stop reason.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/xr/headset_view.dart';
import 'package:immich_mobile/desktop/video/xr/headset_view_button.dart';
import 'package:immich_mobile/desktop/video/xr/headset_view_service.dart';
import 'package:immich_mobile/desktop/video/xr/headset_view_setting.dart';
import 'package:immich_mobile/domain/models/flat_stereo.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:media_kit_video/xr.dart';
import 'package:path/path.dart' as p;

import 'headset_test_support.dart';

void main() {
  late Directory folder;
  late FakeHeadsetApi api;
  late HeadsetViewService service;

  setUp(() async {
    folder = Directory.systemTemp.createTempSync('headset_widgets_test');
    api = FakeHeadsetApi();
    service = testService(api, folder);
    // Read for real before the fake time of the widget tests, where a file never answers
    await service.settings.load();
  });

  tearDown(() {
    service.dispose();
    folder.deleteSync(recursive: true);
  });

  /// The menu's pop, then the files the start writes (each a turn of the real event loop) and the calls after them
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    await tester.pumpAndSettle();
  }

  /// After a tap that starts the view: waits for the start itself rather than the fixed turns of [settle], which a
  /// slow runner (the Windows job of the Desktop CI) can outlast while the start writes its files, then settles
  Future<void> settleStarted(WidgetTester tester) async {
    for (var i = 0; i < 250 && api.starts.isEmpty; i++) {
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    await settle(tester);
  }

  Widget bar() => const ColoredBox(
    color: Colors.black,
    child: Align(alignment: Alignment.topRight, child: HeadsetViewButton()),
  );

  group('the button', () {
    testWidgets('hidden without a runtime registered, without a page, off Windows, with the switch off', (
      tester,
    ) async {
      final page = FakePage();
      for (final (info, windows, enabled, registered) in [
        (const XrRuntimeInfo(compiled: true, registered: false), true, true, true),
        (steamVr, true, true, false),
        (steamVr, false, true, true),
        (XrRuntimeInfo.notInBuild, true, true, true),
        (steamVr, true, false, true),
      ]) {
        api
          ..info = info
          ..windows = windows;
        await tester.runAsync(() => service.settings.setEnabled(enabled));
        if (registered) {
          service.register(page.target);
        } else {
          service.unregister(page.target);
        }
        await tester.runAsync(service.refreshRuntime);
        await tester.pumpWidget(localized(bar(), service: service));
        await settle(tester);
        expect(
          find.byKey(const Key('headset_view_button')),
          findsNothing,
          reason: '$info $windows $enabled $registered',
        );
      }
    });

    testWidgets(
      'a 360 page: around you marked, on a flat screen; while it runs, its state, recenter, lying down, stop',
      (tester) async {
        final page = FakePage();
        service.register(page.target);
        await tester.runAsync(service.refreshRuntime);
        await tester.pumpWidget(localized(bar(), service: service));
        await settle(tester);
        await tester.tap(find.byKey(const Key('headset_view_button')));
        await tester.pumpAndSettle();
        expect(find.text(english['headset_view_around']! as String), findsOneWidget);
        expect(find.text(english['headset_view_screen_2d']! as String), findsOneWidget);
        expect(find.text(english['headset_view_screen_sbs']! as String), findsNothing);
        expect(
          tester.widget<CheckedPopupMenuItem<Object>>(find.byKey(const Key('headset_view_around'))).checked,
          isTrue,
        );
        expect(find.byKey(const Key('headset_view_stop')), findsNothing, reason: 'nothing runs');

        await tester.tap(find.byKey(const Key('headset_view_around')));
        await settleStarted(tester);
        expect(api.starts.single.content.mode, XrHeadsetMode.sphere);
        await tester.runAsync(service.tick);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('headset_view_button')));
        await tester.pumpAndSettle();
        expect(find.text('In the headset: Meta Quest 3'), findsOneWidget);
        expect(find.byKey(const Key('headset_view_recenter')), findsOneWidget);
        expect(
          tester.widget<CheckedPopupMenuItem<Object>>(find.byKey(const Key('headset_view_lying_down'))).checked,
          isFalse,
        );
        await tester.tap(find.byKey(const Key('headset_view_lying_down')));
        await settle(tester);
        expect(api.recenters, [true]);

        await tester.tap(find.byKey(const Key('headset_view_button')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<CheckedPopupMenuItem<Object>>(find.byKey(const Key('headset_view_lying_down'))).checked,
          isTrue,
        );
        await tester.tap(find.byKey(const Key('headset_view_recenter')));
        await settle(tester);
        expect(api.recenters, [true, true]);

        await tester.tap(find.byKey(const Key('headset_view_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('headset_view_stop')));
        await settle(tester);
        expect(api.stops, 1);
        expect(service.running, isFalse);
      },
    );

    testWidgets('a flat page: 2D, 3D side by side, 3D over under, the one of the file name marked', (tester) async {
      final page = FakePage(
        choices: const [HeadsetChoice.screen2d, HeadsetChoice.screenSideBySide, HeadsetChoice.screenOverUnder],
        preselected: flatHeadsetChoiceOf(guessFlatStereoFormat(fileName: 'Avatar.2009.3D.HOU.mkv', isVideo: true)),
        source: HeadsetSourceKind.nas,
        video: HeadsetVideoKind.flat,
      );
      service.register(page.target);
      await tester.runAsync(service.refreshRuntime);
      await tester.pumpWidget(localized(bar(), service: service));
      await settle(tester);
      await tester.tap(find.byKey(const Key('headset_view_button')));
      await tester.pumpAndSettle();
      expect(find.text(english['headset_view_around']! as String), findsNothing);
      for (final (key, checked) in [
        ('headset_view_screen2d', false),
        ('headset_view_screenSideBySide', false),
        ('headset_view_screenOverUnder', true),
      ]) {
        expect(tester.widget<CheckedPopupMenuItem<Object>>(find.byKey(Key(key))).checked, checked, reason: key);
      }
      expect(find.text(english['headset_view_screen_ou']! as String), findsOneWidget);
    });
  });

  group('the 3D layout of a flat film', () {
    test('from the file name, full or half from it, else from the frame', () {
      expect(flatHeadsetChoiceOf(null), HeadsetChoice.screen2d);
      expect(flatHeadsetChoiceOf(FlatStereoFormat.halfSbs), HeadsetChoice.screenSideBySide);
      expect(flatHeadsetChoiceOf(FlatStereoFormat.tb), HeadsetChoice.screenOverUnder);
      expect(
        flatHeadsetLayout(HeadsetChoice.screenSideBySide, guess: FlatStereoFormat.halfSbs).squeeze,
        XrEyeSqueeze.half,
      );
      expect(
        flatHeadsetLayout(
          HeadsetChoice.screenSideBySide,
          guess: FlatStereoFormat.sbs,
          width: 1920,
          height: 1080,
        ).squeeze,
        XrEyeSqueeze.full,
        reason: 'the name says full',
      );
      expect(flatHeadsetLayout(HeadsetChoice.screenSideBySide, width: 1920, height: 1080).squeeze, XrEyeSqueeze.half);
      expect(flatHeadsetLayout(HeadsetChoice.screenSideBySide, width: 3840, height: 1080).squeeze, XrEyeSqueeze.full);
      expect(flatHeadsetLayout(HeadsetChoice.screenOverUnder, width: 1920, height: 1080).squeeze, XrEyeSqueeze.half);
      expect(flatHeadsetLayout(HeadsetChoice.screenOverUnder, width: 1920, height: 2160).squeeze, XrEyeSqueeze.full);
      final flat = flatHeadsetLayout(HeadsetChoice.screen2d, guess: FlatStereoFormat.sbs);
      expect((flat.mode, flat.stereo), (XrHeadsetMode.screen, XrStereo.mono));
      expect(headsetStripShowsSubtitles(flat), isFalse, reason: 'a flat 2D screen keeps the frame subtitles');
      expect(headsetStripShowsSubtitles(flatHeadsetLayout(HeadsetChoice.screenOverUnder)), isTrue);
      expect(
        headsetStripShowsSubtitles((mode: XrHeadsetMode.sphere, stereo: XrStereo.mono, squeeze: XrEyeSqueeze.full)),
        isTrue,
      );
    });
  });

  testWidgets('a raw file drawn by two players: the menu says not available and offers no layout', (tester) async {
    final page = FakePage()..notAvailable = 'a raw file drawn by two players';
    service.register(page.target);
    await tester.runAsync(service.refreshRuntime);
    await tester.pumpWidget(localized(bar(), service: service));
    await settle(tester);
    await tester.tap(find.byKey(const Key('headset_view_button')));
    await tester.pumpAndSettle();
    expect(find.text(english['headset_view_not_available']! as String), findsOneWidget);
    expect(find.byKey(const Key('headset_view_around')), findsNothing);
    expect(find.byKey(const Key('headset_view_screen2d')), findsNothing);
    await tester.tap(find.byKey(const Key('headset_view_not_available')), warnIfMissed: false);
    await settle(tester);
    expect(api.starts, isEmpty);
    // Once one player draws the whole frame, the layouts are back at the next opening of the menu
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    page.notAvailable = null;
    await tester.tap(find.byKey(const Key('headset_view_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('headset_view_around')), findsOneWidget);
    expect(find.byKey(const Key('headset_view_not_available')), findsNothing);
  });

  group('the setting row', () {
    String text(String key) => english[key]! as String;

    testWidgets('Linux and macOS: Windows only for now, the switch disabled', (tester) async {
      api.windows = false;
      await tester.pumpWidget(localized(const HeadsetViewSetting(), service: service));
      await settle(tester);
      expect(find.text(text('headset_view_setting_windows_only')), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('headset_view_setting_switch'))).onChanged, isNull);
    });

    testWidgets('a Windows build without the option shows no row', (tester) async {
      api.info = XrRuntimeInfo.notInBuild;
      await tester.pumpWidget(localized(const HeadsetViewSetting(), service: service));
      await settle(tester);
      expect(find.byKey(const Key('headset_view_setting_switch')), findsNothing);
    });

    testWidgets('no runtime: the plain message, no test pattern', (tester) async {
      api.info = const XrRuntimeInfo(compiled: true, registered: false);
      await tester.pumpWidget(localized(const HeadsetViewSetting(), service: service));
      await settle(tester);
      expect(find.textContaining(text('headset_view_setting_no_runtime')), findsOneWidget);
      expect(find.byKey(const Key('headset_view_pattern_24')), findsNothing);
    });

    testWidgets('a runtime: its name, the two switches, the patterns, the folder of the logs', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(
        localized(
          HeadsetViewSetting(
            openFolder: (folder) async {
              opened.add(folder);
              return true;
            },
          ),
          service: service,
        ),
      );
      await settle(tester);
      expect(find.textContaining('Runtime: SteamVR'), findsOneWidget);
      expect(find.text(text('headset_view_refresh_title')), findsOneWidget);
      expect(find.text(text('headset_view_pause_title')), findsOneWidget);
      expect(find.text('Test pattern at 24 frames per second'), findsOneWidget);
      expect(find.text('Test pattern at 30 frames per second'), findsOneWidget);
      await tester.tap(find.byKey(const Key('headset_view_open_logs')));
      await settle(tester);
      expect(opened, [p.join(folder.path, 'headset')]);
      await tester.tap(find.byKey(const Key('headset_view_pattern_30')));
      await settleStarted(tester);
      expect(api.starts.single.content.mode, XrHeadsetMode.pattern);
      expect(api.starts.single.content.fps, 30);
      await tester.tap(find.byKey(const Key('headset_view_setting_stop')));
      await settle(tester);
      expect(api.stops, 1);

      api.info = const XrRuntimeInfo(compiled: true, registered: true, runtime: '');
      await tester.runAsync(service.refreshRuntime);
      await tester.pumpAndSettle();
      expect(find.textContaining('Runtime: ${text('headset_view_runtime_other')}'), findsOneWidget);

      await tester.tap(find.byKey(const Key('headset_view_setting_switch')));
      await settle(tester);
      expect(service.settings.enabled.value, isFalse);
      expect(find.byKey(const Key('headset_view_setting_refresh')), findsNothing);
      expect(find.byKey(const Key('headset_view_pattern_24')), findsNothing);
      // The logs stay reachable with the switch off
      await tester.tap(find.byKey(const Key('headset_view_open_logs')));
      await settle(tester);
      expect(opened, [p.join(folder.path, 'headset'), p.join(folder.path, 'headset')]);
    });

    testWidgets('the crash guard turned the switch off: the folder of the logs is still there', (tester) async {
      // Two views in a row that were running when the app ended. Made in the real zone, as the service of setUp:
      // the settings' chain of writes would otherwise wait for the fake time
      final next = (await tester.runAsync(() async {
        final guarded = HeadsetViewSettings(folder: () async => folder);
        await guarded.markRunning();
        await guarded.checkCrashMarker();
        await guarded.markRunning();
        final next = testService(api, folder);
        expect(await next.settings.checkCrashMarker(), HeadsetCrashCheck.turnedOff);
        return next;
      }))!;
      addTearDown(next.dispose);
      final opened = <String>[];
      await tester.pumpWidget(
        localized(
          HeadsetViewSetting(
            openFolder: (folder) async {
              opened.add(folder);
              return true;
            },
          ),
          service: next,
        ),
      );
      await settle(tester);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('headset_view_setting_switch'))).value, isFalse);
      expect(find.byKey(const Key('headset_view_setting_refresh')), findsNothing);
      expect(find.byKey(const Key('headset_view_pattern_24')), findsNothing);
      await tester.tap(find.byKey(const Key('headset_view_open_logs')));
      await settle(tester);
      expect(opened, [p.join(folder.path, 'headset')]);
    });
  });

  testWidgets('every stop reason has its text, the window stopping it none; the notices', (tester) async {
    late Translations t;
    await tester.pumpWidget(
      localized(
        Builder(
          builder: (context) {
            t = context.t;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final keys = {
      XrStopReason.endedFromHeadset: 'headset_view_ended_from_headset',
      XrStopReason.noRuntime: 'headset_view_error_no_runtime',
      XrStopReason.loaderMissing: 'headset_view_error_loader_missing',
      XrStopReason.noHeadset: 'headset_view_error_no_headset',
      XrStopReason.otherGpu: 'headset_view_error_other_gpu',
      XrStopReason.gpuTooWeak: 'headset_view_error_gpu_too_weak',
      XrStopReason.runtimeLost: 'headset_view_error_runtime_lost',
      XrStopReason.runtimeNotAnswering: 'headset_view_error_not_answering',
      XrStopReason.notWindows: 'headset_view_setting_windows_only',
      XrStopReason.alreadyRunning: 'headset_view_error_failed',
      XrStopReason.notInBuild: 'headset_view_error_failed',
      XrStopReason.failed: 'headset_view_error_failed',
    };
    for (final reason in XrStopReason.values) {
      final shown = headsetStopText(t, reason);
      if (reason == XrStopReason.none || reason == XrStopReason.stoppedByApp) {
        expect(shown, isNull, reason: reason.name);
      } else {
        expect(shown, english[keys[reason]], reason: reason.name);
      }
    }
    expect(
      headsetNoticeText(t, const HeadsetNotice(HeadsetNoticeKind.experimental)),
      english['headset_view_experimental_notice'],
    );
    expect(
      headsetNoticeText(t, const HeadsetNotice(HeadsetNoticeKind.takenOff)),
      english['headset_view_paused_taken_off'],
    );
    expect(
      headsetNoticeText(t, const HeadsetNotice(HeadsetNoticeKind.crashGuard)),
      english['headset_view_crash_guard'],
    );
    expect(const HeadsetNotice(HeadsetNoticeKind.experimental).transient, isTrue);
    expect(const HeadsetNotice(HeadsetNoticeKind.stopped, reason: XrStopReason.noRuntime).transient, isFalse);
  });

  test('the texts of the headset view: no dash, no address, the probe keys gone', () {
    final keys = english.keys.where((key) => key.startsWith('headset_')).toList();
    expect(keys.where((key) => key.startsWith('headset_probe_')), isEmpty);
    expect(keys.length, greaterThanOrEqualTo(50));
    for (final key in keys) {
      final value = english[key]! as String;
      expect(value, isNot(matches(RegExp(r'[\u2012-\u2015]| - |://'))), reason: key);
    }
  });
}
