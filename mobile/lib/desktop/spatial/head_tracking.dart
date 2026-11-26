// The head tracking of the Spatial 2.5D views of the computers: the webcam session of packages/immuch_head_tracker
// (Windows, Linux and macOS), the phones' filter (run by the native tracker on the eye midpoint, with the head's speed
// for a short prediction) and viewpoint on its samples, and what the page shows about it (the face lost, the webcam
// refused, busy, gone, the Media Feature Pack missing, automatic framing or Center Stage that could not be turned off).
//
// The page decides when the webcam runs, by the rules of the lot: only while the Spatial page shows with head tracking
// chosen, closed when the page closes, when the window is minimised and when tracking is turned off; an error never
// starts it again by itself (the user turns tracking on again, or comes back from the camera settings). The pictures
// never reach Dart: only the position of the face comes out of the native code, one sample per analysed frame.
//
// A start waits for the release of the previous webcam session (its capture thread ends in a background isolate), so
// that a quick minimise and restore, the mouse then the head again, or a page closed and opened again at once, never
// finds the webcam still held by this app (which the page would call busy). That wait is shared by every
// SpatialHeadTracking of the app. A webcam taken by default is opened as colour only: one whose formats are all grey
// (an infrared camera with a plain name) is refused before it streams, marked infrared, and the next one is taken.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';
import 'package:logging/logging.dart';

final _log = Logger('SpatialHeadTracking');

/// Lists the webcams and opens one: the tracker's DLL in the app, fakes in the tests
abstract class SpatialHeadSource {
  /// The video cameras, without opening any. Throws [HeadTrackerException] (noMediaFoundation).
  Future<List<HeadCamera>> cameras();

  /// Starts tracking with [camera]; an error to open it comes on the session's samples. [colourOnly]: a camera taken by
  /// default, refused when its formats are all grey (HeadTrackerError.greyOnly)
  HeadTrackingSession start(HeadCamera camera, {bool colourOnly = false});
}

/// [SpatialHeadSource] over the tracker's library of the app
class NativeSpatialHeadSource implements SpatialHeadSource {
  NativeSpatialHeadSource(this._tracker);

  final HeadTracker _tracker;

  /// The tracker of the app's library on the computers; null elsewhere, or when the library does not load
  static SpatialHeadSource? desktop() {
    try {
      final tracker = HeadTracker.desktop();
      return tracker == null ? null : NativeSpatialHeadSource(tracker);
    } catch (error) {
      _log.warning('The head tracker did not load: $error');
      return null;
    }
  }

  @override
  Future<List<HeadCamera>> cameras() => _tracker.cameras();

  @override
  HeadTrackingSession start(HeadCamera camera, {bool colourOnly = false}) =>
      _tracker.start(camera, options: HeadTrackerOptions(colourOnly: colourOnly));
}

/// What keeps head tracking from running, as the page says it
enum SpatialTrackingProblem {
  /// The system refused the webcam: the privacy message, with the button of the camera settings where there is one
  cameraOff,

  /// A Windows N edition without the Media Feature Pack
  mediaFeaturePack,

  /// A webcam that offers compressed pictures only (MJPEG on Linux), which the tracker does not decode
  unsupportedFormat,

  /// No webcam (or infrared cameras only, which are never taken by themselves)
  noCamera,

  /// Another app holds the webcam
  cameraBusy,

  /// The webcam went away while it streamed
  cameraLost,

  /// Anything else: the tracker's DLLs missing, a format it cannot read
  failed,
}

/// The problem of a tracker error
SpatialTrackingProblem spatialProblemOf(HeadTrackerError error) => switch (error) {
  HeadTrackerError.accessDenied => SpatialTrackingProblem.cameraOff,
  HeadTrackerError.noMediaFoundation => SpatialTrackingProblem.mediaFeaturePack,
  HeadTrackerError.noCamera => SpatialTrackingProblem.noCamera,
  HeadTrackerError.cameraBusy => SpatialTrackingProblem.cameraBusy,
  HeadTrackerError.deviceLost => SpatialTrackingProblem.cameraLost,
  // Only a camera the user picked reaches the page this way, and it is opened without the check: never shown
  HeadTrackerError.greyOnly => SpatialTrackingProblem.noCamera,
  HeadTrackerError.format => SpatialTrackingProblem.unsupportedFormat,
  _ => SpatialTrackingProblem.failed,
};

/// Where head tracking is
enum SpatialTrackingState {
  /// No webcam open
  off,

  /// The webcams are being listed, or the chosen one opens
  starting,

  /// The webcam runs and gives samples
  running,

