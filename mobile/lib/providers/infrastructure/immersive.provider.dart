import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/immersive_navigation.service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:logging/logging.dart';

final _log = Logger('ImmersiveViewer');

final immersiveApiProvider = Provider<ImmersiveApi>((_) => ImmersiveApi());

/// True on a Meta Quest headset (Horizon OS), where 360 media open in the immersive viewer.
/// Asked once to the platform, false on iOS and when the question fails.
final isHorizonOsProvider = FutureProvider<bool>((ref) async {
  if (!CurrentPlatform.isAndroid) {
    return false;
  }
  try {
    return await ref.read(immersiveApiProvider).isHorizonOs();
  } catch (error) {
    _log.warning('Could not detect Horizon OS: $error');
    return false;
  }
});

/// A request of the immersive viewer for the media [step] places away from the one it shows (see
/// [ImmersiveEvents.requestAdjacent]), which a navigator answers (see [ImmersiveNavigator.showAdjacent]).
///
/// The session cancels it once the viewer closed, asked again, or opened on another media from the app, and once its
/// deadline passed (see [immersiveSearchDeadline]): the viewer no longer waits for it then, so a search checks
/// [isCancelled] between its steps and shows nothing once it is.
class ImmersiveAdjacentRequest {
  ImmersiveAdjacentRequest({required this.id, required this.step, required this.stereoLayout, required this.coverage});

  /// The id the viewer gave the request, which [show] hands back to it
  final int id;

  /// +1 next, -1 previous: only its sign counts
  final int step;

  /// What the viewer shows now, with the corrections of the user, to remember before moving on
  final ImmersiveStereoLayout stereoLayout;
  final ImmersiveSphereCoverage coverage;

  bool _cancelled = false;
  Future<bool>? _shown;

  /// Whether the viewer no longer waits for this request
  bool get isCancelled => _cancelled;

  /// The viewer no longer waits for this request: the search stops, showing nothing
  void cancel() => _cancelled = true;

  /// Shows the media found with [showAdjacent] (ImmersiveApi.showAdjacent, given [id]), and returns whether the viewer
  /// shows it; false without asking once the request is cancelled. The answer of the request then waits for this one
  /// whatever its deadline, since the viewer may show the media already.
  Future<bool> show(Future<bool> Function(int requestId) showAdjacent) {
    if (_cancelled) {
      return Future.value(false);
    }
    return _shown = showAdjacent(id);
  }
}

/// Previous and next in the immersive viewer, from the media it opened on, and what the app does once it closes: one
/// per opening of the viewer, held by [ImmersiveSession] meanwhile.
///
/// The viewer asks minutes after the widget that opened it, which may be gone by then: a navigator holds everything
/// it needs from the moment the viewer opened, never a WidgetRef.
abstract interface class ImmersiveNavigator {
  /// Answers [request]: keeps what the user corrected on the media shown, looks for the nearest media the viewer can
  /// show in the direction asked, and shows it in place with [ImmersiveAdjacentRequest.show]. Returns whether the
  /// viewer shows it; false leaves the viewer as it is, and is also the answer once the request is cancelled.
  Future<bool> showAdjacent(ImmersiveAdjacentRequest request);

  /// The viewer closed on the media at [url], the one it showed last, with [stereoLayout] and [coverage] (the user may
  /// have corrected them there), a video at [positionMs] (0 for a photo)
  void onClosed(String url, ImmersiveStereoLayout stereoLayout, ImmersiveSphereCoverage coverage, int positionMs);
}

/// Takes the events of the immersive viewer (see [ImmersiveEvents]) and hands them to the navigator of the media it
/// opened on (see [ImmersiveNavigator]), which [start] tells right before the viewer opens. One viewer at most is open
/// at a time, and one request for another media at most is answered at a time.
///
/// Each opening gets its own id, which the viewer sends back with every event: the session answers only the opening
/// it follows, the last one started. An event of an earlier opening (a closing that comes long after the user left
/// through the system, or a request of a viewer since opened on another media from the app) would otherwise move the
/// asset viewer, or search the timeline, for a viewer that is gone.
class ImmersiveSession implements ImmersiveEvents {
  ImmersiveSession({this.searchDeadline = immersiveSearchDeadline});

  /// Longest a request for another media is answered in, see [immersiveSearchDeadline]
  final Duration searchDeadline;

  // The id of the last opening started: the next one gets the following id, so that no two openings share one. Seeded
  // from the clock because the viewer activity can outlive the app engine that opened it (the engine is recreated
  // with the activity of the app window, the viewer is its own activity): a counter starting at zero in every engine
  // would hand out again an id a stale viewer still reports with
  var _lastOpeningId = DateTime.now().microsecondsSinceEpoch;

