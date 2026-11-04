// What a network share looks like to the app, whatever its protocol (SMB through dart_smb2, WebDAV and DLNA through
// plain HTTP, Plex through its pinned HTTPS client, the recordings of a Tapo camera). Implementations read on demand
// and never copy a whole file to the device, except the clips of a camera: it cannot serve a part of one, so a clip
// is fetched whole into the cache before it plays.

import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/network_source.dart';

/// Thrown by the file systems for anything the user may act on: wrong credentials, host unreachable, missing file.
class NetworkFileSystemException implements Exception {
  const NetworkFileSystemException(this.message, {this.isAuthentication = false, this.isNotFound = false});

  final String message;

  /// The server refused the credentials
  final bool isAuthentication;

  /// The path does not exist
  final bool isNotFound;

  @override
  String toString() => 'NetworkFileSystemException: $message';
}

/// A connected share. Paths are absolute inside the share, "/" separated, starting with "/".
abstract class NetworkFileSystem {
  NetworkSource get source;

  /// The entries of a folder, folders first then files, both sorted by name without case
  Future<List<NetworkEntry>> list(String path);

  /// Size and date of one entry
  Future<NetworkEntry> stat(String path);

  /// [length] bytes of a file from [offset]; fewer at the end of the file, none past it
  Future<Uint8List> readRange(String path, int offset, int length);

  /// Closes the connection; the object is not used again
  Future<void> close();
}

/// A share whose server makes small pictures of its media (a Plex server). The pictures are read in Dart with the
/// credentials of the share, so that no URL holding a credential reaches an image widget, whose errors print URLs.
abstract interface class NetworkThumbnailSource {
  /// A JPEG of [entry] about [size] pixels on its long side, null when the server has none
  Future<Uint8List?> thumbnail(NetworkEntry entry, int size);
}

/// A share that can be reached through an address outside home (a Plex server through its public address)
abstract interface class NetworkRemoteEndpoint {
  /// Whether the open connection goes through the address outside home (mobile data, another network)
  bool get isOutsideHome;
}

/// A share whose files may only be read from their start (a device that sends whole files, see DocumentTreeFileSystem):
/// a read near the end of a file reads all of it, so the browser does not look there for what a video declares
abstract interface class NetworkSequentialReads {
  /// Whether the files are known to be readable from their start only
  bool get readsFromStartOnly;
}

/// The order of [NetworkFileSystem.list]: folders first, then files, both by name without case (then with case, so
/// that two names differing by case only keep one order)
int compareNetworkEntries(NetworkEntry a, NetworkEntry b) {
  if (a.isDirectory != b.isDirectory) {
    return a.isDirectory ? -1 : 1;
  }
  final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
  return byName != 0 ? byName : a.name.compareTo(b.name);
}

/// Opens a [NetworkFileSystem] for a source with its password (null when none was stored)
typedef NetworkFileSystemOpener = Future<NetworkFileSystem> Function(NetworkSource source, String? password);

/// The local HTTP bridge that serves the files of the registered shares to the players of the app: an http URL on
/// this device (127.0.0.1, a random port, a random token in the path), with Range requests, so that the image
/// widgets, Media3, AVPlayer, the Spatial player and the Quest viewer stream straight from the share.
abstract class MediaBridge {
  /// Starts listening when needed; safe to call again
  Future<void> start();

  /// Makes the files of [fileSystem] reachable under its source id
  void register(NetworkFileSystem fileSystem);

  void unregister(String sourceId);

  /// The bridge URL of a file of a registered source, valid while the app runs; also of a file of generated media,
  /// with its id
  Uri urlFor(String sourceId, String path);

  /// Serves the files [media] makes in memory under [id] (random, never a source id), until [unregisterGenerated]:
  /// the live playlist of a camera on iPhone and iPad
  void registerGenerated(String id, GeneratedMedia media);

  void unregisterGenerated(String id);

  Future<void> stop();
}

/// Files the app makes in memory, or keeps on this device, that the bridge serves next to the shares
abstract class GeneratedMedia {
  /// The file [name] (one path segment), null when there is none (or no longer)
  GeneratedFile? file(String name);
}

/// Generated media that also takes small posts: the events the page of the splat viewer sends to the app
abstract class GeneratedMediaSink {
  /// The most bytes of a post; the bridge answers 413 to a larger one and hands nothing over
  static const maxPostBytes = 16 * 1024;

  /// The body of a POST to [name]; false when [name] takes no post (the bridge answers 404)
  bool received(String name, Uint8List body);
}

/// A sink that takes larger posts to some names: the poster of a splat scene saved from the splat viewer's page
abstract class GeneratedMediaLargePosts {
  /// The most bytes of a post to [name]
  int postLimit(String name);
}

class GeneratedFile {
  /// A file held in memory
  const GeneratedFile(Uint8List this.bytes, this.contentType, {this.headers = const {}}) : diskFile = null;

  /// A file of this device, read from disk at each request with the same ranges: a splat file of the computer, a
  /// file picked on a phone or a reduced copy in the cache, which the bridge never holds in memory
  const GeneratedFile.disk(File this.diskFile, this.contentType, {this.headers = const {}}) : bytes = null;

  final Uint8List? bytes;
  final File? diskFile;

  /// "application/vnd.apple.mpegurl", "video/mp4", "text/javascript; charset=utf-8"
  final String contentType;

  /// More headers of the answer: the Content-Security-Policy of a page, X-Content-Type-Options, a Cache-Control that
  /// replaces the bridge's no-cache
  final Map<String, String> headers;
}
