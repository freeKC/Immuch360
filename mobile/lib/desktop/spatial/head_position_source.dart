// The head as a source of viewer positions (viewer_position.dart) for the Spatial 2.5D views of the computers, and the
// lifecycle of its webcam.
//
// The webcam opens only when all of these hold:
// - a view shows this source (attach when the view is on screen, detach when it closes or another page covers it);
// - the window is not minimised or hidden (the app's lifecycle) and nobody is away (session locked, display off:
//   DesktopSessionPresence);
// - "Use the webcam for head tracking" is on, and the user said yes on the card of the first time (needsConsent asks
//   the view to show it; no answer, no webcam);
// - the last try did not end on a problem (a refusal of the system, no webcam, the webcam busy or gone): the problem
//   is shown with its message, and nothing opens the webcam again but the user (retry). A transient failure (the call
//   to the Windows camera service broke, the webcam gone in its first seconds) is tried again once by the tracking
//   itself after a short pause, on the same webcam only (head_tracking.dart), only while all of these still hold
//   (mayRetry is shouldRunCamera); a second failure in a row is the problem, and three new tries at most are made
//   until the next start.
// Whenever one stops holding, the webcam closes and its light goes off. While the head cannot be used ([usable] false:
// no tracker on this computer, no consent yet, said no, the webcam off in the settings, a problem), the view moves with
// the mouse instead, never an error page.
//
// The positions: the native tracker gives the eye midpoint filtered by the phones' One Euro filter, and its speed.
// Each sample becomes a position predicted one camera frame ahead (33 ms, ht_predict's rule of at most 40 ms), timed
// for that moment. x is the head's offset from the centre (set by the first face after the start or a recenter, as on
// the phones) in units of [headRange]: a head [headRange] of the frame's width to the side of the centre is the end of
// the range (x of 1), which at the view's default sensitivity is the phones' desktop gain of 3 (0.35 / 3, see
// spatial_viewpoint.dart of the photo lot). The tracker smooths: [followTime] is zero. No face for 300 ms: a lost
// position (confidence 0), and the view glides back to its centre.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position.dart';
import 'package:immich_mobile/desktop/window/session_presence.dart';
import 'package:logging/logging.dart';

final _log = Logger('HeadPositionSource');

/// See the top of this file
class HeadPositionSource extends ChangeNotifier with WidgetsBindingObserver implements ViewerPositionSource {
  HeadPositionSource({
    required DesktopSpatialSettingsStore store,
    SpatialHeadSource? source,
    ValueListenable<bool>? away,
    this._observeLifecycle = true,
    // The pause before the one new try of a transient failure, shorter in the tests
    Duration retryPause = const Duration(seconds: 2),
  }) : _store = store,
       _settings = store.read(),
       _away = away ?? DesktopSessionPresence.instance.away,
       _source = source {
    _tracking = SpatialHeadTracking(source: source, retryPause: retryPause)
      ..onSample = _onSample
      ..mayRetry = (() => shouldRunCamera);
    _tracking.addListener(_onTracking);
    _away.addListener(_update);
    if (_observeLifecycle) {
      WidgetsBinding.instance.addObserver(this);
    }
  }

  /// The source of the app: the tracker's library of this computer, the app's settings
  factory HeadPositionSource.app() =>
      HeadPositionSource(store: const AppSpatialSettingsStore(), source: NativeSpatialHeadSource.desktop());

  /// The head offset, as a fraction of the frame's width, that is the end of the range (x of 1)
  static const headRange = 0.35 / 3;

  /// How far ahead a position is predicted: one frame of a 30 fps webcam
  static const lookahead = Duration(microseconds: 33333);

  final DesktopSpatialSettingsStore _store;
  final SpatialHeadSource? _source;
  final ValueListenable<bool> _away;
  final bool _observeLifecycle;
  late final SpatialHeadTracking _tracking;
  DesktopSpatialSettings _settings;

  /// Writes of this source's choices not done yet
  int _saving = 0;
  final _positions = StreamController<ViewerPosition>.broadcast(sync: true);
  ViewerPosition? _latest;
  double? _centre;
  bool _recenter = true;
  bool _wasLost = false;
  bool _onScreen = false;
  bool _windowShown = true;
  bool _declined = false;
  bool _closed = false;

  @override
  ViewerPositionKind get kind => ViewerPositionKind.head;

  @override
  Stream<ViewerPosition> get positions => _positions.stream;

  @override
  ViewerPosition? get latest => _latest;

  /// The native tracker filters its positions
  @override
  Duration get followTime => Duration.zero;

  /// The head tracking behind (its state, its problem, the webcams listed)
  SpatialHeadTracking get tracking => _tracking;

  DesktopSpatialSettings get settings => _settings;

  /// This computer has a head tracker (its library loaded)
  bool get supported => _source != null;

  /// The head can move the view now or once the webcam opens: else the view uses the mouse
  bool get usable => supported && _settings.webcam && _settings.consent && _tracking.problem == null && !_declined;

  /// The card of the first time is due: the view shows this source, the webcam is allowed and the user never answered
  bool get needsConsent => _onScreen && supported && _settings.webcam && !_settings.consent && !_declined;

