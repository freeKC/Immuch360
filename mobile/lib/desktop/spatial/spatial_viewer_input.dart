// The input of one Spatial 2.5D view on the computers and the lifecycle of its webcam: the ViewerPositionSource the
// photo page and the video route read their viewpoint from.
//
// The webcam opens only when all of these hold:
// - the view is on screen (attach after the page is built, detach when it closes or another page covers it);
// - the window is not minimised or hidden (the app's lifecycle) and nobody is away (session locked, display off:
//   DesktopSessionPresence);
// - the head moves the view, "Use the webcam for head tracking" is on, and the user said yes on the card of the first
//   time (needsConsent shows it; no answer, no webcam);
// - the last try did not end on a problem (a refusal of the system, no webcam, the webcam busy or gone): a problem is
//   shown with its message and nothing opens the webcam again but the user (retry, or choosing the head again).
// Whenever one stops holding, the webcam closes and its light goes off. While the head is chosen but cannot be used
// (no consent yet, said no, the webcam off in the settings, a problem), the mouse moves the view: never an error page.
//
// The other inputs: the mouse over the picture (its x from the left edge to the right one, smoothed by the phones' One
// Euro filter), the automatic sway (0.5 + 0.2 sin(2 pi t / 4 s), no input at all) and the keys (the arrows and the
// slider move the viewpoint by steps, R recenters).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position.dart';
import 'package:immich_mobile/desktop/window/session_presence.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';
import 'package:logging/logging.dart';

final _log = Logger('SpatialViewerInput');

/// See the top of this file
class SpatialViewerInput extends ChangeNotifier with WidgetsBindingObserver implements ViewerPositionSource {
  SpatialViewerInput({
    required DesktopSpatialSettingsStore store,
    SpatialHeadSource? source,
    ValueListenable<bool>? away,
    Duration Function()? clock,
    bool observeLifecycle = true,
  }) : _store = store,
       _settings = store.read(),
       _away = away ?? DesktopSessionPresence.instance.away,
       _observeLifecycle = observeLifecycle,
       _source = source {
    _clock = clock ?? _stopwatchClock();
    _tracking = SpatialHeadTracking(source: source, sensitivity: _settings.sensitivity)
      ..reversed = _settings.reverseHead;
    _tracking.addListener(_onTracking);
    _chosen = _settings.startInput;
    _away.addListener(_update);
    if (_observeLifecycle) {
      WidgetsBinding.instance.addObserver(this);
    }
  }

  /// The input of the app: the tracker's library of the computer, the app's settings
  factory SpatialViewerInput.app() =>
      SpatialViewerInput(store: const AppSpatialSettingsStore(), source: NativeSpatialHeadSource.desktop());

  static Duration Function() _stopwatchClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  /// One step of the arrow keys
  static const keyStep = 0.05;

  /// The period and reach of the automatic sway
  static const swayPeriod = Duration(seconds: 4);
  static const swayReach = 0.2;

  final DesktopSpatialSettingsStore _store;
  final SpatialHeadSource? _source;
  final ValueListenable<bool> _away;
  final bool _observeLifecycle;
  late final Duration Function() _clock;
  late final SpatialHeadTracking _tracking;
  DesktopSpatialSettings _settings;
  late ViewerInput _chosen;
  bool _onScreen = false;
  bool _windowShown = true;
  bool _declined = false;
  bool _disposed = false;
  double _keysX = ViewerPosition.centreX;
  double _mouseX = ViewerPosition.centreX;
  final _mouseFilter = OneEuroFilter();

  /// The head tracking behind the head input (its state, its problem, the webcams listed)
  SpatialHeadTracking get tracking => _tracking;

  DesktopSpatialSettings get settings => _settings;

  /// What the user chose to move the view
  ViewerInput get chosen => _chosen;

  /// Whether this computer has a head tracker at all (its library loaded)
  bool get headSupported => _source != null;

  /// The head is chosen and the webcam may run: allowed in the settings, agreed to, no problem
  bool get _headUsable =>
      _chosen == ViewerInput.head &&
      headSupported &&
      _settings.webcam &&
      _settings.consent &&
      _tracking.problem == null;

  /// What moves the view now: the mouse while the head is chosen but cannot be used
  ViewerInput get input => _chosen == ViewerInput.head && !_headUsable ? ViewerInput.mouse : _chosen;

  /// The card that explains the webcam is due: the head is chosen, the webcam allowed, and the user never answered
  bool get needsConsent =>
      _onScreen && _chosen == ViewerInput.head && headSupported && _settings.webcam && !_settings.consent && !_declined;

  /// The webcam is open now (its light on): the page shows the camera icon
  bool get cameraOpen => _tracking.cameraOpen;

  /// Why the head cannot be used, null when nothing is wrong
  SpatialTrackingProblem? get problem => _chosen == ViewerInput.head ? _tracking.problem : null;

  bool get onScreen => _onScreen;

  /// The webcam may run: see the top of this file
  @visibleForTesting
  bool get shouldRunCamera => _onScreen && _windowShown && !_away.value && _headUsable;

  /// The view is on screen: the webcam may open
  void attach() {
    if (_onScreen || _disposed) {
      return;
    }
    _onScreen = true;
    _update();
    notifyListeners();
  }

  /// The view left the screen (closed, or covered by another page): the webcam closes
  void detach() {
    if (!_onScreen || _disposed) {
      return;
    }
    _onScreen = false;
    _update();
    notifyListeners();
  }

