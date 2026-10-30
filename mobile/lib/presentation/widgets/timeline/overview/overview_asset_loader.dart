// The thumbnails of the months and the years come from all over the library at once: a few assets at the start of each
// month on screen. They are read here rather than through the buffer of the grid (TimelineService.loadAssets), which
// keeps a single window of 1024 assets and would load a new one for each block.
//
// The requests made in one frame wait for the end of it, then go out the most recent first (the blocks that just came
// on screen), at most [OverviewAssetLoader.maxInFlight] reads at a time. A read of a range steps through every asset
// before it (LIMIT/OFFSET): near the top of the timeline each request merges with the others that fall within
// [OverviewAssetLoader.mergeSpan] assets of it, a span that grows with the depth, where a read of its own costs more
// than the assets read for nothing between two requests. Deeper, the main timeline reads every request at once in one
// pass ([OverviewIndexedSource]). A block that leaves the screen cancels its request. The assets asked for stay in a
// cache by index until the buckets change.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:logging/logging.dart';

/// Reads [count] assets of the timeline from [index] (TimelineService.peekAssets)
typedef OverviewAssetSource = Future<List<BaseAsset>> Function(int index, int count);

/// Reads the assets at [indexes] of the timeline in one pass (TimelineOverviewRepository, the main timeline); null when
/// the timeline changed since the indexes were taken
typedef OverviewIndexedSource = Future<Map<int, BaseAsset>?> Function(List<int> indexes);

final _log = Logger('OverviewAssetLoader');

class OverviewAssetLoader {
  OverviewAssetLoader(
    this._source, {
    this.indexedSource,
    this.capacity = 4096,
    this.maxInFlight = 2,
    this.mergeSpan = 512,
    this.maxMergeSpan = 4096,
    this.indexedFrom = 2048,
    this.maxIndexes = 1024,
  });

  final OverviewAssetSource _source;

  /// The one-pass reads of the main timeline, null elsewhere
  final OverviewIndexedSource? indexedSource;

  /// The most assets kept in the cache, the oldest read leaving first
  final int capacity;

  /// The most reads at a time
  final int maxInFlight;

  /// The widest range one read may cover to serve several requests near the top of the timeline; deeper, an eighth of
  /// the depth, up to [maxMergeSpan] (on a PC a read stepped through some 10 assets in the time it read one)
  final int mergeSpan;
  final int maxMergeSpan;

  /// The depth from which a request goes to [indexedSource], and the most assets of one such read
  final int indexedFrom;
  final int maxIndexes;

  final _cache = <int, BaseAsset>{};
  final _pending = <OverviewAssetRequest>[];
  var _inFlight = 0;
  var _pumpScheduled = false;
  var _disposed = false;
  var _generation = 0;

  /// Changes each time the cache is cleared: what a block holds from before is stale
  int get generation => _generation;

  /// How many reads went out, and how many in one pass, for the tests
  @visibleForTesting
  int reads = 0;
  @visibleForTesting
  int indexedReads = 0;

  /// The assets of [index, index + count) when all are in the cache
  List<BaseAsset>? cached(int index, int count) {
    final assets = <BaseAsset>[];
    for (var i = index; i < index + count; i++) {
      final asset = _cache[i];
      if (asset == null) {
        return null;
      }
      assets.add(asset);
    }
    return assets;
  }

  /// Asks for the assets of [index, index + count); [onLoaded] gets them (fewer at the end of the timeline) unless the
  /// request is cancelled first or the cache is cleared meanwhile
  OverviewAssetRequest request(int index, int count, ValueChanged<List<BaseAsset>> onLoaded) {
    final request = OverviewAssetRequest._(this, index, count, onLoaded);
    if (_disposed) {
      request._cancelled = true;
      return request;
    }
    _pending.add(request);
    _schedulePump();
    return request;
  }

  /// Forgets what was read and drops what waits: the buckets changed, the indexes point at other assets
  void clear() {
    _generation++;
    _cache.clear();
    for (final request in _pending) {
      request._cancelled = true;
    }
    _pending.clear();
  }

  void dispose() {
    _disposed = true;
    clear();
  }

  void _cancel(OverviewAssetRequest request) {
    request._cancelled = true;
    _pending.remove(request);
  }

  void _schedulePump() {
    if (_pumpScheduled) {
      return;
    }
    _pumpScheduled = true;
    scheduleMicrotask(() {
      _pumpScheduled = false;
      _pump();
    });
  }

