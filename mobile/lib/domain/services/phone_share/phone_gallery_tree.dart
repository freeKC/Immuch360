// The folders "Share this phone on the network" serves: a virtual tree over the gallery of the device, read only.
//
//   /                      Albums, By month, 360
//   /Albums/<album>/       the photos and videos of each album of the device
//   /By month/<yyyy-MM>/   every photo and video by creation month, the newest month first
//   /360/                  the 360° photos and videos found on the device, raw files and forced ones included
//
// The folder names are fixed and ASCII whatever the language of the phone: a headset stores the paths of a share, and
// they must still lead somewhere after the phone changed language. A client only ever names nodes of this tree: a
// path resolves to an asset id through the listings, never to a path of the file system.
//
// Listing a folder of files asks the platform for the size, type and date of its assets (see PhoneShareFiles), one
// call per 500 assets; what the platform does not answer for (gone from the gallery, in iCloud only) is left out.
// Listings are kept 30 s, which a PROPFIND followed by the GETs of its files, or a folder opened again, reuse.

import 'dart:async';
import 'dart:math';

import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/platform/phone_share_api.g.dart';

/// Where the tree takes the albums and assets of the device from, see PhoneGalleryRepository
abstract interface class PhoneGallerySource {
  Future<List<LocalAlbum>> albums();

  Future<List<LocalAsset>> albumAssets(String albumId);

  /// The months that have photos or videos, with how many, the newest first
  Future<List<({int year, int month, int count})>> months();

  /// The photos and videos created in [month] of [year] (local time), the newest first
  Future<List<LocalAsset>> monthAssets(int year, int month);

  Future<List<LocalAsset>> assetsByIds(Iterable<String> ids);
}

/// What the platform tells of the files of the gallery, see PhoneShareApi
abstract interface class PhoneShareFiles {
  /// The size, type, name and date of the assets among [assetIds] that are on the device; the others are left out
  Future<List<PhoneShareFileInfo>> fileInfos(List<String> assetIds);

  /// A path Dart can read the file of [assetId] from, null when it is gone or not on the device
  Future<PhoneShareOpenedFile?> openFile(String assetId);
}

/// A folder or a file of the tree. [path] is absolute, "/" separated, without a trailing "/" ("/" for the root).
sealed class PhoneGalleryNode {
  const PhoneGalleryNode({required this.path, required this.name, this.modified});

  final String path;

  /// The last segment of [path], empty for the root
  final String name;

  final DateTime? modified;

  /// The segments of [path], none for the root
  List<String> get segments => [
    for (final segment in path.split('/'))
      if (segment.isNotEmpty) segment,
  ];
}

final class PhoneGalleryFolder extends PhoneGalleryNode {
  const PhoneGalleryFolder({required super.path, required super.name, super.modified, this.children = const []});

  /// Filled for the folder [PhoneGalleryTree.resolve] answered with, empty for the folders inside it
  final List<PhoneGalleryNode> children;

  PhoneGalleryFolder withChildren(List<PhoneGalleryNode> children) =>
      PhoneGalleryFolder(path: path, name: name, modified: modified, children: children);
}

final class PhoneGalleryFile extends PhoneGalleryNode {
  const PhoneGalleryFile({
    required super.path,
    required super.name,
    required DateTime super.modified,
    required this.assetId,
    required this.size,
    required this.mimeType,
  });

  final String assetId;

  /// Null when the platform does not tell it before the file is opened
  final int? size;

  final String mimeType;

  @override
  DateTime get modified => super.modified!;
}