  /// "Use the webcam" on the card: remembered, then the webcam opens
  Future<void> acceptConsent() async {
    _declined = false;
    await _save(_settings.copyWith(consent: true, webcam: true, input: ViewerInput.head));
    _chosen = ViewerInput.head;
    _update();
    _notify();
  }

  /// "Use the mouse" on the card: the mouse moves the view, and it stays the choice until the user picks the head again
  Future<void> declineConsent() async {
    _declined = true;
    _chosen = ViewerInput.mouse;
    await _save(_settings.copyWith(input: ViewerInput.mouse));
    _update();
    _notify();
  }

  /// Another input chosen in the menu. Choosing the head again after a problem tries the webcam again.
  Future<void> choose(ViewerInput input) async {
    if (input == ViewerInput.head) {
      _declined = false;
      if (_tracking.problem != null) {
        await _tracking.stop();
      }
    }
    _chosen = input;
    _mouseFilter.reset();
    await _save(_settings.copyWith(input: input));
    _update();
    _notify();
  }

  /// The user asks for the webcam again after a problem (the message's button)
  Future<void> retry() async {
    await _tracking.stop();
    _update();
    _notify();
  }

  /// "Use the webcam for head tracking" in the settings: off closes the webcam at once
  Future<void> setWebcamAllowed(bool allowed) async {
    await _save(_settings.copyWith(webcam: allowed));
    _update();
    _notify();
  }

  Future<void> setReverseHead(bool reversed) async {
    _tracking.reversed = reversed;
    await _save(_settings.copyWith(reverseHead: reversed));
    _notify();
  }

  Future<void> setSensitivity(double sensitivity) async {
    _tracking.sensitivity = sensitivity;
    await _save(_settings.copyWith(sensitivity: sensitivity));
    _notify();
  }

  /// The webcam picked in the menu (null for the default one); a running webcam is changed at once
  Future<void> setCamera(String? cameraId) async {
    await _save(_settings.copyWith(cameraId: cameraId, clearCamera: cameraId == null));
    if (_tracking.cameraOpen) {
      await _tracking.stop();
      _update();
    }
    _notify();
  }

  Future<void> _save(DesktopSpatialSettings settings) async {
    _settings = settings;
    try {
      await _store.write(settings);
    } catch (error) {
      _log.warning('The Spatial 2.5D settings were not saved: $error');
    }
  }

  @override
  ViewerPosition get position {
    final input = this.input;
    switch (input) {
      case ViewerInput.head:
        final value = _tracking.viewpointNow();
        return ViewerPosition(
          x: ViewerPosition.clampX(value ?? ViewerPosition.centreX),
          input: input,
          tracking: _tracking.latest?.hasFace ?? false,
        );
      case ViewerInput.mouse:
        return ViewerPosition(x: ViewerPosition.clampX(_mouseX), input: input);
      case ViewerInput.sway:
        final t = _clock().inMicroseconds / swayPeriod.inMicroseconds;
        return ViewerPosition(
          x: ViewerPosition.clampX(ViewerPosition.centreX + swayReach * math.sin(2 * math.pi * t)),
          input: input,
        );
      case ViewerInput.keys:
        return ViewerPosition(x: ViewerPosition.clampX(_keysX), input: input);
    }
  }

  @override
  void pointer(double fraction) {
    if (fraction.isNaN) {
      return;
    }
    final target = ViewerPosition.min + (ViewerPosition.max - ViewerPosition.min) * fraction.clamp(0.0, 1.0);
    // The phones' filter on the pointer, in the 640 pixel scale its parameters are tuned for
    _mouseX = _mouseFilter.filter(target * 640, _clock().inMicroseconds * 1000) / 640;
  }

  @override
  void step(double delta) {
    if (_chosen == ViewerInput.keys) {
      _keysX = ViewerPosition.clampX(_keysX + delta);
    } else {
      // The arrow keys and the slider take over from the other inputs for this view (the choice kept in the settings
      // stays): the webcam closes
      _keysX = ViewerPosition.clampX(position.x + delta);
      _chosen = ViewerInput.keys;
      _update();
      _notify();
    }
  }

  @override
  void recenter() {
    _keysX = ViewerPosition.centreX;
    _mouseFilter.reset();
    _mouseX = ViewerPosition.centreX;
    _tracking.recenter();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Minimised or hidden: hidden then paused; restored: inactive then resumed. A window that only lost the focus
    // stays shown, as the user may watch it beside another one.
    final shown = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (shown != _windowShown) {
      _windowShown = shown;
      _update();
    }
  }

  /// Opens or closes the webcam as the rules at the top of this file say
  void _update() {
    if (_disposed) {
      return;
    }
    final run = shouldRunCamera;
    final state = _tracking.state;
    if (run && state == SpatialTrackingState.off) {
      unawaited(_tracking.start(cameraId: _settings.cameraId));
    } else if (!run && (state == SpatialTrackingState.running || state == SpatialTrackingState.starting)) {
      unawaited(_tracking.stop());
    }
  }

  void _onTracking() => _notify();

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _onScreen = false;
    _away.removeListener(_update);
    if (_observeLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _tracking.removeListener(_onTracking);
    // Closes the webcam (its release goes on in the background)
    _tracking.dispose();
    super.dispose();
  }
}
