// The headset probe of the computers (lib/desktop/video/xr/headset_probe.dart): the switch kept in desktop_xr.json,
// off by default; the button hidden unless the switch is on, on Windows, in a build that has the probe; its menu
// starting the right mode with the player's handle, layout, yaw and a log file of the support folder, the test pattern
// with no player, a flat player's renderer C turned on before the start and off after the stop, a refusal shown.

import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/video/xr/headset_probe.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:media_kit_video/xr.dart';
import 'package:path/path.dart' as p;

class _FakeApi implements HeadsetProbeApi {
  _FakeApi({this.compiled = true});

  final bool compiled;
  final starts = <Map<String, Object?>>[];
  int stops = 0;
  int recenters = 0;
  XrProbeResult answer = const XrProbeResult(ok: true);
  bool running = false;

  @override
  Future<XrProbeResult> start({
    int? handle,
    required XrProbeMode mode,
    XrProbeStereo stereo = XrProbeStereo.mono,
    double fps = 0,
    double yaw = 0,
    required String logPath,
    String label = '',
  }) async {
    starts.add({
      'handle': handle,
      'mode': mode,
      'stereo': stereo,
      'fps': fps,
      'yaw': yaw,
      'logPath': logPath,
      'label': label,
    });
    running = answer.ok;
    return answer;
  }

  @override
  Future<bool> stop() async {
    stops++;
    running = false;
    return true;
  }

  @override
  Future<void> recenter() async => recenters++;

  @override
  Future<XrProbeState> state() async => XrProbeState(
    compiled: compiled,
    running: running,
    phase: running ? 'running' : 'stopped',
    sessionState: running ? 'focused' : '',
    reason: running ? '' : 'stopped by the app',
  );
}

