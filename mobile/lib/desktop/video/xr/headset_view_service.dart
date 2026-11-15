// The headset view of the app (headset_view.dart): one at a time, owned by the app and not by a page, so that it lives
// from one video to the next. HeadsetViewService starts it, polls it 10 times a second, applies the controllers'
// events to the page on screen, feeds the strip, and ends it: from the window, from the headset, by the runtime, or
// at the close of the window (a step of close_sequence.dart, bound 2 s, before the players go).
//
// The pages register their HeadsetTarget while their video is the one on screen (the newest registered is the one
// shown). While a view runs, the next video registered is attached with setContent, no new session; once no page is
// left (back to the library), the headset waits in its dark room with "Pick a video in the window".
//
// Events, each applied once by its sequence number: play or pause and seek go through the page's own controls; exit
// stops the view and pauses; the headset taken off pauses when the setting says so, and nothing resumes by itself;
// recenter and lying down update the menu. Any end the window did not ask pauses the video and says why.
//
// The crash guard (HeadsetViewSettings): a marker is written before each start and cleared at every end. A marker
// found at the app's start means a view took the app down: a notice; twice in a row turns the switch off.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/video/xr/headset_strip.dart';
import 'package:immich_mobile/desktop/video/xr/headset_view.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:media_kit_video/xr.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

/// Where the view is, as the window shows it
enum HeadsetViewPhase {
  /// No view
  off,

  /// Asked to the plugin, which opens the runtime
  starting,

  /// The runtime waits for a headset (a minute at most)
  waiting,

  /// In the headset
  running,

  /// Ending
  stopping,
}

/// The app's headset view
final headsetViewServiceProvider = Provider<HeadsetViewService>((ref) {
  final service = HeadsetViewService();
  ref.onDispose(service.dispose);
  return service;
});

class HeadsetViewService extends ChangeNotifier {
  HeadsetViewService({
    HeadsetApi? api,
    HeadsetViewSettings? settings,
    Future<Uint8List> Function(HeadsetStripContent content, String? fontFamily)? renderStrip,
    void Function(HeadsetNotice notice)? onNotice,
    Translations? translations,
    Future<String> Function()? appVersion,
    DateTime Function()? now,
    this.pollInterval = const Duration(milliseconds: 100),
  }) : api = api ?? const PluginHeadsetApi(),
       settings = settings ?? HeadsetViewSettings(),
       _renderStrip = renderStrip ?? ((content, font) => renderHeadsetStrip(content, fontFamily: font)),
       _onNotice = onNotice ?? showHeadsetNotice,
       _t = translations,
       _appVersion = appVersion ?? _packageVersion,
       _now = now ?? DateTime.now {
    _strip = HeadsetStripSender(
      render: (content) => _renderStrip(content, _fontFamily),
      send: (rgba, width, height, {required visible}) => this.api.setStrip(rgba, width, height, visible: visible),
      now: _now,
    );
    this.settings.enabled.addListener(notifyListeners);
  }

  final HeadsetApi api;
  final HeadsetViewSettings settings;
  final Duration pollInterval;
  final Future<Uint8List> Function(HeadsetStripContent content, String? fontFamily) _renderStrip;
  final void Function(HeadsetNotice notice) _onNotice;
  final Translations? _t;
  final Future<String> Function() _appVersion;
  final DateTime Function() _now;
  late final HeadsetStripSender _strip;

  Translations get t => _t ?? StaticTranslations.instance;

  /// How long the close of the window waits for the view to end
  static const closeBound = Duration(seconds: 2);

  bool _disposed = false;
  XrRuntimeInfo? _runtime;
  final _targets = <HeadsetTarget>[];

  HeadsetViewPhase _phase = HeadsetViewPhase.off;
  HeadsetTarget? _shown;
  HeadsetChoice? _choice;
  bool _pattern = false;
  bool _stopAsked = false;
  bool _reachedRunning = false;
  int _lastSequence = 0;
  String _logName = '';
  XrHeadsetState? _state;
  Timer? _poll;
  bool _polling = false;
  DateTime? _flashAt;
  Timer? _flashEnd;
  bool _subtitlesHidden = false;
  String? _fontFamily;
  Future<void> _queue = Future.value();