  /// Whether [request] goes to the one-pass reads
  bool _indexed(OverviewAssetRequest request) =>
      indexedSource != null && !request._rangeOnly && request.index + request.count > indexedFrom;

  /// The widest range a read from [index] may cover
  int _spanAt(int index) => math.max(mergeSpan, math.min(maxMergeSpan, index ~/ 8));

  void _pump() {
    while (!_disposed && _inFlight < maxInFlight && _pending.isNotEmpty) {
      // The most recent first: the blocks that just came on screen
      final seed = _pending.removeLast();
      final batch = [seed];
      if (_indexed(seed)) {
        // Every other request as deep, in the same pass
        var size = seed.count;
        for (var i = _pending.length - 1; i >= 0 && size < maxIndexes; i--) {
          final other = _pending[i];
          if (_indexed(other)) {
            size += other.count;
            batch.add(other);
            _pending.removeAt(i);
          }
        }
        unawaited(_readIndexed(batch));
        continue;
      }
      var start = seed.index;
      var end = seed.index + seed.count;
      for (var i = _pending.length - 1; i >= 0; i--) {
        final other = _pending[i];
        if (_indexed(other)) {
          continue;
        }
        final mergedStart = math.min(start, other.index);
        final mergedEnd = math.max(end, other.index + other.count);
        if (mergedEnd - mergedStart <= _spanAt(mergedStart)) {
          start = mergedStart;
          end = mergedEnd;
          batch.add(other);
          _pending.removeAt(i);
        }
      }
      unawaited(_read(start, end - start, batch));
    }
  }

  Future<void> _read(int start, int count, List<OverviewAssetRequest> batch) async {
    _inFlight++;
    reads++;
    final generation = _generation;
    try {
      final assets = await _source(start, count);
      if (_disposed || generation != _generation) {
        return;
      }
      for (final request in batch) {
        // The assets asked for, not those read on the way between two requests
        final from = request.index - start;
        final shown = assets.skip(from).take(request.count).toList(growable: false);
        for (var i = 0; i < shown.length; i++) {
          _put(request.index + i, shown[i]);
        }
        if (!request._cancelled) {
          request._onLoaded(shown);
        }
      }
    } catch (error, stack) {
      _log.warning('Could not read $count assets from $start', error, stack);
    } finally {
      _inFlight--;
      if (!_disposed && _pending.isNotEmpty) {
        _schedulePump();
      }
    }
  }

  Future<void> _readIndexed(List<OverviewAssetRequest> batch) async {
    _inFlight++;
    reads++;
    indexedReads++;
    final generation = _generation;
    try {
      final indexes = <int>{
        for (final request in batch)
          for (var i = request.index; i < request.index + request.count; i++) i,
      }.toList()..sort();
      final assets = await indexedSource!(indexes);
      if (_disposed || generation != _generation) {
        return;
      }
      if (assets == null) {
        // The timeline changed since the indexes were taken: the reads of a range answer as the grid does, until the
        // buckets catch up and clear the cache
        for (final request in batch) {
          if (!request._cancelled) {
            request._rangeOnly = true;
            _pending.add(request);
          }
        }
        return;
      }
      for (final request in batch) {
        // Fewer at the end of the timeline
        final shown = <BaseAsset>[];
        for (var i = request.index; i < request.index + request.count; i++) {
          final asset = assets[i];
          if (asset == null) {
            break;
          }
          shown.add(asset);
          _put(i, asset);
        }
        if (!request._cancelled) {
          request._onLoaded(shown);
        }
      }
    } catch (error, stack) {
      _log.warning('Could not read ${batch.length} requests in one pass', error, stack);
    } finally {
      _inFlight--;
      if (!_disposed && _pending.isNotEmpty) {
        _schedulePump();
      }
    }
  }

  void _put(int index, BaseAsset asset) {
    _cache.remove(index);
    _cache[index] = asset;
    if (_cache.length > capacity) {
      _cache.remove(_cache.keys.first);
    }
  }
}

/// A request of [OverviewAssetLoader.request], to cancel when its block leaves the screen
class OverviewAssetRequest {
  OverviewAssetRequest._(this._loader, this.index, this.count, this._onLoaded);

  final OverviewAssetLoader _loader;
  final int index;
  final int count;
  final ValueChanged<List<BaseAsset>> _onLoaded;
  var _cancelled = false;

  /// Read as a range, not in one pass: the pass found the timeline changed
  var _rangeOnly = false;

  bool get isCancelled => _cancelled;

  void cancel() => _loader._cancel(this);
}