  // The opening followed, with its navigator (null for a media with no previous or next); null once it closed or could
  // not open
  ({int id, ImmersiveNavigator? navigator})? _opening;

  // The request being answered, cancelled by the next one
  ImmersiveAdjacentRequest? _request;

  /// Whether a viewer is open, as far as this session knows
  bool get isOpen => _opening != null;

  /// Whether the session follows the opening [openingId]: it no longer does once that viewer closed, or once another
  /// opening started
  bool isCurrent(int openingId) => _opening?.id == openingId;

  /// The viewer opens on a media whose previous, next and closing [navigator] takes care of; null for a media with
  /// no previous or next, which still replaces whatever the session followed before. Returns the id of this opening,
  /// for ImmersiveApi.open: the events of any opening before it are ignored from now on.
  int start(ImmersiveNavigator? navigator) {
    _cancelRequest();
    final id = ++_lastOpeningId;
    _opening = (id: id, navigator: navigator);
    return id;
  }

  /// The viewer could not open for [openingId]: nothing will close
  void cancel(int openingId) {
    if (isCurrent(openingId)) {
      _cancelRequest();
      _opening = null;
    }
  }

  /// The session takes no more events: a search still running stops, showing nothing, and the events of the viewer
  /// no longer reach it
  void dispose() {
    _cancelRequest();
    _opening = null;
    ImmersiveEvents.setUp(null);
  }

  void _cancelRequest() {
    _request?.cancel();
    _request = null;
  }

  @override
  Future<bool> requestAdjacent(
    int openingId,
    int requestId,
    int step,
    ImmersiveStereoLayout stereoLayout,
    ImmersiveSphereCoverage coverage,
  ) async {
    if (!isCurrent(openingId)) {
      // A viewer the session no longer follows: its search would go through the list of the opening followed now, and
      // would cancel the request of that opening
      _log.info('The immersive viewer of opening $openingId asked for another media, but it is no longer followed');
      return false;
    }
    final navigator = _opening?.navigator;
    if (navigator == null) {
      _log.info('The immersive viewer asked for another media, but nothing was opened with a list around it');
      return false;
    }
    // Asking again means the viewer gave up on the previous request: that search stops and answers false, and this
    // one starts right away rather than after it, a search being slow to notice while it waits for a read
    _cancelRequest();
    final request = ImmersiveAdjacentRequest(id: requestId, step: step, stereoLayout: stereoLayout, coverage: coverage);
    _request = request;
    // The viewer waits for so long at most: the search stops at its next step past the deadline, and the answer does
    // not wait for a step that hangs (a read of the network or of the database)
    final deadline = Timer(searchDeadline, request.cancel);
    try {
      return await navigator
          .showAdjacent(request)
          .timeout(
            searchDeadline,
            onTimeout: () {
              request.cancel();
              _log.info('No media found $step places away within $searchDeadline');
              return request._shown ?? Future.value(false);
            },
          );
    } catch (error, stackTrace) {
      _log.warning('Could not show the media $step places away', error, stackTrace);
      return false;
    } finally {
      deadline.cancel();
      if (identical(_request, request)) {
        _request = null;
      }
    }
  }

  @override
  void closed(
    int openingId,
    String url,
    ImmersiveStereoLayout stereoLayout,
    ImmersiveSphereCoverage coverage,
    int positionMs,
  ) {
    if (!isCurrent(openingId)) {
      // A viewer gone already: its closing would move the asset viewer, or the player, away from what the opening
      // followed now shows, and the session would stop following that opening
      _log.fine('The immersive viewer of opening $openingId closed, but it is no longer followed');
      return;
    }
    final navigator = _opening?.navigator;
    _opening = null;
    // A search still running for this viewer stops, showing nothing
    _cancelRequest();
    if (navigator == null) {
      _log.fine('The immersive viewer closed on a media opened without a navigator');
      return;
    }
    try {
      navigator.onClosed(url, stereoLayout, coverage, positionMs);
    } catch (error, stackTrace) {
      _log.warning('Could not follow the closing of the immersive viewer', error, stackTrace);
    }
  }
}

/// The session of the immersive viewer. Reading it the first time registers it as the [ImmersiveEvents] handler on
/// the engine of the app window, which the openers do before the viewer opens, like for the native 360° player.
final immersiveSessionProvider = Provider<ImmersiveSession>((ref) {
  final session = ImmersiveSession();
  ImmersiveEvents.setUp(session);
  ref.onDispose(session.dispose);
  return session;
});