  /// The runtime registered, as read at the last page opened (null before)
  XrRuntimeInfo? get runtime => _runtime;

  /// Windows, the only system for now
  bool get windows => api.isWindows;

  /// Whether the button shows: the switch on, Windows, a build with the plugin's option and a runtime registered
  bool get available =>
      settings.enabled.value && windows && (_runtime?.compiled ?? false) && (_runtime?.registered ?? false);

  HeadsetViewPhase get phase => _phase;
  bool get running => _phase != HeadsetViewPhase.off;

  /// The page on screen, the newest registered
  HeadsetTarget? get target => _targets.isEmpty ? null : _targets.last;

  /// What the headset shows now, null in the dark room or for the pattern
  HeadsetTarget? get shown => _shown;
  HeadsetChoice? get choice => _choice;
  bool get pattern => _pattern;
  bool get lyingDown => _state?.lyingDown ?? false;

  /// The headset's name once the runtime tells it
  String get headset => _state?.system ?? '';
  XrHeadsetState? get state => _state;

  /// The status line of the menu
  String get statusText => switch (_phase) {
    HeadsetViewPhase.starting => t.headset_view_starting,
    HeadsetViewPhase.waiting => t.headset_view_waiting,
    HeadsetViewPhase.running => t.headset_view_running(headset: headset.isEmpty ? '?' : headset),
    HeadsetViewPhase.stopping || HeadsetViewPhase.off => '',
  };

  /// The keys H and Shift+H act: a view runs, or a page that can be shown is on screen
  bool get handlesKeys => running || (available && target != null);

  static Future<String> _packageVersion() async {
    final info = await PackageInfo.fromPlatform();
    return '${info.version}+${info.buildNumber}';
  }

  /// One call after the other: a start, a switch and a stop never cross
  Future<T> _serial<T>(Future<T> Function() action) {
    final done = _queue.then((_) => action());
    _queue = done.then<void>((_) {}, onError: (Object _) {});
    return done;
  }

  void _changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// At the app's start: the crash guard reads its marker (Windows only; elsewhere nothing is read)
  Future<void> startUp() async {
    if (!windows) {
      return;
    }
    final check = await settings.checkCrashMarker();
    switch (check) {
      case HeadsetCrashCheck.none:
        break;
      case HeadsetCrashCheck.once:
        headsetViewLog.warning('The last headset view was running when the app ended');
        _onNotice(const HeadsetNotice(HeadsetNoticeKind.crashOnce));
      case HeadsetCrashCheck.turnedOff:
        headsetViewLog.warning(
          'Two headset views in a row were running when the app ended: View in headset turned off',
        );
        _onNotice(const HeadsetNotice(HeadsetNoticeKind.crashGuard));
    }
    _changed();
  }

  /// Reads the runtime registered again, without loading any DLL (a page opened, the setting row shown)
  Future<XrRuntimeInfo> refreshRuntime() async {
    if (!windows) {
      _runtime = XrRuntimeInfo.notWindows;
      _changed();
      return XrRuntimeInfo.notWindows;
    }
    await settings.load();
    final info = await api.runtimeInfo();
    _runtime = info;
    _changed();
    return info;
  }

  /// A page's video is on screen
  void register(HeadsetTarget target) {
    if (_disposed) {
      return;
    }
    _targets
      ..remove(target)
      ..add(target);
    unawaited(refreshRuntime());
    if (running && !_pattern && !identical(_shown, target)) {
      unawaited(_serial(() => _show(target, target.preselected())));
    }
    _changed();
  }

  /// A page's video left the screen
  void unregister(HeadsetTarget target) {
    if (_disposed || !_targets.remove(target)) {
      return;
    }
    if (identical(_shown, target)) {
      // At once: the page disposes what the strip follows right after this
      _follow(null);
      final next = this.target;
      unawaited(_serial(() => next == null ? _showIdle() : _show(next, next.preselected())));
    }
    _changed();
  }

