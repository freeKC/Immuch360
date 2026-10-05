// What a network share looks like to the app, whatever its protocol (SMB through dart_smb2, WebDAV and DLNA through
// plain HTTP). Implementations read on demand and never copy a whole file to the device.

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
