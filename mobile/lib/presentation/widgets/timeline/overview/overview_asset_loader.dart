// The thumbnails of the months and the years come from all over the library at once: a few assets at the start of each
// month on screen. They are read here rather than through the buffer of the grid (TimelineService.loadAssets), which
// keeps a single window of 1024 assets and would load a new one for each block.
//
// The requests made in one frame wait for the end of it, then go out the most recent first (the blocks that just came
// on screen), each merged with the others that fall within [OverviewAssetLoader.mergeSpan] assets of it, at most
// [OverviewAssetLoader.maxInFlight] at a time. A block that leaves the screen cancels its request. What was read stays
// in a cache by index until the buckets change.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:logging/logging.dart';

/// Reads [count] assets of the timeline from [index] (TimelineService.peekAssets)
typedef OverviewAssetSource = Future<List<BaseAsset>> Function(int index, int count);

final _log = Logger('OverviewAssetLoader');

class OverviewAssetLoader {
  OverviewAssetLoader(this._source, {this.capacity = 4096, this.maxInFlight = 2, this.mergeSpan = 512});

  final OverviewAssetSource _source;

  /// The most assets kept in the cache, the oldest read leaving first
  final int capacity;

  /// The most reads at a time
  final int maxInFlight;

  /// The widest range one read may cover to serve several requests
  final int mergeSpan;

  final _cache = <int, BaseAsset>{};
  final _pending = <OverviewAssetRequest>[];
  var _inFlight = 0;
  var _pumpScheduled = false;
  var _disposed = false;
  var _generation = 0;

  /// Changes each time the cache is cleared: what a block holds from before is stale
  int get generation => _generation;

  /// How many reads went out, for the tests
  @visibleForTesting
  int reads = 0;

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

  void _pump() {
    while (!_disposed && _inFlight < maxInFlight && _pending.isNotEmpty) {
      // The most recent first: the blocks that just came on screen
      final seed = _pending.removeLast();
      var start = seed.index;
      var end = seed.index + seed.count;
      final batch = [seed];
      for (var i = _pending.length - 1; i >= 0; i--) {
        final other = _pending[i];
        final mergedStart = math.min(start, other.index);
        final mergedEnd = math.max(end, other.index + other.count);
        if (mergedEnd - mergedStart <= mergeSpan) {
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
      for (var i = 0; i < assets.length; i++) {
        _put(start + i, assets[i]);
      }
      for (final request in batch) {
        if (request._cancelled) {
          continue;
        }
        final from = request.index - start;
        request._onLoaded(assets.skip(from).take(request.count).toList(growable: false));
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

  bool get isCancelled => _cancelled;

  void cancel() => _loader._cancel(this);
}
