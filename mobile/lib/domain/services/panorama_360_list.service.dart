import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/panorama_360.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/panorama_360_list.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/repositories/panorama_360.repository.dart';
import 'package:logging/logging.dart';

final _log = Logger('Panorama360List');

typedef Panorama360TraitsReader = Set<Panorama360Trait> Function(Panorama360Entry entry);

typedef _Sources = ({String? userId, Set<String> forcedKeys, Set<String> deviceIds});

/// The list of the 360° page of the Library, one per page: it reads the candidates from the database when they may
/// have changed (see [setSources], and the changes of the tables), and shows them through the filter of the bar
/// (see [setView]), from memory. The page builds its TimelineService once on [timelineQuery], and the asset viewer
/// holds that service: a new filter only gives a new view, never a new service.
class Panorama360ListService {
  Panorama360ListService({
    required this._repository,
    required this._groupBy,
    this.reloadDelay = const Duration(milliseconds: 300),
  }) {
    _changes = _repository.watchChanges().listen((_) => _scheduleReload());
  }

  final Panorama360Repository _repository;
  final GroupAssetsBy _groupBy;

  /// Wait after a change of the database or of the ids before reading the candidates again: a sync writes in bursts
  final Duration reloadDelay;

  late final StreamSubscription<void> _changes;
  final _controller = StreamController<Panorama360View>.broadcast();
  Timer? _reloadTimer;
  bool _loading = false;
  bool _reloadAgain = false;
  bool _disposed = false;

  _Sources? _sources;
  Panorama360Filter? _filter;
  Panorama360TraitsReader? _traitsOf;

  // What the latest read gave, and whether a server was connected for it; null before the first read ended
  List<Panorama360Entry>? _candidates;
  bool _candidatesHaveServer = false;
  Panorama360View? _latest;

  /// What to read: [userId] null without a server; [forcedKeys] the keys of ForcedPanoramaAssets; [deviceIds] the ids
  /// on the device the scan found 360°. Reads again when any of them changed (the first call reads at once).
  void setSources({String? userId, required Set<String> forcedKeys, required Set<String> deviceIds}) {
    if (_disposed) {
      return;
    }
    final previous = _sources;
    _sources = (userId: userId, forcedKeys: Set.unmodifiable(forcedKeys), deviceIds: Set.unmodifiable(deviceIds));
    if (previous == null) {
      _scheduleReload(now: true);
    } else if (previous.userId != userId ||
        !setEquals(previous.forcedKeys, forcedKeys) ||
        !setEquals(previous.deviceIds, deviceIds)) {
      _scheduleReload();
    }
  }

  /// How to show it: recomputes the view from the candidates in memory, without reading the database. Emits only
  /// when the entries (hero tags, in order) or the facets changed.
  void setView({required Panorama360Filter filter, required Panorama360TraitsReader traitsOf}) {
    if (_disposed) {
      return;
    }
    _filter = filter;
    _traitsOf = traitsOf;
    _emit();
  }

  /// The latest view, replayed to each new listener
  Stream<Panorama360View> get views => Stream.multi((controller) {
    final last = _latest;
    if (last != null) {
      controller.add(last);
    }
    if (_disposed) {
      unawaited(controller.close());
      return;
    }
    final subscription = _controller.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    // Not waited for: the end of the list reaches its listeners at once, whatever the cancel of a subscription that
    // already saw that end waits for
    controller.onCancel = () => unawaited(subscription.cancel());
  });

  Panorama360View? get latest => _latest;

  /// For TimelineService: buckets of each view, and the entries of the latest view, page by page
  TimelineQuery get timelineQuery => (
    bucketSource: () => views.map((view) => view.buckets),
    assetSource: (offset, count) async =>
        (latest?.entries ?? const []).skip(offset).take(count).map((entry) => entry.asset).toList(growable: false),
    origin: TimelineOrigin.panorama360,
  );

  void _scheduleReload({bool now = false}) {
    if (_disposed || _sources == null) {
      return;
    }
    _reloadTimer?.cancel();
    _reloadTimer = Timer(now ? Duration.zero : reloadDelay, () => unawaited(_reload()));
  }

  Future<void> _reload() async {
    if (_loading) {
      _reloadAgain = true;
      return;
    }
    _loading = true;
    try {
      do {
        _reloadAgain = false;
        final sources = _sources;
        if (sources == null) {
          return;
        }
        final userId = sources.userId;
        // A device file the user forced counts as found: its server copy is listed through its checksum too
        final deviceIds = sources.deviceIds.union(sources.forcedKeys);
        try {
          final remote = userId == null
              ? const <Panorama360Entry>[]
              : await _repository.loadRemote(userId: userId, forcedKeys: sources.forcedKeys, deviceIds: deviceIds);
          final device = await _repository.loadDevice(ids: deviceIds, userId: userId);
          if (_disposed) {
            return;
          }
          _candidates = mergePanorama360Candidates([...remote, ...device]);
          _candidatesHaveServer = userId != null;
          // An asset may have changed under the same hero tag (a favourite): always shown again after a read
          _emit(force: true);
        } catch (error, stackTrace) {
          _log.warning('Could not read the 360° photos and videos', error, stackTrace);
          if (_candidates == null && !_disposed) {
            // The page shows an empty list rather than waiting for ever; the next change reads again
            _candidates = const [];
            _candidatesHaveServer = userId != null;
            _emit(force: true);
          }
        }
      } while (_reloadAgain && !_disposed);
    } finally {
      _loading = false;
    }
  }

  void _emit({bool force = false}) {
    final candidates = _candidates;
    final filter = _filter;
    final traitsOf = _traitsOf;
    if (_disposed || candidates == null || filter == null || traitsOf == null) {
      return;
    }
    final view = buildPanorama360View(
      candidates,
      filter,
      hasServer: _candidatesHaveServer,
      traitsOf: traitsOf,
      groupBy: _groupBy,
    );
    final previous = _latest;
    // A scan saving its progress must not reload the buffer of the timeline for nothing
    if (!force && previous != null && _sameView(previous, view)) {
      return;
    }
    _latest = view;
    _controller.add(view);
  }

  static bool _sameView(Panorama360View a, Panorama360View b) =>
      a.facets == b.facets &&
      const ListEquality<String>().equals(
        a.entries.map((entry) => entry.asset.heroTag).toList(growable: false),
        b.entries.map((entry) => entry.asset.heroTag).toList(growable: false),
      );

  Future<void> dispose() async {
    _disposed = true;
    _reloadTimer?.cancel();
    _reloadTimer = null;
    // Both at once: the listeners hear of the end without waiting for the database to let go
    await Future.wait([_changes.cancel(), _controller.close()]);
  }
}
