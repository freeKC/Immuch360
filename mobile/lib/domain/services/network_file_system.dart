// What a network share looks like to the app, whatever its protocol (SMB through dart_smb2, WebDAV and DLNA through
// plain HTTP, Plex through its pinned HTTPS client, the recordings of a Tapo camera). Implementations read on demand
// and never copy a whole file to the device, except the clips of a camera: it cannot serve a part of one, so a clip
// is fetched whole into the cache before it plays.

import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/network_source.dart';

/// Thrown by the file systems for anything the user may act on: wrong credentials, host unreachable, missing file.
class NetworkFileSystemException implements Exception {
  const NetworkFileSystemException(
    this.message, {
    this.isAuthentication = false,
    this.isNotFound = false,
    this.isDownloadForbidden = false,
    this.isFileUnreadable = false,
  });

  final String message;

  /// The server refused the credentials
  final bool isAuthentication;

  /// The path does not exist
  final bool isNotFound;

  /// The server owner forbids this account to download files (Plex: "Allow Downloads" off for a shared user)
  final bool isDownloadForbidden;

  /// The server still lists the file but cannot read it now (Plex: 404 on the part of a film it knows, when the volume
  /// holding the films is not mounted): worth trying again later, unlike [isNotFound]
  final bool isFileUnreadable;

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

/// A share read over plain HTTP (WebDAV, a DLNA media server, Plex), whose server may answer a range request with the
/// whole file: reads still work then, each one transferring the file from its start up to the bytes asked for
abstract interface class NetworkRangeReads {
  /// Whether the server honours range requests: null until a read tells, false once it answered one with the whole
  /// file
  bool? get supportsRanges;
}

/// A share whose folders may hold live streams it does not list (the TV channels of a DLNA media server), so that the
/// browser tells why such a folder shows nothing instead of calling it empty
abstract interface class NetworkLiveStreams {
  /// The live streams of the folder at [path] in its last listing, 0 for a folder not listed yet
  int liveStreamsIn(String path);
}

/// A share whose server gives a whole file for a copy on this device (a Plex server, request 5 of the Plex films study:
/// "Download"), as a stream from an offset so that a copy cut short goes on where it stopped
abstract interface class NetworkFileDownloads {
  /// The file at [path] from byte [from] on. The server may start over from byte 0 when it does not honour the range
  /// ([NetworkDownloadStream.start] says where the bytes begin). [abort] stops the request and its body. Throws a
  /// [NetworkFileSystemException] when the server refuses (a Plex account without the right to download: its failure
  /// says so) or cannot be reached.
  Future<NetworkDownloadStream> openDownload(String path, {int from = 0, Future<void>? abort});
}

/// The answer of [NetworkFileDownloads.openDownload]
class NetworkDownloadStream {
  const NetworkDownloadStream({
    required this.start,
    required this.total,
    required this.identity,
    required this.bytes,
    this.fileName,
  });

  /// The offset of the first byte of [bytes]: the one asked, or 0 when the server sent the whole file
  final int start;

  /// The size of the whole file, null when the server does not tell it
  final int? total;

  /// What changes when the file on the server changes (for Plex the key of the part, which holds its change stamp): a
  /// copy started under another identity starts over
  final String identity;

  /// The name the server gives the file, null when it gives none
  final String? fileName;

  final Stream<List<int>> bytes;
}

/// Whether [error] says that the server owner forbids downloads to this account
bool isDownloadForbidden(Object error) => error is NetworkFileSystemException && error.isDownloadForbidden;

/// Whether [entry] of [fileSystem] reads at any position, as the motion track of a raw video needs (it sits at the end
/// of an Insta360 file, through a GoPro or a DJI file): its size is known (a file of a DLNA or Plex server that does
/// not tell it is streamed by the media bridge from its start, without ranges), the share does not send each file from
/// its start (see [NetworkSequentialReads]), and its server did not answer a range request with the whole file (see
/// [NetworkRangeReads]). Asked again at each call: a server tells whether it honours ranges at its first reads.
bool readsAnywhere(NetworkFileSystem? fileSystem, NetworkEntry entry) {
  final size = entry.size;
  if (size == null || size <= 0) {
    return false;
  }
  if (fileSystem case NetworkSequentialReads(readsFromStartOnly: true)) {
    return false;
  }
  if (fileSystem case NetworkRangeReads(supportsRanges: false)) {
    return false;
  }
  return true;
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

/// Generated media whose files are fetched when a player asks for them, from a server the app reads in Dart: the
/// playlist and the segments of a film the Plex server converts (PlexConversion). [GeneratedMedia.file] is not asked.
abstract class GeneratedMediaFetch implements GeneratedMedia {
  /// The file [name] (one path segment), null when there is none; throws when it could not be fetched
  Future<GeneratedFile?> fetch(String name);
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
