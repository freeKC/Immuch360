// Previous and next in the immersive viewer of the Meta Quest: from the media it shows, the nearest one in that
// direction that it can show as 360°, among the assets of a timeline or the files of a share folder.
//
// Most media of a timeline are flat, so a search reads the timeline a chunk at a time and checks a whole chunk at
// once (one database query for what the server flags), and gives up past a bound: a long timeline without any 360°
// media ahead must not keep the headset waiting. Checking a file of a share costs a read of it over the network, so
// those are checked one by one, with a lower bound and a bound on each read. Whatever the bounds, a search stops at
// a deadline, past which the headset no longer waits for it.

import 'dart:math' as math;

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/spatial_media.dart';

/// Most assets of a timeline a search goes through, in one direction
const immersiveTimelineSearchLimit = 400;

/// Assets of a timeline loaded and checked at once
const immersiveTimelineChunkSize = 32;

/// Most files of a share folder a search goes through, in one direction
const immersiveFolderSearchLimit = 50;

/// Longest wait for what a file of a share declares during a search: a slow file is skipped rather than holding the
/// search past its deadline
const immersiveFolderFileTimeout = Duration(seconds: 5);

/// Longest search for the previous or next media: the headset waits for the answer meanwhile, and gives up on its
/// side past that (see ImmersiveEvents.requestAdjacent)
const immersiveSearchDeadline = Duration(seconds: 12);

/// A media found by [findAdjacentImmersive]: its [index] in the list searched, and the [item] there
typedef ImmersiveCandidate<T> = ({int index, T item});

/// Looks for the nearest item after [index] in the direction of [step] (+1 next, -1 previous: only its sign counts)
/// that the immersive viewer can show, among [length] items. Returns null when there is none within [limit] items in
/// that direction, for a [step] of 0, and once [isCancelled] says so.
///
/// The items are looked up and checked [chunkSize] at a time, nearest first: [lookup] gives the items from `start`
/// on, `count` of them at most (fewer, or nulls, where it has none, which are skipped), and [isCapable] tells for
/// each of the items it is given whether the viewer can show it, in the same order. No item past the first chunk
/// holding a capable one is looked up.
Future<ImmersiveCandidate<T>?> findAdjacentImmersive<T extends Object>({
  required int index,
  required int step,
  required int length,
  required Future<List<T?>> Function(int start, int count) lookup,
  required Future<List<bool>> Function(List<T> items) isCapable,
  int limit = immersiveTimelineSearchLimit,
  int chunkSize = immersiveTimelineChunkSize,
  bool Function()? isCancelled,
}) async {
  final direction = step.sign;
  if (direction == 0 || limit <= 0 || chunkSize <= 0 || length <= 0) {
    return null;
  }
  // The farthest index the search may reach: inside the list, and within the limit
  final last = direction > 0 ? math.min(length - 1, index + limit) : math.max(0, index - limit);
  // The list may have shrunk since the media was opened: a search backwards starts from its end then
  var next = direction > 0 ? math.max(0, index + 1) : math.min(length - 1, index - 1);
  while (direction > 0 ? next <= last : next >= last) {
    if (isCancelled?.call() ?? false) {
      return null;
    }
    final count = math.min(chunkSize, (last - next).abs() + 1);
    final start = direction > 0 ? next : next - count + 1;
    final items = await lookup(start, count);
    final candidates = <ImmersiveCandidate<T>>[];
    for (var offset = 0; offset < count; offset++) {
      // Nearest first: from the start of the chunk going forwards, from its end going backwards
      final position = direction > 0 ? offset : count - 1 - offset;
      final item = position < items.length ? items[position] : null;
      if (item != null) {
        candidates.add((index: start + position, item: item));
      }
    }
    if (candidates.isNotEmpty) {
      if (isCancelled?.call() ?? false) {
        return null;
      }
      final capable = await isCapable([for (final candidate in candidates) candidate.item]);
      for (var i = 0; i < candidates.length && i < capable.length; i++) {
        if (capable[i]) {
          return candidates[i];
        }
      }
    }
    next += direction * count;
  }
  return null;
}

/// [findAdjacentImmersive] among the files of a share folder, [items] in the order the browser lists them, from the
/// one at [index]. Each file is checked on its own ([isCapable]), the search stopping at the first one the viewer can
/// show: checking one reads it over the network.
Future<ImmersiveCandidate<T>?> findAdjacentImmersiveInFolder<T extends Object>({
  required List<T> items,
  required int index,
  required int step,
  required Future<bool> Function(T item) isCapable,
  int limit = immersiveFolderSearchLimit,
  bool Function()? isCancelled,
}) => findAdjacentImmersive<T>(
  index: index,
  step: step,
  length: items.length,
  lookup: (start, count) async => items.sublist(start, math.min(items.length, start + count)),
  isCapable: (chunk) async => [for (final item in chunk) await isCapable(item)],
  limit: limit,
  chunkSize: 1,
  isCancelled: isCancelled,
);

/// Whether the immersive viewer shows [asset] as a 360° media, as far as what is at hand tells without reading its
/// file: any photo or video of the 360° timeline ([all360]); elsewhere, one the user chose to view as 360° ([forced],
/// keys as [spatialLayoutKey] makes them, or ids on the device), one whose file on the device declares it ([localIds],
/// ids on the device), or one the server flags as equirectangular ([equirectangularIds], server ids). The same rules
/// as the 360° button of the asset viewer (see isEquirectangularProvider), which shows only for those.
bool isImmersiveCandidate(
  BaseAsset asset, {
  required bool all360,
  required Set<String> forced,
  required Set<String> localIds,
  Set<String> equirectangularIds = const {},
}) {
  if (!asset.isImage && !asset.isVideo) {
    return false;
  }
  if (all360) {
    return true;
  }
  final localId = asset.localId;
  if (forced.contains(spatialLayoutKey(asset)) || (localId != null && forced.contains(localId))) {
    return true;
  }
  if (localId != null && localIds.contains(localId)) {
    return true;
  }
  final remoteId = asset.remoteId;
  return remoteId != null && equirectangularIds.contains(remoteId);
}