  /// "View in headset" with [choice] of the page on screen; while a view runs, the page or the layout changes with
  /// no new session
  Future<void> start(HeadsetChoice choice, {Locale? locale}) => _serial(() async {
    final page = target;
    if (page == null) {
      return;
    }
    _setFont(locale);
    if (running) {
      _pattern = false;
      return _show(page, choice);
    }
    final reason = page.notAvailable?.call();
    if (reason != null) {
      headsetViewLog.info('Not shown in the headset yet ($reason): no view started');
      return;
    }
    await _start(page, choice: choice);
  });

  /// The test pattern of the setting row, no player
  Future<void> startPattern(double fps, {Locale? locale}) => _serial(() async {
    _setFont(locale);
    if (running) {
      await _release();
      _pattern = true;
      _changed();
      await api.setContent(XrContent(mode: XrHeadsetMode.pattern, fps: fps, label: 'test pattern'));
      return;
    }
    await _start(null, patternFps: fps);
  });

  /// H: starts the page's preselected choice, or stops the view
  Future<void> toggle({Locale? locale}) {
    if (running) {
      return stop();
    }
    final page = target;
    if (page == null || !available || page.notAvailable?.call() != null) {
      return Future.value();
    }
    return start(page.preselected(), locale: locale);
  }

  void _setFont(Locale? locale) {
    if (locale == null) {
      return;
    }
    // As the app's theme chooses it (theme_data.dart)
    _fontFamily = localesNotSupportedByAppFont.contains(locale) ? null : 'GoogleSans';
  }

  Future<void> _start(HeadsetTarget? page, {HeadsetChoice? choice, double? patternFps}) async {
    await settings.load();
    _phase = HeadsetViewPhase.starting;
    _stopAsked = false;
    _reachedRunning = false;
    _state = null;
    _pattern = page == null;
    _changed();
    // The crash guard's marker, before anything of the runtime runs
    await settings.markRunning();
    final logPath = await settings.newLogPath();
    _logName = p.basename(logPath);
    XrContent content;
    if (page == null) {
      content = XrContent(mode: XrHeadsetMode.pattern, fps: patternFps ?? 24, label: 'test pattern');
    } else {
      final chosen = choice ?? page.preselected();
      if (page.prepare != null && !await page.prepare!(chosen)) {
        headsetViewLog.warning('The page could not be drawn for the headset, no view started');
        await page.release?.call();
        await _endedBeforeStart(XrStopReason.failed);
        return;
      }
      _shown = page;
      _choice = chosen;
      content = await _contentOf(page, chosen);
      await _hideSubtitles(page, chosen);
    }
    String version;
    try {
      version = await _appVersion();
    } catch (_) {
      version = 'unknown';
    }
    final result = await api.start(
      XrStartRequest(
        content: content,
        logPath: logPath,
        matchRefreshRate: settings.matchRefreshRate.value,
        actionNames: headsetActionNames(t),
        appVersion: '$version, media_kit_360 $headsetPluginCommit',
      ),
    );
    if (!result.ok) {
      headsetViewLog.warning('Headset view not started: ${result.reason.name}, log $_logName');
      await _release();
      await _endedBeforeStart(result.reason);
      return;
    }
    headsetViewLog.info('Headset view started: ${content.label}, log $_logName');
    _lastSequence = 0;
    _strip.reset();
    _follow(page);
    _poll?.cancel();
    _poll = Timer.periodic(pollInterval, (_) => unawaited(tick()));
    _onNotice(const HeadsetNotice(HeadsetNoticeKind.experimental));
    _flash();
    _changed();
  }

  Future<void> _endedBeforeStart(XrStopReason reason) async {
    _phase = HeadsetViewPhase.off;
    _shown = null;
    _choice = null;
    _pattern = false;
    await settings.clearRunning(good: false);
    _onNotice(HeadsetNotice(HeadsetNoticeKind.stopped, reason: reason));
    _changed();
  }

