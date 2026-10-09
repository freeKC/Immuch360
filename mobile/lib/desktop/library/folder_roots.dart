// The folders of the library of Immuch360 Desktop: what a root is, which files and folders a scan takes, and the ids
// the local tables know them by.
//
// A file's id is "f" and the first 20 bytes of HMAC-SHA-256 of "<root id>/<path relative to the root>", in hex. The
// root id comes from the volume (see volume_id.dart), not from the drive letter or the mount point, so a drive that
// comes back as F: instead of E: keeps the ids of its files. The id is never the path itself: it reaches the server as
// the deviceAssetId of an upload, and a path would carry the user's account name there. Nor is it a plain hash of the
// path: the only unknown in "win-1a2b3c4d:/users/<account>/pictures/img_0001.jpg" is a 32-bit volume serial number
// (none at all for a share), so whoever sees the id on the server could try a guessed account name against every
// serial in seconds. The key is a random secret made once per installation and kept in the index
// (LibraryIndex.ids); it never leaves the computer. The relative path is case folded where the file system ignores
// case (Windows, macOS), so a rename that only changes the case keeps the id, as the file system sees one file.
//
// Each folder that holds media is an album, like a bucket of the Android gallery; its id is built the same way from
// the folder's path, with "d" in front.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_windows/path_provider_windows.dart';

/// The two kinds of media the library takes, numbered like AssetType (image 1, video 2) for PlatformAsset.type
enum LibraryMediaKind {
  image(1),
  video(2);

  const LibraryMediaKind(this.assetType);

  final int assetType;
}

// What the Immich server accepts (server/src/utils/mime-types.ts), less the vector images, plus the files of 360°
// cameras the app opens itself: GoPro .360 and .36p, DJI .osv. The low resolution proxies of the cameras (.lrv, .lrf)
// are no media of their own.
const _imageExtensions = {
  'jpg',
  'jpeg',
  'jpe',
  'jfif',
  'png',
  'gif',
  'webp',
  'bmp',
  'avif',
  'heic',
  'heif',
  'hif',
  'jxl',
  'jp2',
  'tif',
  'tiff',
  'insp',
  'mpo',
  '36p',
  'dng',
  '3fr',
  'ari',
  'arw',
  'cap',
  'cin',
  'cr2',
  'cr3',
  'crw',
  'dcr',
  'erf',
  'fff',
  'iiq',
  'k25',
  'kdc',
  'mrw',
  'nef',
  'nrw',
  'orf',
  'ori',
  'pef',
  'psd',
  'raf',
  'raw',
  'rw2',
  'rwl',
  'sr2',
  'srf',
  'srw',
  'x3f',
};

const _videoExtensions = {
  '3gp',
  '3gpp',
  'avi',
  'flv',
  'insv',
  'm2t',
  'm2ts',
  'm4v',
  'mkv',
  'mov',
  'mp4',
  'mpe',
  'mpeg',
  'mpg',
  'mts',
  'mxf',
  'ts',
  'vob',
  'webm',
  'wmv',
  '360',
  'osv',
};

String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/// Whether the library takes a file named [name], and as what; null for anything else
LibraryMediaKind? mediaKindOfName(String name) {
  final extension = _extensionOf(name);
  if (_imageExtensions.contains(extension)) {
    return LibraryMediaKind.image;
  }
  if (_videoExtensions.contains(extension)) {
    return LibraryMediaKind.video;
  }
  return null;
}

/// A content type for the file named [name], for the computer share and the uploads; the raw videos of 360° cameras
/// are MP4 files under names of their own
String mimeTypeOfName(String name) => switch (_extensionOf(name)) {
  'jpg' || 'jpeg' || 'jpe' || 'jfif' || 'insp' || 'mpo' || '36p' => 'image/jpeg',
  'png' => 'image/png',
  'gif' => 'image/gif',
  'webp' => 'image/webp',
  'bmp' => 'image/bmp',
  'avif' => 'image/avif',
  'heic' || 'hif' => 'image/heic',
  'heif' => 'image/heif',
  'jxl' => 'image/jxl',
  'jp2' => 'image/jp2',
  'tif' || 'tiff' => 'image/tiff',
  'dng' => 'image/x-adobe-dng',
  'mp4' || 'insv' || '360' || 'osv' => 'video/mp4',
  'm4v' => 'video/x-m4v',
  'mov' => 'video/quicktime',
  'mkv' => 'video/x-matroska',
  'webm' => 'video/webm',
  'avi' => 'video/x-msvideo',
  '3gp' || '3gpp' => 'video/3gpp',
  'mts' || 'm2ts' || 'm2t' || 'ts' => 'video/mp2t',
  'mpg' || 'mpeg' || 'mpe' || 'vob' => 'video/mpeg',
  'wmv' => 'video/x-ms-wmv',
  'flv' => 'video/x-flv',
  'mxf' => 'application/mxf',
  final extension =>
    mediaKindOfName('x.$extension') == LibraryMediaKind.image ? 'image/$extension' : 'application/octet-stream',
};

