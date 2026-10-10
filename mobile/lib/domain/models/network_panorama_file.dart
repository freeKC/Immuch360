// The 360° photos and videos of the network shares, for the 360° list: the files the app found 360° when it read them
// (the 360° badge of a share folder, a viewer), remembered across starts. The app never walks a share on its own to
// look for them: a share holds thousands of files, each a read over the network.

import 'dart:convert';

import 'package:immich_mobile/domain/models/network_source.dart';

/// A photo or a video of a share whose file declares a 360° projection (see NetworkMediaInfo.is360). [size] and
/// [modified] are those of the listing it was read from: another file at the same path is read again.
class NetworkPanoramaFile {
  const NetworkPanoramaFile({required this.sourceId, required this.path, this.size, this.modified});

  NetworkPanoramaFile.of(NetworkEntry entry)
    : this(sourceId: entry.sourceId, path: entry.path, size: entry.size, modified: entry.modified);

  final String sourceId;

  /// Absolute inside the share, "/" separated, starting with "/"
  final String path;
  final int? size;
  final DateTime? modified;

  /// The file as the browser of the share lists it
  NetworkEntry get entry =>
      NetworkEntry(sourceId: sourceId, path: path, isDirectory: false, size: size, modified: modified);

  bool get isVideo => entry.isVideo;

  /// Whether [entry] is this file: the same share and path
  bool isAt(NetworkEntry entry) => entry.sourceId == sourceId && entry.path == path;

  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    'path': path,
    if (size != null) 'size': size,
    if (modified != null) 'modified': modified!.toUtc().millisecondsSinceEpoch,
  };

  /// Null for anything that is not a stored file
  static NetworkPanoramaFile? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final sourceId = json['sourceId'];
    final path = json['path'];
    final size = json['size'];
    final modified = json['modified'];
    if (sourceId is! String || sourceId.isEmpty || path is! String || !path.startsWith('/')) {
      return null;
    }
    return NetworkPanoramaFile(
      sourceId: sourceId,
      path: path,
      size: size is int ? size : null,
      modified: modified is int ? DateTime.fromMillisecondsSinceEpoch(modified, isUtc: true).toLocal() : null,
    );
  }

  static String encodeList(List<NetworkPanoramaFile> files) => jsonEncode([for (final file in files) file.toJson()]);

  /// A damaged value gives an empty list, a damaged item is left out
  static List<NetworkPanoramaFile> decodeList(String? json) {
    if (json == null || json.isEmpty) {
      return const [];
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) {
      return const [];
    }
    return List.unmodifiable(decoded.map(fromJson).nonNulls);
  }

  /// The same file: the same millisecond for [modified] (what is stored), whether it reads in UTC (a listing) or in
  /// local time (read back)
  @override
  bool operator ==(Object other) =>
      other is NetworkPanoramaFile &&
      other.sourceId == sourceId &&
      other.path == path &&
      other.size == size &&
      other.modified?.millisecondsSinceEpoch == modified?.millisecondsSinceEpoch;

  @override
  int get hashCode => Object.hash(sourceId, path, size, modified?.millisecondsSinceEpoch);

  @override
  String toString() => 'NetworkPanoramaFile($sourceId, $path, $size, $modified)';
}

/// The most files remembered: past it, the ones found first go
const networkPanoramaMaxFiles = 2000;

/// [files] once [entry] was read: added last when it is 360° (in place of an older record of the same path), taken out
/// when it is not, or no longer. [files] itself when nothing changes, so that the caller writes nothing.
List<NetworkPanoramaFile> withNetworkPanorama(
  List<NetworkPanoramaFile> files,
  NetworkEntry entry, {
  required bool is360,
  int maxFiles = networkPanoramaMaxFiles,
}) {
  if (!entry.isMedia) {
    return files;
  }
  final index = files.indexWhere((file) => file.isAt(entry));
  if (!is360) {
    return index < 0 ? files : List.unmodifiable([...files]..removeAt(index));
  }
  final file = NetworkPanoramaFile.of(entry);
  if (index >= 0 && files[index] == file) {
    return files;
  }
  final next = [...files];
  if (index >= 0) {
    next.removeAt(index);
  }
  next.add(file);
  return List.unmodifiable(next.length > maxFiles ? next.sublist(next.length - maxFiles) : next);
}

/// [files] newest first, by the date of the file; those without one last, the latest found first
List<NetworkPanoramaFile> newestNetworkPanoramasFirst(List<NetworkPanoramaFile> files) {
  final indexed = files.indexed.toList();
  indexed.sort((a, b) {
    final (ai, af) = a;
    final (bi, bf) = b;
    final am = af.modified;
    final bm = bf.modified;
    final byDate = am != null && bm != null
        ? bm.compareTo(am)
        : am == null && bm != null
        ? 1
        : am != null && bm == null
        ? -1
        : 0;
    return byDate != 0 ? byDate : bi.compareTo(ai);
  });
  return [for (final (_, file) in indexed) file];
}