void main() {
  late Directory folder;

  setUp(() async => folder = await Directory.systemTemp.createTemp('headset_probe_test'));
  tearDown(() async => folder.delete(recursive: true));

  HeadsetProbeSettings settings() => HeadsetProbeSettings(folder: () async => folder);

  test('the switch is off by default and kept in desktop_xr.json', () async {
    final first = settings();
    await first.load();
    expect(first.enabled.value, isFalse);
    await first.setEnabled(true);
    expect(jsonFile(folder), '{"probe":true}');
    final second = settings();
    await second.load();
    expect(second.enabled.value, isTrue);
  });

  test('a log file per start, in xr-probe of the support folder', () async {
    final path = await settings().newLogPath(now: DateTime(2026, 11, 14, 9, 5, 7));
    expect(path, p.join(folder.path, 'xr-probe', 'xr-probe-20261114-090507.log'));
    expect(Directory(p.dirname(path)).existsSync(), isTrue);
  });

  Future<HeadsetProbeAvailability> availability(_FakeApi api, {bool on = true, bool windows = true}) async {
    final kept = settings();
    if (on) {
      await kept.setEnabled(true);
    }
    return HeadsetProbeAvailability(settings: kept, api: api, windows: windows);
  }

  Widget page(HeadsetProbeAvailability availability, HeadsetProbeTarget Function() target) => EasyLocalization(
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
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Align(
            alignment: Alignment.topRight,
            child: HeadsetProbeButton(availability: availability, target: target),
          ),
        ),
      ),
    ),
  );

  HeadsetProbeTarget sphere() => HeadsetProbeTarget(
    handle: () async => 77,
    modes: const [XrProbeMode.sphere, XrProbeMode.screen],
    stereo: XrProbeStereo.leftRight,
    fps: 29.97,
    yaw: 40,
    label: '180 video, leftRight',
  );

  testWidgets('hidden while the switch is off, off Windows, or in a build without the probe', (tester) async {
    for (final (api, on, windows) in [
      (_FakeApi(), false, true),
      (_FakeApi(), true, false),
      (_FakeApi(compiled: false), true, true),
    ]) {
      final kept = await tester.runAsync(() => availability(api, on: on, windows: windows));
      await tester.pumpWidget(page(kept!, sphere));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('headset_probe_button')), findsNothing, reason: 'on $on, windows $windows');
    }
  });

  testWidgets('around you: the player, its layout, rate and yaw, a log file; recenter and stop', (tester) async {
    final api = _FakeApi();
    final kept = await tester.runAsync(() => availability(api));
    await tester.pumpWidget(page(kept!, sphere));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('headset_probe_button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('headset_probe_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('headset_probe_sphere')), findsOneWidget);
    expect(find.byKey(const Key('headset_probe_stop')), findsNothing, reason: 'nothing to stop yet');
    await tester.tap(find.byKey(const Key('headset_probe_sphere')));
    await settle(tester);
    expect(api.starts, hasLength(1));
    final start = api.starts.single;
    expect(start['handle'], 77);
    expect(start['mode'], XrProbeMode.sphere);
    expect(start['stereo'], XrProbeStereo.leftRight);
    expect(start['fps'], 29.97);
    expect(start['yaw'], 40.0);
    expect(start['label'], '180 video, leftRight');
    expect(start['logPath']! as String, startsWith(p.join(folder.path, 'xr-probe', 'xr-probe-')));
    await tester.tap(find.byKey(const Key('headset_probe_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('headset_probe_recenter')));
    await tester.pumpAndSettle();
    expect(api.recenters, 1);
    await tester.tap(find.byKey(const Key('headset_probe_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('headset_probe_stop')));
    await settle(tester);
    expect(api.stops, 1);
    expect(find.textContaining('stopped by the app'), findsOneWidget);
  });

  testWidgets('the test pattern needs no player', (tester) async {
    final api = _FakeApi();
    final kept = await tester.runAsync(() => availability(api));
    await tester.pumpWidget(page(kept!, sphere));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('headset_probe_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('headset_probe_pattern24')));
    await settle(tester);
    expect(api.starts.single['mode'], XrProbeMode.pattern);
    expect(api.starts.single['handle'], isNull);
    expect(api.starts.single['fps'], 24.0);
    expect(api.starts.single['label'], 'test pattern');
    // The page goes: so does the headset view
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    expect(api.stops, 1);
  });

  testWidgets('a flat player: renderer C on before the start, off after the stop; a refusal shown', (tester) async {
    final api = _FakeApi();
    final kept = await tester.runAsync(() => availability(api));
    final calls = <String>[];
    HeadsetProbeTarget flat() => HeadsetProbeTarget(
      handle: () async => 5,
      modes: const [XrProbeMode.screen],
      label: 'flat video',
      prepare: () async {
        calls.add('prepare');
        return true;
      },
      release: () async => calls.add('release'),
    );
    await tester.pumpWidget(page(kept!, flat));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('headset_probe_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('headset_probe_sphere')), findsNothing, reason: 'a flat player has no sphere');
    await tester.tap(find.byKey(const Key('headset_probe_screen')));
    await settle(tester);
    expect(calls, ['prepare']);
    expect(api.starts.single['mode'], XrProbeMode.screen);
    expect(api.starts.single['handle'], 5);
    await tester.tap(find.byKey(const Key('headset_probe_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('headset_probe_stop')));
    await settle(tester);
    expect(calls, ['prepare', 'release']);

    api.answer = const XrProbeResult(ok: false, reason: 'a headset view already runs');
    await tester.tap(find.byKey(const Key('headset_probe_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('headset_probe_screen')));
    await settle(tester);
    expect(find.textContaining('a headset view already runs'), findsOneWidget);
    expect(calls, ['prepare', 'release', 'prepare', 'release'], reason: 'renderer C off again after a refusal');
  });
}

/// The menu's pop, then the file of the log made on the disk and the calls after it: real time between pumps
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
  await tester.pumpAndSettle();
}

String jsonFile(Directory folder) => File(p.join(folder.path, HeadsetProbeSettings.fileName)).readAsStringSync();
