// The one-key rotation of the viewers: a photo turned by quarter turns, 90° clockwise per press. An Immich photo the
// server can edit is turned on the server (see ViewRotationController); every other flat photo is turned on screen
// only, and the turn is remembered on this device (StoreKey.viewRotations), per asset of the library and per file of
// a network share. The 360°, 180° and 3D views never read any of it (see rotationModeProvider).

import 'dart:convert';
import 'dart:ui' show Size;

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/spatial_media.dart';

/// [turns] brought into 0 to 3: 4 quarter turns are no turn, -1 is 3
int normalizeQuarterTurns(int turns) => ((turns % 4) + 4) % 4;

/// [size] once turned by [turns] quarter turns: width and height swap for an odd number
Size rotatedSize(Size size, int turns) => normalizeQuarterTurns(turns).isOdd ? size.flipped : size;

/// Key of an asset of the library in the remembered rotations: an asset of the server under its server id, as for
/// the other choices kept per asset (see [spatialLayoutKey]); a file of the device under its id there, even when its
/// copy is on the server: the views of the device albums draw the file, never what an edit of the server made of it,
/// so its turns are kept apart from those of the server's picture.
String viewRotationAssetKey(BaseAsset asset) => _assetKey(asset is LocalAsset ? asset.id : spatialLayoutKey(asset));

/// The key of [asset] under its id on the device, null when it has none: a rotation chosen before the upload is
/// found there once the asset has a server id
String? viewRotationLocalKey(BaseAsset asset) {
  final localId = asset.localId;
  return localId == null ? null : _assetKey(localId);
}

String _assetKey(String id) => '$_assetPrefix$id';

const _assetPrefix = 'a:';
const _sharePrefix = 'n:';

/// The id of the asset behind [key], null for a key that is not an asset's
String? viewRotationAssetId(String key) => key.startsWith(_assetPrefix) ? key.substring(_assetPrefix.length) : null;

/// Key of the file at [path] of the network share [sourceId] in the remembered rotations
String viewRotationShareKey(String sourceId, String path) => '$_sharePrefix$sourceId:$path';

/// Whether [key] is the key of a file of the share [sourceId]
bool isViewRotationShareKeyOf(String key, String sourceId) => key.startsWith('$_sharePrefix$sourceId:');

/// A remembered rotation: [turns] quarter turns clockwise (1 to 3). A file of a share also keeps its [size] and its
/// [modifiedMs] as it was turned: a different size or date means another file under the same path, whose rotation is
/// then ignored. An asset of a server keeps the user signed in when it was turned ([userId]): only that user's
/// library tells whether it is gone, another account's leaves it alone.
class ViewRotationEntry {
  const ViewRotationEntry(this.turns, {this.size, this.modifiedMs, this.userId});

  final int turns;
  final int? size;
  final int? modifiedMs;
  final String? userId;

  /// Whether this rotation was made for a file of [size] modified at [modifiedMs]
  bool matchesFile({int? size, int? modifiedMs}) => this.size == size && this.modifiedMs == modifiedMs;

  @override
  bool operator ==(Object other) =>
      other is ViewRotationEntry &&
      other.turns == turns &&
      other.size == size &&
      other.modifiedMs == modifiedMs &&
      other.userId == userId;

  @override
  int get hashCode => Object.hash(turns, size, modifiedMs, userId);

  @override
  String toString() => 'ViewRotationEntry($turns, size: $size, modifiedMs: $modifiedMs, userId: $userId)';
}

/// The quarter turns [entries] keep for the file at [path] of the share [sourceId], of [size] bytes modified at
/// [modifiedMs]: 0 when none, or when they were kept for another file under that path
int viewRotationShareTurnsOf(
  Map<String, ViewRotationEntry> entries,
  String sourceId,
  String path, {
  int? size,
  int? modifiedMs,
}) {
  final entry = entries[viewRotationShareKey(sourceId, path)];
  return entry != null && entry.matchesFile(size: size, modifiedMs: modifiedMs) ? entry.turns : 0;
}

/// Past this many photos, the ones turned first are forgotten
const maxViewRotations = 5000;

/// Reads the remembered rotations from their JSON form: a map from `a:<asset id>` to the quarter turns, or to
/// `{"t": turns, "u": user id}` for an asset of a server, and from `n:<source id>:<path>` to `{"t": turns, "s": size,
/// "m": modified ms}`, the latest last. A damaged value, an unknown kind of key and turns out of 1 to 3 are skipped.
Map<String, ViewRotationEntry> decodeViewRotations(String? json) {
  final entries = <String, ViewRotationEntry>{};
  if (json == null || json.isEmpty) {
    return entries;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return entries;
  }
  if (decoded is! Map) {
    return entries;
  }
  for (final MapEntry(:key, :value) in decoded.entries) {
    if (key is! String) {
      continue;
    }
    final entry = key.startsWith(_assetPrefix)
        ? (value is Map ? _assetEntryOf(value) : _turnsOf(value))
        : key.startsWith(_sharePrefix) && value is Map
        ? _shareEntryOf(value)
        : null;
    if (entry != null) {
      entries[key] = entry;
    }
  }
  return entries;
}

ViewRotationEntry? _turnsOf(Object? value) =>
    value is int && value >= 1 && value <= 3 ? ViewRotationEntry(value) : null;

ViewRotationEntry? _assetEntryOf(Map<dynamic, dynamic> value) {
  final turns = _turnsOf(value['t']);
  final userId = value['u'];
  if (turns == null || (userId != null && userId is! String)) {
    return null;
  }
  return ViewRotationEntry(turns.turns, userId: userId as String?);
}

ViewRotationEntry? _shareEntryOf(Map<dynamic, dynamic> value) {
  final turns = _turnsOf(value['t']);
  final size = value['s'];
  final modified = value['m'];
  if (turns == null || (size != null && size is! int) || (modified != null && modified is! int)) {
    return null;
  }
  return ViewRotationEntry(turns.turns, size: size as int?, modifiedMs: modified as int?);
}

/// The JSON form of [entries], see [decodeViewRotations]
String encodeViewRotations(Map<String, ViewRotationEntry> entries) => jsonEncode({
  for (final MapEntry(:key, :value) in entries.entries)
    key: key.startsWith(_sharePrefix)
        ? {
            't': value.turns,
            if (value.size != null) 's': value.size,
            if (value.modifiedMs != null) 'm': value.modifiedMs,
          }
        : value.userId != null
        ? {'t': value.turns, 'u': value.userId}
        : value.turns,
});

/// [entries] with [key] set to [entry], moved to the end as the latest; without it when [entry] is null. The ones
/// turned first go past [maxEntries].
Map<String, ViewRotationEntry> withViewRotation(
  Map<String, ViewRotationEntry> entries,
  String key,
  ViewRotationEntry? entry, {
  int maxEntries = maxViewRotations,
}) {
  final next = {...entries}..remove(key);
  if (entry != null) {
    next[key] = entry;
  }
  while (next.length > maxEntries) {
    next.remove(next.keys.first);
  }
  return next;
}
