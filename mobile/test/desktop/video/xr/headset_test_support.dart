// What the tests of the headset view share (lib/desktop/video/xr): a fake plugin, a fake page, the service on a
// folder of its own, and a localized app around a widget.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/video/xr/headset_strip.dart';
import 'package:immich_mobile/desktop/video/xr/headset_view.dart';
import 'package:immich_mobile/desktop/video/xr/headset_view_service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:media_kit_video/xr.dart';

const steamVr = XrRuntimeInfo(
  compiled: true,
  registered: true,
  source: 'registry',
  manifestName: 'steamxr_win64.json',
  exists: true,
  runtime: 'SteamVR',
);

/// The plugin's headset view, as a test drives it
class FakeHeadsetApi implements HeadsetApi {
  FakeHeadsetApi({this.windows = true, this.info = steamVr});

  bool windows;
  XrRuntimeInfo info;
  final starts = <XrStartRequest>[];
  final contents = <XrContent>[];
  final strips = <({int bytes, bool visible})>[];
  final recenters = <bool>[];
  final rates = <double>[];
  int stops = 0;
  XrStartResult startAnswer = const XrStartResult(ok: true);

  /// What the next polls say
  bool running = false;
  String phase = 'running';
  String system = 'Meta Quest 3';
  String rightProfile = '/interaction_profiles/oculus/touch_controller';
  bool controllers = true;
  bool memoryTight = false;
  XrStopReason reason = XrStopReason.none;

  /// The events of the view; [replay] gives them all at each poll, as a plugin that drained nothing would
  final events = <XrEvent>[];
  bool replay = false;
  int _sequence = 0;

  /// A stop that waits for this before it answers
  Completer<void>? stopHangs;
  bool stopAnswer = true;

  void emit(XrEventKind kind, {double seconds = 0, bool on = false}) =>
      events.add(XrEvent(sequence: ++_sequence, kind: kind, seconds: seconds, on: on));

  @override
  bool get isWindows => windows;

  @override
  Future<XrRuntimeInfo> runtimeInfo() async => info;

  @override
  Future<XrStartResult> start(XrStartRequest request) async {
    starts.add(request);
    contents.add(request.content);
    running = startAnswer.ok;
    reason = XrStopReason.none;
    return startAnswer;
  }

  @override
  Future<void> setContent(XrContent content) async => contents.add(content);

  @override
  Future<void> setContentRate(double fps) async => rates.add(fps);

  @override
  Future<void> setStrip(Uint8List rgba, int width, int height, {required bool visible}) async =>
      strips.add((bytes: rgba.length, visible: visible));

  @override
  Future<void> recenter({bool lyingDown = false}) async => recenters.add(lyingDown);

  @override
  Future<XrHeadsetState> poll({int afterSequence = 0}) async => XrHeadsetState(
    compiled: true,
    running: running,
    phase: running ? phase : 'stopped',
    reason: running ? XrStopReason.none : reason,
    system: system,
    rightProfile: rightProfile,
    controllers: controllers,
    memoryTight: memoryTight,
    lastSequence: _sequence,
    events: [
      for (final event in events)
        if (replay || event.sequence > afterSequence) event,
    ],
  );

  @override
  Future<bool> stop() async {
    stops++;
    final hangs = stopHangs;
    if (hangs != null) {
      await hangs.future;
    }
    running = false;
    reason = stopAnswer ? XrStopReason.stoppedByApp : XrStopReason.runtimeNotAnswering;
    return stopAnswer;
  }
}

/// A page whose calls the tests read
class FakePage {
  FakePage({
    this.choices = const [HeadsetChoice.around, HeadsetChoice.screen2d],
    this.preselected = HeadsetChoice.around,
    this.handle = 7,
    this.title = 'Holiday in Lisbon.mp4',
    this.source = HeadsetSourceKind.player360,
    this.video = HeadsetVideoKind.video360,
    this.stereo = XrStereo.mono,
    this.canPrepare = true,
  });

  final List<HeadsetChoice> choices;
  final HeadsetChoice preselected;
  final int handle;
  final String title;
  final HeadsetSourceKind source;
  final HeadsetVideoKind video;
  final XrStereo stereo;
  final bool canPrepare;
  final calls = <String>[];
  final playback = ValueNotifier(const HeadsetPlayback(status: HeadsetPlaybackStatus.playing));
  final frameRate = ValueNotifier(0.0);
  final subtitle = ValueNotifier('');
  final changed = HeadsetSignal();

  /// Why the page cannot go to the headset yet (a raw file drawn by two players), null when it can
  String? notAvailable;

  late final target = HeadsetTarget(
    source: () => source,
    video: () => video,
    title: () => title,
    choices: choices,
    preselected: () => preselected,
    layoutOf: (choice) => switch (choice) {
      HeadsetChoice.around => (mode: XrHeadsetMode.sphere, stereo: stereo, squeeze: XrEyeSqueeze.full),
      _ => flatHeadsetLayout(choice, width: 3840, height: 1080),
    },
    handle: () async => handle,
    playPause: () {
      calls.add('playPause');
      playback.value = HeadsetPlayback(
        status: playback.value.status == HeadsetPlaybackStatus.playing
            ? HeadsetPlaybackStatus.paused
            : HeadsetPlaybackStatus.playing,
      );
    },
    seekBy: (delta) => calls.add('seek ${delta.inSeconds}'),
    pause: () {
      calls.add('pause');
      playback.value = const HeadsetPlayback(status: HeadsetPlaybackStatus.paused);
    },
    playback: playback,
    frameRate: frameRate,
    subtitle: subtitle,
    yaw: () => 40,
    prepare: (choice) async {
      calls.add('prepare ${choice.name}');
      return canPrepare;
    },
    release: () async => calls.add('release'),
    hideSubtitles: (hidden) async => calls.add('subtitles ${hidden ? 'hidden' : 'shown'}'),
    videoChanged: changed,
    notAvailable: () => notAvailable,
  );
}

/// The service on [folder], with no timer of its own (the tests poll with tick) and no drawing
HeadsetViewService testService(
  FakeHeadsetApi api,
  Directory folder, {
  List<HeadsetNotice>? notices,
  HeadsetViewSettings? settings,
  DateTime Function()? now,
}) => HeadsetViewService(
  api: api,
  settings: settings ?? HeadsetViewSettings(folder: () async => folder),
  renderStrip: (content, font, direction) async => Uint8List(headsetStripWidth * headsetStripHeight * 4),
  onNotice: (notice) => notices?.add(notice),
  appVersion: () async => '3.4.2+3030046',
  now: now,
  pollInterval: const Duration(hours: 1),
);

/// [child] in a localized app (English) with [service] as the app's headset view
Widget localized(Widget child, {HeadsetViewService? service}) => ProviderScope(
  overrides: [if (service != null) headsetViewServiceProvider.overrideWithValue(service)],
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
        home: Scaffold(body: child),
      ),
    ),
  ),
);

/// The English texts of the app (i18n/en.json)
final Map<String, Object?> english = Map<String, Object?>.from(
  jsonDecode(File('../i18n/en.json').readAsStringSync()) as Map,
);