  /// The webcam is open now (its light on): the view shows the camera icon
  bool get cameraOpen => _tracking.cameraOpen;

  /// Why the head cannot be used, null when nothing is wrong
  SpatialTrackingProblem? get problem => _tracking.problem;

  bool get onScreen => _onScreen;

  /// The webcam may run: see the top of this file
  @visibleForTesting
  bool get shouldRunCamera => _onScreen && _windowShown && !_away.value && usable && !_closed;

  /// A view shows this source: the webcam may open. The settings are read again first: the settings page covers the
  /// view, so "Use the webcam for head tracking" or the webcam may have changed there meanwhile.
  void attach() {
    if (_onScreen || _closed) {
      return;
    }
    _onScreen = true;
    if (_saving == 0) {
      // While a choice of this source is being written, the one it holds is the newest
      _settings = _store.read();
    }
    _update();
    _notify();
  }

  /// No view shows it any more (closed, or covered by another page): the webcam closes
  void detach() {
    if (!_onScreen || _closed) {
      return;
    }
    _onScreen = false;
    _update();
    _notify();
  }

  /// "Use the webcam" on the card: remembered, then the webcam opens
  Future<void> acceptConsent() async {
    _declined = false;
    await _save(_settings.copyWith(consent: true, webcam: true));
    _update();
    _notify();
  }

  /// "Use the mouse" on the card: no webcam for this view; the card comes back on the next one
  void declineConsent() {
    _declined = true;
    _update();
    _notify();
  }

  /// The user asks for the webcam again after a problem (the button of its message)
  Future<void> retry() async {
    _declined = false;
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

  /// The webcam picked in the menu (null for the default one); an open webcam is changed at once, and one starting or
  /// waiting for its new try after a transient failure starts again with the new one
  Future<void> setCamera(String? cameraId) async {
    await _save(_settings.copyWith(cameraId: cameraId, clearCamera: cameraId == null));
    final state = _tracking.state;
    if (state == SpatialTrackingState.running || state == SpatialTrackingState.starting) {
      await _tracking.stop();
      _update();
    }
    _notify();
  }

  /// The settings changed elsewhere (the settings page): read again
  void reload() {
    _settings = _store.read();
    _update();
    _notify();
  }

  Future<void> _save(DesktopSpatialSettings settings) async {
    _settings = settings;
    _saving++;
    try {
      await _store.write(settings);
    } catch (error) {
      _log.warning('The Spatial 2.5D settings were not saved: $error');
    } finally {
      _saving--;
    }
  }

  /// The viewer's present position becomes the centre: the next face sets it, and the tracker takes the largest face
  @override
  void recenter() {
    _recenter = true;
    _tracking.recenter();
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _onScreen = false;
    _away.removeListener(_update);
    if (_observeLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _tracking.removeListener(_onTracking);
    _tracking.onSample = null;
    // The stop that releases the webcam begins here (the dispose after it finds nothing open), so that the close waits
    // for this release and not an older one
    final released = _tracking.stop();
    _tracking.dispose();
    await _positions.close();
    // The webcam's light off before the close is done
    await released;
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
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
    if (_closed) {
      return;
    }
    final run = shouldRunCamera;
    final state = _tracking.state;
    if (run && state == SpatialTrackingState.off) {
      // A new start: the first face sets the centre
      _recenter = true;
      unawaited(_tracking.start(cameraId: _settings.cameraId));
    } else if (!run && (state == SpatialTrackingState.running || state == SpatialTrackingState.starting)) {
      unawaited(_tracking.stop());
      _emitLost();
    }
  }

  void _onSample() {
    final sample = _tracking.latest;
    if (sample == null || _closed) {
      return;
    }
    if (sample.lost) {
      _emitLost();
      return;
    }
    final predicted = _tracking.predictedHead(aheadUs: lookahead.inMicroseconds);
    if (predicted == null) {
      // No face in this frame, the last one less than 300 ms ago: the view holds still
      return;
    }
    final head = sample.filteredX;
    if (_recenter || _centre == null) {
      _centre = head;
      _recenter = false;
    }
    _wasLost = false;
    final eyeY = sample.eyeY.isFinite ? sample.eyeY : 0.5;
    _emit(
      ViewerPosition(
        x: (predicted.x - _centre!) / headRange,
        y: (eyeY - 0.5) * 2,
        timestamp: Duration(microseconds: predicted.timeUs),
        confidence: sample.confidence.clamp(0.01, 1.0),
      ),
    );
  }

  void _emitLost() {
    if (_wasLost || _latest == null || _closed) {
      return;
    }
    _wasLost = true;
    _emit(ViewerPosition.lost(_latest!.timestamp + const Duration(microseconds: 1)));
  }

  void _emit(ViewerPosition position) {
    _latest = position;
    if (!_positions.isClosed) {
      _positions.add(position);
    }
  }

  void _onTracking() {
    if (_tracking.state == SpatialTrackingState.starting && !_tracking.cameraOpen) {
      // The webcam closed for a new try (or another one): the view glides back meanwhile rather than hold still
      _emitLost();
    }
    _notify();
  }

  void _notify() {
    if (!_closed) {
      notifyListeners();
    }
  }
}