  Future<XrContent> _contentOf(HeadsetTarget page, HeadsetChoice choice) async {
    final layout = page.layoutOf(choice);
    int? handle;
    try {
      handle = await page.handle();
    } catch (error) {
      headsetViewLog.fine('No player handle for the headset: $error');
    }
    return XrContent(
      handle: handle,
      mode: layout.mode,
      stereo: layout.stereo,
      squeeze: layout.squeeze,
      fps: page.frameRate.value,
      yaw: page.yaw?.call() ?? 0,
      label: page.labelOf(choice),
    );
  }

  /// The headset shows [page] with [choice], the view running
  Future<void> _show(HeadsetTarget page, HeadsetChoice choice) async {
    if (!running) {
      return;
    }
    final reason = page.notAvailable?.call();
    if (reason != null) {
      headsetViewLog.info('Not shown in the headset yet ($reason): the dark room');
      return _showIdle();
    }
    if (!identical(_shown, page)) {
      await _release();
    } else {
      await _hideSubtitles(page, null);
    }
    if (page.prepare != null && !await page.prepare!(choice)) {
      headsetViewLog.warning('The page could not be drawn for the headset: the dark room');
      await page.release?.call();
      return _showIdle();
    }
    _shown = page;
    _choice = choice;
    _pattern = false;
    final content = await _contentOf(page, choice);
    await _hideSubtitles(page, choice);
    headsetViewLog.info('Headset view shows ${content.label}');
    await api.setContent(content);
    _follow(page);
    _flash();
    _changed();
  }

  Future<void> _showIdle() async {
    await _release();
    if (!running) {
      return;
    }
    headsetViewLog.info('Headset view waits for a video');
    await api.setContent(XrContent.idle);
    _follow(null);
    _flash();
    _changed();
  }

  /// The page shown no longer is: its frame's subtitles back, renderer C's flat pass off
  Future<void> _release() async {
    final page = _shown;
    _shown = null;
    _choice = null;
    _follow(null);
    if (page != null) {
      await _hideSubtitles(page, null);
      try {
        await page.release?.call();
      } catch (error) {
        headsetViewLog.fine('The page was not released: $error');
      }
    }
  }

  /// The frame's subtitles hidden while the strip shows them ([choice] null: back as they were)
  Future<void> _hideSubtitles(HeadsetTarget page, HeadsetChoice? choice) async {
    final hide = choice != null && headsetStripShowsSubtitles(page.layoutOf(choice));
    if (hide == _subtitlesHidden && choice != null) {
      return;
    }
    _subtitlesHidden = hide;
    await page.hideSubtitles?.call(hide);
  }

  HeadsetTarget? _followed;

  /// The strip follows [page]'s playback, and the headset its frame rate and its next video
  void _follow(HeadsetTarget? page) {
    final before = _followed;
    if (identical(before, page)) {
      return;
    }
    if (before != null) {
      before.playback.removeListener(_onPlayback);
      before.subtitle.removeListener(_updateStrip);
      before.frameRate.removeListener(_onRate);
      before.videoChanged?.removeListener(_onVideoChanged);
    }
    _followed = page;
    if (page != null) {
      page.playback.addListener(_onPlayback);
      page.subtitle.addListener(_updateStrip);
      page.frameRate.addListener(_onRate);
      page.videoChanged?.addListener(_onVideoChanged);
      _lastStatus = page.playback.value.status;
    }
    // The callers show the strip once they set what the headset shows (_flash)
  }

  HeadsetPlaybackStatus? _lastStatus;

  void _onPlayback() {
    final status = _followed?.playback.value.status;
    if (status != _lastStatus) {
      _lastStatus = status;
      _flash();
    } else {
      _updateStrip();
    }
  }

  void _onRate() {
    final page = _followed;
    if (page != null && running && page.frameRate.value > 0) {
      unawaited(api.setContentRate(page.frameRate.value));
    }
  }

  /// The page plays another video, has another player or another 3D layout: shown again, in the same choice
  void _onVideoChanged() {
    final page = _followed;
    if (page != null && running) {
      unawaited(_serial(() => _show(page, _choice ?? page.preselected())));
    }
  }

  /// One poll of the view: its state and the events since the last one. The timer calls it 10 times a second.
  Future<void> tick() async {
    if (_polling || !running || _disposed) {
      return;
    }
    _polling = true;
    try {
      final state = await api.poll(afterSequence: _lastSequence);
      if (_disposed) {
        return;
      }
      await _take(state);
    } catch (error) {
      headsetViewLog.fine('The headset view did not answer a poll: $error');
    } finally {
      _polling = false;
    }
  }