/// The tree of the phone share, see the top of this file
class PhoneGalleryTree {
  PhoneGalleryTree({
    required this._source,
    required this._files,
    required this._panoramaIds,
    this.cacheTtl = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const albumsFolder = 'Albums';
  static const monthsFolder = 'By month';
  static const panoramasFolder = '360';

  /// Asset ids per question to the platform
  static const fileInfoChunk = 500;

  /// How long a listing is reused
  final Duration cacheTtl;

  final PhoneGallerySource _source;
  final PhoneShareFiles _files;
  final Set<String> Function() _panoramaIds;
  final DateTime Function() _clock;

  final Map<String, ({DateTime at, Future<_Listing> listing})> _listings = {};

  /// Sizes learned by opening the files, for the assets whose size the platform does not tell before
  final Map<String, int> _knownSizes = {};

  /// The node at [path], a folder with its children or a file; null when there is none. Paths are matched without
  /// case, as the names of a folder are unique without case.
  Future<PhoneGalleryNode?> resolve(String path) async {
    final segments = _segmentsOf(path);
    if (segments == null) {
      return null;
    }
    if (segments.isEmpty) {
      return const PhoneGalleryFolder(path: '/', name: '').withChildren(_rootFolders);
    }

    final top = _rootFolders.where((folder) => _sameName(folder.name, segments[0])).firstOrNull;
    if (top == null) {
      return null;
    }
    final topListing = await _listing(top.path);
    if (segments.length == 1) {
      return top.withChildren(topListing.nodes);
    }

    final second = topListing.find(segments[1]);
    if (second == null) {
      return null;
    }
    if (second is PhoneGalleryFile) {
      return segments.length == 2 ? second : null;
    }
    final folder = second as PhoneGalleryFolder;
    final listing = await _listing(folder.path, albumId: topListing.albumIds[folder.path]);
    if (segments.length == 2) {
      return folder.withChildren(listing.nodes);
    }
    final file = listing.find(segments[2]);
    return segments.length == 3 && file is PhoneGalleryFile ? file : null;
  }

  /// The real size of the file of [assetId], learned when it was opened: the next listings tell it
  void rememberSize(String assetId, int size) {
    if (size > 0) {
      _knownSizes[assetId] = size;
    }
  }

  /// Forgets the listings, so that the next requests read the gallery again
  void clear() => _listings.clear();

  static const _rootFolders = [
    PhoneGalleryFolder(path: '/$albumsFolder', name: albumsFolder),
    PhoneGalleryFolder(path: '/$monthsFolder', name: monthsFolder),
    PhoneGalleryFolder(path: '/$panoramasFolder', name: panoramasFolder),
  ];

  /// The listing of the folder at [path] (as the tree names it), from the cache when it is recent; [albumId] for the
  /// folder of an album
  Future<_Listing> _listing(String path, {String? albumId}) {
    final now = _clock();
    final cached = _listings[path];
    if (cached != null && now.difference(cached.at) < cacheTtl && !now.isBefore(cached.at)) {
      return cached.listing;
    }
    _listings.removeWhere((_, entry) => now.difference(entry.at) >= cacheTtl);
    final listing = _read(path, albumId: albumId);
    _listings[path] = (at: now, listing: listing);
    // A failed read is not kept: the next request tries again
    unawaited(
      listing.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_listings[path]?.listing, listing)) {
            _listings.remove(path);
          }
        },
      ),
    );
    return listing;
  }

  Future<_Listing> _read(String path, {String? albumId}) async {
    if (path == '/$albumsFolder') {
      return _albumFolders();
    }
    if (path == '/$monthsFolder') {
      return _monthFolders();
    }
    if (path == '/$panoramasFolder') {
      return _filesOf(path, await _source.assetsByIds(_panoramaIds()));
    }
    if (albumId != null) {
      return _filesOf(path, await _source.albumAssets(albumId));
    }
    final month = _parseMonth(path.substring(path.lastIndexOf('/') + 1));
    if (path.startsWith('/$monthsFolder/') && month != null) {
      return _filesOf(path, await _source.monthAssets(month.year, month.month));
    }
    return const _Listing([]);
  }

  Future<_Listing> _albumFolders() async {
    final albums = [...await _source.albums()]
      ..sort((a, b) {
        final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return byName != 0 ? byName : a.id.compareTo(b.id);
      });
    final names = _UniqueNames();
    final folders = <PhoneGalleryNode>[];
    final ids = <String, String>{};
    for (final album in albums) {
      final name = names.take(sanitizePhoneShareName(album.name), isFolder: true);
      final path = '/$albumsFolder/$name';
      folders.add(PhoneGalleryFolder(path: path, name: name, modified: album.updatedAt.toUtc()));
      ids[path] = album.id;
    }
    return _Listing(folders, albumIds: ids);
  }

  Future<_Listing> _monthFolders() async {
    final months = await _source.months();
    return _Listing([
      for (final month in months)
        if (month.count > 0)
          PhoneGalleryFolder(
            path: '/$monthsFolder/${_monthName(month.year, month.month)}',
            name: _monthName(month.year, month.month),
          ),
    ]);
  }

  /// The files of [assets] in the folder at [folder], the newest first. Names are deduplicated from the oldest asset,
  /// so that a file keeps its name when a newer one with the same name arrives.
  Future<_Listing> _filesOf(String folder, List<LocalAsset> assets) async {
    final media = [
      for (final asset in assets)
        if (asset.type == AssetType.image || asset.type == AssetType.video) asset,
    ];
    final infos = <String, PhoneShareFileInfo>{};
    for (var start = 0; start < media.length; start += fileInfoChunk) {
      final chunk = [for (final asset in media.sublist(start, min(start + fileInfoChunk, media.length))) asset.id];
      for (final info in await _files.fileInfos(chunk)) {
        infos[info.assetId] = info;
      }
    }

    media.sort((a, b) {
      final byDate = a.createdAt.compareTo(b.createdAt);
      return byDate != 0 ? byDate : a.id.compareTo(b.id);
    });
    final names = _UniqueNames();
    final files = <PhoneGalleryNode>[];
    for (final asset in media) {
      final info = infos[asset.id];
      if (info == null) {
        continue;
      }
      final name = names.take(phoneShareFileName(asset.name, info.fileName), isFolder: false);
      files.add(
        PhoneGalleryFile(
          path: '$folder/$name',
          name: name,
          assetId: asset.id,
          size: info.size > 0 ? info.size : _knownSizes[asset.id],
          mimeType: info.mimeType,
          modified: info.modifiedMs > 0
              ? DateTime.fromMillisecondsSinceEpoch(info.modifiedMs, isUtc: true)
              : asset.updatedAt.toUtc(),
        ),
      );
    }
    return _Listing(files.reversed.toList());
  }

  /// The segments of [path] without the empty ones, null when one is "." or ".." (no node has such a name)
  static List<String>? _segmentsOf(String path) {
    final segments = [
      for (final segment in path.split('/'))
        if (segment.isNotEmpty) segment,
    ];
    if (segments.any((segment) => segment == '.' || segment == '..') || segments.length > 3) {
      return null;
    }
    return segments;
  }

  static String _monthName(int year, int month) =>
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';

  static ({int year, int month})? _parseMonth(String name) {
    final match = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(name);
    if (match == null) {
      return null;
    }
    final month = int.parse(match.group(2)!);
    return month < 1 || month > 12 ? null : (year: int.parse(match.group(1)!), month: month);
  }
}

