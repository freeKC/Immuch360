// The head tracking of the Spatial page of the computers: the webcam session of packages/immuch_head_tracker, the
// phones' filter and viewpoint on its samples, and what the page shows about it (the face lost, the webcam refused,
// busy, gone, the Media Feature Pack missing, automatic framing that could not be turned off).
//
// The page decides when the webcam runs, by the rules of the lot: only while the Spatial page shows with head tracking
// chosen, closed when the page closes, when the window is minimised and when tracking is turned off; an error never
// starts it again by itself (the user turns tracking on again, or comes back from the camera settings). The pictures
// never reach Dart: only the position of the face comes out of the native code, one sample per analysed frame.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';
import 'package:logging/logging.dart';

final _log = Logger('SpatialHeadTracking');

/// Lists the webcams and opens one: the tracker's DLL in the app, fakes in the tests
abstract class SpatialHeadSource {
  /// The video cameras, without opening any. Throws [HeadTrackerException] (noMediaFoundation).
  Future<List<HeadCamera>> cameras();

  /// Starts tracking with [camera]; an error to open it comes on the session's samples
  HeadTrackingSession start(HeadCamera camera);
}

/// [SpatialHeadSource] over immuch_head_tracker.dll
class NativeSpatialHeadSource implements SpatialHeadSource {
  NativeSpatialHeadSource(this._tracker);

  final HeadTracker _tracker;

  /// The tracker of the app's DLL on Windows; null elsewhere, or when the DLL does not load
  static SpatialHeadSource? windows() {
    try {
      final tracker = HeadTracker.windows();
      return tracker == null ? null : NativeSpatialHeadSource(tracker);
    } catch (error) {
      _log.warning('The head tracker did not load: $error');
      return null;
    }
  }

  @override
  Future<List<HeadCamera>> cameras() => _tracker.cameras();

  @override
  HeadTrackingSession start(HeadCamera camera) => _tracker.start(camera);
}

/// What keeps head tracking from running, as the page says it
enum SpatialTrackingProblem {
  /// Camera access is turned off for desktop apps: the privacy message, with the button of the camera settings
  cameraOff,

  /// A Windows N edition without the Media Feature Pack
  mediaFeaturePack,

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
  HeadTrackingSession? _session;
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

  /// The webcams listed when tracking started first, null before
  List<HeadCamera>? get cameras => _cameras;

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
    final chosen = cameras.where((camera) => camera.id == cameraId).firstOrNull ?? defaultHeadCamera(cameras);
    if (chosen == null) {
      _fail(SpatialTrackingProblem.noCamera, 'no webcam: ${cameras.length} camera(s), infrared only');
      return;
    }
    _camera = chosen;
    final HeadTrackingSession session;
    try {
      session = source.start(chosen);
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
      await session.close();
    }
  }

  /// The next face sets the centre
  void recenter() => _viewpoint.recenter();

  /// The viewpoint now, from the head: null when the webcam does not run
  double? viewpointNow() {
    final session = _session;
    if (session == null || _state != SpatialTrackingState.running) {
      return null;
    }
    return _viewpoint.valueAt(session.nowNanos());
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
    _viewpoint.onSample(sample, _filter.add(sample));
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
    final problem = error is HeadTrackerException ? spatialProblemOf(error.error) : SpatialTrackingProblem.failed;
    _fail(problem, 'the webcam stopped: $error');
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