  /// It stopped on a problem ([SpatialHeadTracking.problem])
  failed,
}

/// The head tracking of one Spatial page, see the top of this file
class SpatialHeadTracking extends ChangeNotifier {
  SpatialHeadTracking({
    required this._source,
    double sensitivity = HeadViewpoint.desktopSensitivity,
    this.manualAfterLost = const Duration(seconds: 3),
    this.framingCheckInterval = const Duration(milliseconds: 500),
  }) {
    _viewpoint.sensitivity = sensitivity;
  }

  final SpatialHeadSource? _source;

  /// The face lost for this long, the page shows the manual slider (the phones' MANUAL_AFTER_LOST_MS)
  final Duration manualAfterLost;

  /// Called at each sample, after the viewpoint took it: the page asks for a frame to draw the new viewpoint. The
  /// listeners hear the changes of state only, not each sample.
  VoidCallback? onSample;

  /// How often automatic framing is read until the camera answers for it
  final Duration framingCheckInterval;

  final _filter = HeadXFilter();
  final _viewpoint = HeadViewpoint();

  List<HeadCamera>? _cameras;
  HeadCamera? _camera;

  /// The webcam in use was taken by default (not chosen): a grey only refusal moves on to the next one
  bool _cameraByDefault = false;

  /// The cameras refused as grey only, by id: marked infrared in the list, never taken by default again
  final _greyOnly = <String>{};
  HeadTrackingSession? _session;

  /// The release of the sessions closed last, until it is done: a start or a listing waits for it. Shared by every
  /// head tracking of the app, since they share the webcam: a page reopened at once, or a view that swaps its source,
  /// has a new one, and its start must wait for the release of the old one as well.
  static Future<void>? _closing;
  bool _reversed = false;
  StreamSubscription<HeadSample>? _subscription;
  SpatialTrackingState _state = SpatialTrackingState.off;
  SpatialTrackingProblem? _problem;
  HeadSample? _latest;
  bool _faceLost = false;
  bool _lostTooLong = false;
  Timer? _lostTimer;
  AutoFramingState _framing = AutoFramingState.unknown;
  int _lastFramingCheckUs = -1;
  int _generation = 0;
  bool _disposed = false;

  /// The webcams listed when tracking started first, null before; a camera found grey only is marked infrared
  List<HeadCamera>? get cameras {
    final cameras = _cameras;
    if (cameras == null || _greyOnly.isEmpty) {
      return cameras;
    }
    return List.unmodifiable([
      for (final camera in cameras) _greyOnly.contains(camera.id) ? camera.asGreyOnly() : camera,
    ]);
  }

  /// Done once every webcam session closed so far, by any head tracking of the app, has released its camera (its light
  /// off)
  Future<void> get released => _closing ?? Future<void>.value();

  /// The head's direction reversed, for a webcam whose own software mirrors its pictures: a head moving to the user's
  /// right then shows on the right of the frame. The next face sets the centre again.
  bool get reversed => _reversed;

  set reversed(bool value) {
    if (value == _reversed) {
      return;
    }
    _reversed = value;
    _viewpoint.recenter();
    _filter.reset();
    notifyListeners();
  }

  /// The webcam in use or last used
  HeadCamera? get camera => _camera;

  SpatialTrackingState get state => _state;

  /// Why tracking stopped or could not start, null while it runs or when it was turned off
  SpatialTrackingProblem? get problem => _problem;

  /// Whether the webcam is open now (its light on)
  bool get cameraOpen => _session != null;

  /// The newest sample
  HeadSample? get latest => _latest;

  /// No face for 300 ms or more: the viewpoint eases back to the middle
  bool get faceLost => _faceLost;

  /// No face for [manualAfterLost]: the page offers the slider
  bool get lostTooLong => _lostTooLong;

  /// Windows Studio Effects automatic framing, as the tracker found it on the camera
  AutoFramingState get framing => _framing;

  /// What the tracker runs with (detector build, camera format), null without a session
  HeadTrackerInfo? info() {
    final session = _session;
    if (session == null) {
      return null;
    }
    try {
      return session.info();
    } catch (error) {
      return null;
    }
  }

  double get sensitivity => _viewpoint.sensitivity;

  set sensitivity(double value) {
    final clamped = value.clamp(HeadViewpoint.minSensitivity, HeadViewpoint.maxSensitivity);
    if (clamped == _viewpoint.sensitivity) {
      return;
    }
    _viewpoint.sensitivity = clamped;
    notifyListeners();
  }