  Future<void> _take(XrHeadsetState state) async {
    final before = _state;
    _state = state;
    for (final event in state.events) {
      if (event.sequence <= _lastSequence) {
        // Already applied
        continue;
      }
      _lastSequence = event.sequence;
      await _apply(event);
      if (!running) {
        return;
      }
    }
    _lastSequence = math.max(_lastSequence, state.lastSequence);
    if (!state.running) {
      if (_phase != HeadsetViewPhase.stopping) {
        await _serial(() => _ended(state.reason));
      }
      return;
    }
    final phase = switch (state.phase) {
      'waiting for the headset' => HeadsetViewPhase.waiting,
      'running' => HeadsetViewPhase.running,
      _ => _phase == HeadsetViewPhase.stopping ? HeadsetViewPhase.stopping : HeadsetViewPhase.starting,
    };
    if (phase == HeadsetViewPhase.running) {
      _reachedRunning = true;
    }
    final changed =
        phase != _phase ||
        before?.system != state.system ||
        before?.lyingDown != state.lyingDown ||
        before?.profile != state.profile ||
        before?.controllers != state.controllers ||
        before?.memoryTight != state.memoryTight;
    if (_phase != HeadsetViewPhase.stopping) {
      _phase = phase;
    }
    if (changed) {
      if (before?.memoryTight != state.memoryTight || before?.profile != state.profile) {
        _flash();
      } else {
        _updateStrip();
      }
      _changed();
    }
  }

  Future<void> _apply(XrEvent event) async {
    final page = _shown;
    headsetViewLog.fine('Headset event ${event.sequence}: ${event.kind.name}');
    switch (event.kind) {
      case XrEventKind.playPause:
        _safely(page?.playPause);
        _flash();
      case XrEventKind.seek:
        _safely(() => page?.seekBy(Duration(milliseconds: (event.seconds * 1000).round())));
        _flash();
      case XrEventKind.recenter:
        _flash();
      case XrEventKind.lyingDown:
        _state = _withLyingDown(_state, event.on);
        _flash();
        _changed();
      case XrEventKind.exit:
        _safely(page?.pause);
        await stop();
      case XrEventKind.visibility:
        if (!event.on && settings.pauseWhenTakenOff.value && page != null) {
          // Never resumed by itself: the user resumes from the headset or the window
          if (page.playback.value.status == HeadsetPlaybackStatus.playing ||
              page.playback.value.status == HeadsetPlaybackStatus.buffering) {
            _safely(page.pause);
            _onNotice(const HeadsetNotice(HeadsetNoticeKind.takenOff));
          }
        }
        _flash();
      case XrEventKind.profile:
        _flash();
    }
  }

  /// A call into a page, which may have gone meanwhile
  static void _safely(void Function()? call) {
    try {
      call?.call();
    } catch (error) {
      headsetViewLog.fine('The page did not take the headset action: $error');
    }
  }

  static XrHeadsetState? _withLyingDown(XrHeadsetState? state, bool on) => state == null
      ? null
      : XrHeadsetState(
          compiled: state.compiled,
          running: state.running,
          phase: state.phase,
          sessionState: state.sessionState,
          visible: state.visible,
          focused: state.focused,
          system: state.system,
          runtime: state.runtime,
          leftProfile: state.leftProfile,
          rightProfile: state.rightProfile,
          controllers: state.controllers,
          lyingDown: on,
          memoryTight: state.memoryTight,
          lastSequence: state.lastSequence,
        );

