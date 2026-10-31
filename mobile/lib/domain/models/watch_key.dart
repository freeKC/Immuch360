import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';

/// Under which key the watch progress of a video is kept on this device (see WatchProgressStore): [key], else [alias]
/// for a row made before the video got its key (a video of the device before its upload), else [fingerprint] for a file
/// of a share renamed or moved since (the same share, size and date).
class WatchKey {
  const WatchKey(this.key, {this.alias, this.fingerprint});

  /// An asset of the server by its server id (`asset:<remoteId>`), the same lookup as the other choices kept per asset
  /// (see spatialLayoutKey): a server id is a UUID, unique across servers, so no address goes in the key (it changes
  /// when the app switches between the local and the external address of one server). Also found under its id on the
  /// device (`local:<localId>`), so that a film started before the upload carries on after it. A file of the device, or
  /// of the library of a computer, by that id alone.
  factory WatchKey.ofAsset(BaseAsset asset) {
    final remoteId = asset.remoteId;
    final localId = asset.localId;
    if (remoteId != null) {
      return WatchKey('$_assetPrefix$remoteId', alias: localId == null ? null : '$_localPrefix$localId');
    }
    return WatchKey('$_localPrefix${localId ?? asset.id}');
  }

  /// A file of a share by its share and its path (`share:<sourceId>:<path>`), with the fingerprint of its size and date
  /// when the share tells them. A file of a drone, a card or a folder picked in the system picker (see
  /// NetworkEntry.isImported) by its name and size, as the uploads know it (see UploadRecordStore.keyOf): the folder
  /// picked changes at each plug.
  factory WatchKey.ofEntry(NetworkEntry entry) {
    if (entry.isImported) {
      return WatchKey('$_importPrefix${UploadRecordStore.keyOf(entry)}');
    }
    final size = entry.size;
    final modified = entry.modified;
    return WatchKey(
      '$_sharePrefix${entry.sourceId}:${entry.path}',
      fingerprint: size == null || modified == null
          ? null
          : '$_fingerprintPrefix${entry.sourceId}:$size:${modified.toUtc().millisecondsSinceEpoch}',
    );
  }

  final String key;
  final String? alias;
  final String? fingerprint;

  /// The keys a row is looked up under, in order
  List<String> get lookups => [key, ?alias];

  static const _assetPrefix = 'asset:';
  static const _localPrefix = 'local:';
  static const _sharePrefix = 'share:';
  static const _importPrefix = 'import:';
  static const _fingerprintPrefix = 'fp:';

  @override
  bool operator ==(Object other) =>
      other is WatchKey && other.key == key && other.alias == alias && other.fingerprint == fingerprint;

  @override
  int get hashCode => Object.hash(key, alias, fingerprint);

  @override
  String toString() => 'WatchKey($key${alias != null ? ', $alias' : ''}${fingerprint != null ? ', $fingerprint' : ''})';
}