// Folders that are never media: the recycle bins and the volume data of Windows, the thumbnail caches of Linux
// desktops and of Synology, and the recycle bin of a Synology share
const _skippedFolderNames = {
  r'$recycle.bin',
  'system volume information',
  '.thumbnails',
  '@eadir',
  '#recycle',
  'found.000',
};

/// Whether a scan skips the folder named [name]: hidden ones (a leading dot), the recycle bins, the volume data of
/// Windows and the thumbnail caches. Hidden folders by attribute are skipped by the Windows lister.
bool isSkippedFolderName(String name) => name.startsWith('.') || _skippedFolderNames.contains(name.toLowerCase());

/// Whether a scan skips the file named [name] whatever its extension: hidden files, among them the "._IMG_1234.JPG"
/// companions macOS writes on drives that are not its own, which hold no picture
bool isSkippedFileName(String name) => name.startsWith('.');

/// How paths are compared on this computer: the separators of its file system, and whether case matters there
class LibraryPathRules {
  const LibraryPathRules({required this.context, required this.caseFold});

  /// The rules of the file system the app runs on: Windows and macOS ignore case
  factory LibraryPathRules.thisComputer() =>
      LibraryPathRules(context: p.context, caseFold: Platform.isWindows || Platform.isMacOS);

  final p.Context context;
  final bool caseFold;

  /// [relative] (in the separators of [context]) as ids are built from it: "/" between the parts, no empty part, case
  /// folded where the file system ignores case
  String key(String relative) {
    final parts = context.split(relative).where((part) => part.isNotEmpty && part != '.' && part != context.separator);
    final joined = parts.join('/');
    return caseFold ? joined.toLowerCase() : joined;
  }
}

// "<root id>/<relative key>": the root id ends with the root's path inside its volume, so the key is the file's path
// inside the volume whatever root it is found under; a root at the top of a volume ("win-1a2b3c4d:/") already ends
// with the separator
String _keyUnder(String rootId, String relativeKey) {
  if (relativeKey.isEmpty) {
    return rootId;
  }
  return rootId.endsWith('/') ? '$rootId$relativeKey' : '$rootId/$relativeKey';
}

/// The length of the key of the ids, in bytes: the block of SHA-256 holds it whole
const libraryIdKeyLength = 32;

/// Builds the ids of the files and albums of one library, with the key of its index (see the header of this file)
class LibraryIds {
  LibraryIds(List<int> key) : _hmac = Hmac(sha256, key) {
    if (key.length != libraryIdKeyLength) {
      throw ArgumentError.value(key.length, 'key', 'A key of the library ids is $libraryIdKeyLength bytes');
    }
  }

  final Hmac _hmac;

  /// The id of the file at [relativeKey] (see [LibraryPathRules.key]) under the root [rootId]. It depends only on the
  /// volume and the file's path inside it, so a folder added inside or around an existing root finds the same ids.
  String file(String rootId, String relativeKey) => _hexId('f', _keyUnder(rootId, relativeKey));

  /// The id of the album of the folder at [relativeDirKey] (empty for the root itself) under the root [rootId]
  String album(String rootId, String relativeDirKey) => _hexId('d', _keyUnder(rootId, relativeDirKey));