  /// The view ended: by the window ([_stopAsked]) or not
  Future<void> _ended(XrStopReason reason) async {
    if (_phase == HeadsetViewPhase.off) {
      return;
    }
    _poll?.cancel();
    _poll = null;
    _flashEnd?.cancel();
    final asked = _stopAsked;
    final page = _shown;
    await _release();
    _phase = HeadsetViewPhase.off;
    _pattern = false;
    final good = _reachedRunning && reason != XrStopReason.runtimeNotAnswering;
    await settings.clearRunning(good: good);
    headsetViewLog.info('Headset view ended: ${reason.name}, log $_logName');
    if (!asked) {
      _safely(page?.pause);
    }
    if (!asked || reason == XrStopReason.runtimeNotAnswering) {
      _onNotice(HeadsetNotice(HeadsetNoticeKind.stopped, reason: reason));
    }
    _changed();
  }

  /// "Stop the headset view"
  Future<void> stop() => _serial(() async {
    if (!running) {
      return;
    }
    _stopAsked = true;
    _phase = HeadsetViewPhase.stopping;
    _changed();
    var ended = false;
    try {
      ended = await api.stop();
    } catch (error) {
      headsetViewLog.warning('The headset view did not stop: $error');
    }
    var reason = ended ? XrStopReason.stoppedByApp : XrStopReason.runtimeNotAnswering;
    try {
      final last = await api.poll(afterSequence: _lastSequence);
      if (!last.running && last.reason != XrStopReason.none) {
        reason = last.reason;
      }
    } catch (_) {
      // The reason asked stays
    }
    if (!ended) {
      reason = XrStopReason.runtimeNotAnswering;
    }
    await _ended(reason);
  });

  /// "Recenter": what is ahead becomes the centre, lying down kept as it is
  Future<void> recenter() async {
    if (!running) {
      return;
    }
    await api.recenter(lyingDown: lyingDown);
    _flash();
  }

  /// "Lying down": the centre follows the head's pitch too, or no longer
  Future<void> setLyingDown(bool on) async {
    if (!running) {
      return;
    }
    await api.recenter(lyingDown: on);
    _state = _withLyingDown(_state, on);
    _flash();
    _changed();
  }

  /// The step of the window's close: the marker cleared first (the app is closing on purpose), then the stop
  Future<void> closeForExit() async {
    if (!running) {
      return;
    }
    await settings.clearRunning(good: true);
    await stop();
  }

  /// The strip shows for [headsetStripFlash] from now
  void _flash() {
    _flashAt = _now();
    _flashEnd?.cancel();
    _flashEnd = Timer(headsetStripFlash, _updateStrip);
    _updateStrip();
  }

  void _updateStrip() {
    if (!running || _disposed) {
      return;
    }
    final state = _state;
    final hint = headsetHintOf(state?.profile ?? '', controllers: state?.controllers ?? false);
    final page = _followed;
    final idle = page == null && !_pattern;
    final playback = page?.playback.value ?? const HeadsetPlayback();
    final choice = _choice;
    final subtitle = page != null && choice != null && headsetStripShowsSubtitles(page.layoutOf(choice))
        ? page.subtitle.value
        : '';
    final flashAt = _flashAt;
    final content = headsetStripContentOf(
      t,
      idle: idle,
      title: page?.title() ?? '',
      playback: playback,
      hint: hint,
      memoryTight: state?.memoryTight ?? false,
      subtitle: subtitle,
    );
    final visible =
        !_pattern &&
        headsetStripVisible(
          idle: idle,
          status: playback.status,
          subtitle: subtitle,
          sinceFlash: flashAt == null ? null : _now().difference(flashAt),
        );
    _strip.update(content, visible: visible);
  }

  /// The strip's sender, for the tests
  @visibleForTesting
  HeadsetStripSender get strip => _strip;

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _flashEnd?.cancel();
    _strip.dispose();
    settings.enabled.removeListener(notifyListeners);
    _follow(null);
    super.dispose();
  }
}

/// Shows [notice] in the window: those that only inform fade after 4 s, the others stay 10 s
void showHeadsetNotice(HeadsetNotice notice) {
  final text = headsetNoticeText(StaticTranslations.instance, notice);
  if (text == null) {
    return;
  }
  if (notice.kind == HeadsetNoticeKind.stopped || notice.kind == HeadsetNoticeKind.crashGuard) {
    snackbar.error(text, duration: const Duration(seconds: 10));
  } else {
    snackbar.info(text, duration: const Duration(seconds: 4));
  }
}
