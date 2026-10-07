// What a network share looks like to the app, whatever its protocol (SMB through dart_smb2, WebDAV and DLNA through
// plain HTTP, Plex through its pinned HTTPS client, the recordings of a Tapo camera). Implementations read on demand
// and never copy a whole file to the device, except the clips of a camera: it cannot serve a part of one, so a clip
// is fetched whole into the cache before it plays.

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

  /// The bridge URL of a file of a registered source, valid while the app runs
  Uri urlFor(String sourceId, String path);

  Future<void> stop();
}