  String _hexId(String prefix, String key) {
    final digest = _hmac.convert(utf8.encode(key)).bytes;
    final buffer = StringBuffer(prefix);
    for (var i = 0; i < 20; i++) {
      buffer.write(digest[i].toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

/// Whether the root [childId] lies inside the root [parentId] (both built by VolumeIdentity.rootId)
bool rootContains(String parentId, String childId) {
  if (parentId == childId) {
    return false;
  }
  return parentId.endsWith('/') ? childId.startsWith(parentId) : childId.startsWith('$parentId/');
}

/// A folder the user added to the library
class LibraryRoot {
  const LibraryRoot({
    required this.id,
    required this.path,
    required this.volumeKey,
    required this.pathInVolume,
    required this.isNetwork,
    required this.includeCloudOnly,
    required this.available,
    required this.addedAt,
    this.scannedAt,
    this.fileCount = 0,
    this.cloudOnlyCount = 0,
  });

  /// From the volume and the path inside it (see volume_id.dart), so that it survives a change of drive letter
  final String id;

  /// Where the folder is now
  final String path;

  /// The volume the folder is on ("win-1a2b3c4d", "uuid-...", "net-...") and the folder's path inside it
  final String volumeKey;
  final String pathInVolume;

  /// A network folder (a share or a mapped drive): not watched, since change notifications over SMB are unreliable
  final bool isNetwork;

  /// Whether the user chose "Download and include" for the files kept online only (OneDrive)
  final bool includeCloudOnly;

  /// False while its drive is not connected: its files stay in the library as they were
  final bool available;

  final DateTime addedAt;
  final DateTime? scannedAt;

  /// Photos and videos the library shows from it, and those it leaves out because they are online only
  final int fileCount;
  final int cloudOnlyCount;

  /// The name the user knows the folder by: its own name, or the drive for the root of a drive ("E:\")
  String get displayName {
    final name = p.basename(path);
    return name.isEmpty ? path : name;
  }
}

/// A folder the folders page offers before the user picked one: the Pictures and Videos folders of the account
class FolderSuggestion {
  const FolderSuggestion(this.path);

  final String path;
}

// FOLDERID_Pictures and FOLDERID_Videos (WindowsKnownFolder.Pictures and .Videos, which the analyzer cannot see
// behind the conditional export of path_provider_windows)
const _knownFolderPictures = '{33E28130-4E1E-4676-835A-98395C3BC3BB}';
const _knownFolderVideos = '{18989B1D-99B5-455B-841C-AB7C74E4DDFC}';

/// The Pictures and Videos folders of this computer that exist: the known folders on Windows (often in OneDrive), the
/// XDG folders on Linux, ~/Pictures and ~/Movies on macOS
Future<List<FolderSuggestion>> folderSuggestions() async {
  final candidates = <String?>[];
  try {
    if (Platform.isWindows) {
      final provider = PathProviderWindows();
      candidates
        ..add(await provider.getPath(_knownFolderPictures))
        ..add(await provider.getPath(_knownFolderVideos));
    } else {
      final home = Platform.environment['HOME'];
      if (home != null) {
        if (Platform.isLinux) {
          final dirs = _xdgUserDirs(home);
          candidates
            ..add(dirs['XDG_PICTURES_DIR'] ?? p.join(home, 'Pictures'))
            ..add(dirs['XDG_VIDEOS_DIR'] ?? p.join(home, 'Videos'));
        } else if (Platform.isMacOS) {
          candidates
            ..add(p.join(home, 'Pictures'))
            ..add(p.join(home, 'Movies'));
        }
      }
    }
  } catch (_) {
    // No suggestion is better than no page: the user can still add any folder
  }
  final seen = <String>{};
  final suggestions = <FolderSuggestion>[];
  for (final path in candidates.nonNulls) {
    // ignore: avoid_slow_async_io
    if (path.isNotEmpty && seen.add(path) && await Directory(path).exists()) {
      suggestions.add(FolderSuggestion(path));
    }
  }
  return suggestions;
}

// ~/.config/user-dirs.dirs: lines like XDG_PICTURES_DIR="$HOME/Images" in the user's language
Map<String, String> _xdgUserDirs(String home) {
  final file = File(p.join(Platform.environment['XDG_CONFIG_HOME'] ?? p.join(home, '.config'), 'user-dirs.dirs'));
  final dirs = <String, String>{};
  try {
    for (final line in file.readAsLinesSync()) {
      final match = RegExp(r'^\s*(XDG_[A-Z]+_DIR)\s*=\s*"(.*)"\s*$').firstMatch(line);
      if (match != null) {
        dirs[match.group(1)!] = match.group(2)!.replaceFirst(r'$HOME', home);
      }
    }
  } on FileSystemException {
    // Not set up: the English defaults
  }
  return dirs;
}

/// Names for the albums of [folders] (album id to the folder's parts, root name first): the folder's own name, with
/// its parents in front, "Trips/2024", for the folders whose names would otherwise be the same
Map<String, String> albumDisplayNames(Map<String, List<String>> folders) {
  final names = <String, String>{};
  var depth = 1;
  var pending = folders.keys.toList();
  while (pending.isNotEmpty) {
    final candidate = <String, String>{for (final id in pending) id: _lastParts(folders[id]!, depth)};
    final counts = <String, int>{};
    for (final name in [...candidate.values, ...names.values]) {
      counts[name] = (counts[name] ?? 0) + 1;
    }
    final next = <String>[];
    for (final id in pending) {
      final parts = folders[id]!;
      final name = candidate[id]!;
      if (counts[name] == 1 || depth >= parts.length) {
        names[id] = name;
      } else {
        next.add(id);
      }
    }
    pending = next;
    depth++;
  }
  return names;
}

String _lastParts(List<String> parts, int depth) =>
    parts.sublist(parts.length - (depth < parts.length ? depth : parts.length)).join('/');