  /// Opens the webcam: [cameraId] when it is listed, else the default one (never an infrared camera). Returns once the
  /// webcam is asked to open; whatever keeps it from running ends in [problem]. Nothing happens while it runs or
  /// starts.
  Future<void> start({String? cameraId}) async {
    if (_disposed || _state == SpatialTrackingState.running || _state == SpatialTrackingState.starting) {
      return;
    }
    final generation = ++_generation;
    _problem = null;
    _setState(SpatialTrackingState.starting);
    final source = _source;
    if (source == null) {
      _fail(SpatialTrackingProblem.failed, 'no head tracker on this computer');
      return;
    }
    // The previous session's capture thread may still hold the webcam: opened again before it let go, the webcam
    // would answer that it is busy
    await _waitForRelease();
    if (generation != _generation || _disposed) {
      return;
    }
    List<HeadCamera> cameras;
    try {
      // Listed again at each start: a webcam plugged in or taken out since the last one counts
      cameras = await source.cameras();
    } on HeadTrackerException catch (error) {
      if (generation == _generation) {
        _fail(spatialProblemOf(error.error), 'the webcams could not be listed: $error');
      }
      return;
    } catch (error) {
      if (generation == _generation) {
        _fail(SpatialTrackingProblem.failed, 'the webcams could not be listed: $error');
      }
      return;
    }
    if (generation != _generation || _disposed) {
      // Stopped while the webcams were listed
      return;
    }
    _cameras = List.unmodifiable(cameras);
    final picked = cameras.where((camera) => camera.id == cameraId).firstOrNull;
    final chosen = picked ?? defaultHeadCamera(this.cameras!, except: _greyOnly);
    if (chosen == null) {
      _fail(SpatialTrackingProblem.noCamera, 'no webcam: ${cameras.length} camera(s), infrared only');
      return;
    }
    _camera = chosen;
    _cameraByDefault = picked == null;
    final HeadTrackingSession session;
    try {
      session = source.start(chosen, colourOnly: _cameraByDefault);
    } on HeadTrackerException catch (error) {
      _fail(spatialProblemOf(error.error), 'the webcam did not start: $error');
      return;
    } catch (error) {
      _fail(SpatialTrackingProblem.failed, 'the webcam did not start: $error');
      return;
    }
    _session = session;
    _latest = null;
    _faceLost = false;
    _lostTooLong = false;
    _framing = AutoFramingState.unknown;
    _lastFramingCheckUs = -1;
    _filter.reset();
    // The first face after the start sets the centre
    _viewpoint.recenter();
    _subscription = session.samples.listen(
      (sample) => _onSample(session, sample),
      onError: (Object error) => _onError(session, error),
    );
    _log.info('Head tracking with $chosen');
    _setState(SpatialTrackingState.running);
  }

  /// Lists the webcams for the menu without opening any (in a background isolate); keeps the previous list on an error
  Future<void> refreshCameras() async {
    final source = _source;
    if (source == null || _disposed) {
      return;
    }
    await _waitForRelease();
    if (_disposed) {
      return;
    }
    try {
      final cameras = await source.cameras();
      if (!_disposed) {
        _cameras = List.unmodifiable(cameras);
        _notify();
      }
    } catch (error) {
      _log.info('The webcams were not listed for the menu: $error');
    }
  }

  /// Closes the webcam (its light goes off once this returns). [keepProblem]: the message of a problem stays.
  Future<void> stop({bool keepProblem = false}) async {
    _generation++;
    final session = _session;
    _session = null;
    _lostTimer?.cancel();
    _faceLost = false;
    _lostTooLong = false;
    if (!keepProblem) {
      _problem = null;
    }
    // Cancelled without waiting: a broadcast subscription stops at once, and the webcam need not wait for it
    unawaited(_subscription?.cancel());
    _subscription = null;
    _setState(_problem != null ? SpatialTrackingState.failed : SpatialTrackingState.off);
    if (session != null) {
      _log.info('Webcam closed');
      final previous = _closing;
      final closing = _release(previous, session);
      _closing = closing;
      await closing;
      if (identical(_closing, closing)) {
        _closing = null;
      }
    }
  }

  /// [session] released after [previous], whatever either answers
  static Future<void> _release(Future<void>? previous, HeadTrackingSession session) async {
    try {
      await previous;
    } catch (_) {
      // Logged by its own stop
    }
    try {
      await session.close();
    } catch (error) {
      _log.warning('The webcam session did not close cleanly: $error');
    }
  }

  Future<void> _waitForRelease() async {
    final closing = _closing;
    if (closing != null) {
      await closing;
    }
  }