/// [name] usable as one segment of a path: "/", "\" and the control characters become "_", and a name that is empty
/// or made of dots only (which a client would read as the folder itself or its parent) becomes "_"
String sanitizePhoneShareName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[/\\\x00-\x1f\x7f]'), '_').trim();
  if (cleaned.isEmpty || RegExp(r'^\.+$').hasMatch(cleaned)) {
    return '_';
  }
  return cleaned;
}

/// The name a file is served under: the original name of the asset ([assetName]), with the extension of the file the
/// platform serves ([servedName]) when it differs, as for an edited iPhone photo served as its JPEG rendering
String phoneShareFileName(String assetName, String servedName) {
  final name = sanitizePhoneShareName(assetName);
  final servedDot = servedName.lastIndexOf('.');
  if (servedDot <= 0 || servedDot == servedName.length - 1) {
    return name;
  }
  final servedExtension = servedName.substring(servedDot + 1);
  final dot = name.lastIndexOf('.');
  final extension = dot <= 0 ? '' : name.substring(dot + 1);
  if (extension.toLowerCase() == servedExtension.toLowerCase()) {
    return name;
  }
  return sanitizePhoneShareName('${dot <= 0 ? name : name.substring(0, dot)}.$servedExtension');
}

bool _sameName(String a, String b) => a.toLowerCase() == b.toLowerCase();

/// The nodes of one folder, and the album id of each album folder by its path
class _Listing {
  const _Listing(this.nodes, {this.albumIds = const {}});

  final List<PhoneGalleryNode> nodes;
  final Map<String, String> albumIds;

  PhoneGalleryNode? find(String name) => nodes.where((node) => _sameName(node.name, name)).firstOrNull;
}

/// Names unique in one folder without case: the second "IMG_1.jpg" becomes "IMG_1 (2).jpg", the second album
/// "Camera" becomes "Camera (2)"
class _UniqueNames {
  final Set<String> _taken = {};

  String take(String name, {required bool isFolder}) {
    if (_taken.add(name.toLowerCase())) {
      return name;
    }
    final dot = isFolder ? -1 : name.lastIndexOf('.');
    final stem = dot <= 0 ? name : name.substring(0, dot);
    final extension = dot <= 0 ? '' : name.substring(dot);
    for (var number = 2; ; number++) {
      final candidate = '$stem ($number)$extension';
      if (_taken.add(candidate.toLowerCase())) {
        return candidate;
      }
    }
  }
}