  /// The next face sets the centre, and the tracker takes the largest face again
  void recenter() {
    _viewpoint.recenter();
    _session?.recenter();
  }

  /// The viewpoint now, from the head moved on a little by its speed (at most 40 ms): null when the webcam does not run
  double? viewpointNow() {
    final session = _session;
    if (session == null || _state != SpatialTrackingState.running) {
      return null;
    }
    final now = session.nowNanos();
    final latest = _latest;
    double? predicted;
    if (latest != null && latest.filteredX.isFinite) {
      final x = session.predictedX();
      predicted = x == null || !_reversed ? x : -x;
    }
    return _viewpoint.predictedAt(now, predicted);
  }

  /// The head position (headX, the phones' convention, never reversed) [aheadUs] after now, moved on by the head's
  /// speed for at most 40 ms (ht_predict's rule), and the time it is for in the clock of the samples; null without a
  /// face or without the tracker's filter
  ({double x, int timeUs})? predictedHead({int aheadUs = 0}) {
    final session = _session;
    final latest = _latest;
    if (session == null || latest == null || !latest.hasFace || !latest.filteredX.isFinite) {
      return null;
    }
    final at = session.nowUs() + aheadUs;
    final x = latest.predictedAt(at);
    return x == null ? null : (x: x, timeUs: at);
  }

  /// Whether the viewpoint eases by itself now (a face lost or found again)
  bool isAnimating() {
    final session = _session;
    return session != null && _viewpoint.isAnimating(session.nowNanos());
  }

  void _onSample(HeadTrackingSession session, HeadSample sample) {
    if (!identical(session, _session) || _disposed) {
      return;
    }
    _latest = sample;
    // The tracker's own filter on the eye midpoint when it gave one (the same One Euro filter, checked against the
    // phones' values), the Dart copy otherwise
    final filtered = sample.filteredX.isFinite ? (sample.hasFace ? sample.filteredX : null) : _filter.add(sample);
    // Reversed: the mirror image of the head's position about the middle of the frame
    _viewpoint.onSample(sample, filtered == null || !_reversed ? filtered : -filtered);
    _checkFraming(session, sample);
    onSample?.call();
    if (sample.lost != _faceLost) {
      _faceLost = sample.lost;
      _lostTimer?.cancel();
      if (_faceLost) {
        _lostTimer = Timer(manualAfterLost, () {
          if (_faceLost && identical(session, _session)) {
            _lostTooLong = true;
            _notify();
          }
        });
      } else {
        _lostTooLong = false;
      }
      _notify();
    }
  }

  /// Automatic framing answers once the camera streams: read on the samples until it is known
  void _checkFraming(HeadTrackingSession session, HeadSample sample) {
    if (_framing != AutoFramingState.unknown) {
      return;
    }
    if (_lastFramingCheckUs >= 0 && sample.timeUs - _lastFramingCheckUs < framingCheckInterval.inMicroseconds) {
      return;
    }
    _lastFramingCheckUs = sample.timeUs;
    try {
      final framing = session.info().framing;
      if (framing != AutoFramingState.unknown) {
        _framing = framing;
        _log.info('Automatic framing: ${framing.name}');
        if (framing == AutoFramingState.stuckOn) {
          _notify();
        }
      }
    } catch (error) {
      _framing = AutoFramingState.absent;
      _log.fine('Automatic framing not read: $error');
    }
  }

  void _onError(HeadTrackingSession session, Object error) {
    if (!identical(session, _session) || _disposed) {
      return;
    }
    final camera = _camera;
    if (error is HeadTrackerException &&
        error.error == HeadTrackerError.greyOnly &&
        camera != null &&
        _cameraByDefault) {
      // An infrared camera under a plain name, refused before it streamed: marked, and the next camera taken
      _log.info('$camera gives grey pictures only: not taken by default');
      _greyOnly.add(camera.id);
      unawaited(_startNext());
      return;
    }
    final problem = error is HeadTrackerException ? spatialProblemOf(error.error) : SpatialTrackingProblem.failed;
    _fail(problem, 'the webcam stopped: $error');
  }

  Future<void> _startNext() async {
    await stop();
    if (!_disposed) {
      await start();
    }
  }

  /// [problem] stops tracking; the webcam is released, and nothing starts it again but the user
  void _fail(SpatialTrackingProblem problem, String why) {
    _log.warning('Head tracking: $why');
    _problem = problem;
    unawaited(stop(keepProblem: true));
  }

  void _setState(SpatialTrackingState state) {
    if (state == _state) {
      return;
    }
    _state = state;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    // Marked first: the page that listens is going away, nothing is told any more
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
