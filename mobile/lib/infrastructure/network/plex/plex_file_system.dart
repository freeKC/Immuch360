// The NetworkFileSystem of a Plex Media Server: its photo and video libraries as folders, read with the token over the
// pinned plex.direct connection (see plex_direct.dart), at home or through the address outside home.
//
// "/" lists the sections the app shows (photos, movies and other videos, shows), a folder each. Below a section come
// its folders as Plex shows them "by folder", and the files under their names on the server's disk; a photo section
// whose folder view does not answer shows its albums instead. The server only knows request keys and ids, which this
// file system maps paths to as it lists, like the DLNA one. Files are read with Range requests on their part, as they
// are on the disk, never through the transcoder of Plex, which would drop the 360° and 3D metadata the app reads. The
// thumbnails come from the photo transcoder of the server, read in Dart with the token (see NetworkThumbnailSource).
//
// The films of a movie library also have paths of their own, whatever lists them (plexFilmPath:
// /.films/{section}/{ratingKey}/{partId}/{name}), found through /library/metadata/{ratingKey} when this connection has
// not met them: the film page, a filtered list of films and the films page of lot A1 open the same file the same way.
// Next to the files, the film page and the players read what the server tells of a film (filmDetails, the filters of
// a library, the subtitle files beside a film) and write back the audio and subtitle track the user picks
// (selectStreams), the only write the app makes to a Plex server.
//
// Rule of every share client of the app: no URL of the server crosses a pigeon call to Kotlin or Swift, nor reaches an
// image widget. The players and viewers only ever get the http://127.0.0.1 URLs of the media bridge. Logs tell request
// kinds, statuses and timings, never the token, an address, a path or a title.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/network/entry_names.dart';
import 'package:immich_mobile/infrastructure/network/http_range_reader.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_direct.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_list.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_server_breaker.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_transcode.dart';
import 'package:immich_mobile/infrastructure/network/webdav_file_system.dart';
import 'package:immich_mobile/providers/network/plex_learned_addresses.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('PlexFileSystem');

/// A [NetworkFileSystem] over a Plex Media Server, see [open]
class PlexFileSystem
    implements
        NetworkFileSystem,
        NetworkThumbnailSource,
        NetworkRemoteEndpoint,
        NetworkRangeReads,
        NetworkAbortableReads,
        NetworkFileDownloads,
        PlexFilmsSource {
  PlexFileSystem._(
    this.source,
    this._hash,
    this._plex,
    this._ownsClient,
    this._local,
    this._public,
    this._pageSize,
    this._publicDelay,
    this._learned,
    this._breaker,
  );

  /// Picks the address that answers (see [_choose]), checks that the server there is the one of the source by its
  /// machine identifier, and lists the start folder (the root path of the source). Throws a
  /// [NetworkFileSystemException] when either fails, with isAuthentication when [token] is null or refused. Once open
  /// at home, the address outside home the server tells is kept for the next time away (see
  /// StoreKey.plexLearnedAddresses).
  ///
  /// [client] is used instead of the pinned client of the hash, and is then left open by [close]. In the tests,
  /// [baseOverride] and [publicBaseOverride] replace the addresses at home and outside home (plain http on loopback,
  /// no pinning). [clientIdentifier] defaults to the one of the install, [learned] to the Store.
  static Future<PlexFileSystem> open(
    NetworkSource source,
    String? token, {
    http.Client? client,
    @visibleForTesting Uri? baseOverride,
    @visibleForTesting Uri? publicBaseOverride,
    @visibleForTesting int pageSize = defaultPageSize,
    @visibleForTesting Duration publicDelay = publicStartDelay,
    String? clientIdentifier,
    PlexLearnedAddressStore? learned,
    @visibleForTesting PlexServerBreaker? breaker,
  }) async {
    if (source.type != NetworkSourceType.plex) {
      throw ArgumentError.value(source.type, 'source.type', 'Not a Plex source');
    }
    if (token == null || token.isEmpty) {
      throw const PlexFileSystemException('No token', PlexFailure.tokenRefused, isAuthentication: true);
    }
    final plex = source.plex;
    if (plex == null || !isPlexHash(plex.hash)) {
      throw const PlexFileSystemException('This Plex server has no certificate to check', PlexFailure.notPlex);
    }
    final hash = plex.hash;
    final testing = baseOverride != null || publicBaseOverride != null;
    final store = learned ?? (testing ? null : _defaultLearnedStore());

    _Candidate? local;
    _Candidate? public;
    if (testing) {
      local = baseOverride == null ? null : _Candidate(false, () async => baseOverride);
      public = publicBaseOverride == null ? null : _Candidate(true, () async => publicBaseOverride);
    } else {
      final host = source.host.trim();
      if (host.isNotEmpty) {
        local = _Candidate(false, () async => plexDirectUri(await _ipv4Of(host), source.port ?? plexDefaultPort, hash));
      }
      final outside = plexPublicAddress(plex, store?.read(source.id));
      if (outside != null) {
        public = _Candidate(true, () async => plexDirectUri(await _ipv4Of(outside.host), outside.port, hash));
      }
    }

    final http.Client httpClient;
    if (client != null) {
      httpClient = client;
    } else if (testing) {
      httpClient = IOClient(unpinnedPlexHttpClientForTests());
    } else {
      httpClient = IOClient(pinnedPlexHttpClient(hash));
    }
    final fileSystem = PlexFileSystem._(
      source,
      hash,
      PlexClient(
        httpClient,
        token: token,
        clientIdentifier: clientIdentifier ?? await plexClientIdentifier(),
        appVersion: await plexAppVersion(),
      ),
      client == null,
      local,
      public,
      pageSize,
      publicDelay,
      store,
      breaker ?? PlexServerBreakers.of(source.id),
    );
    final watch = Stopwatch()..start();
    try {
      await fileSystem._guard(() async {
        fileSystem._current = await fileSystem._choose();
        final root = normalizePath(source.rootPath);
        fileSystem._openListing = (
          root,
          await fileSystem._onServer(() => fileSystem._rewalkOnce((again) => fileSystem._browseFolder(root, again))),
        );
      });
    } catch (_) {
      await fileSystem.close();
      rethrow;
    }
    _log.info('Opened ${fileSystem.isOutsideHome ? 'outside home' : 'at home'} in ${watch.elapsedMilliseconds} ms');
    // The probes of the breaker go through the last connection opened to the server
    fileSystem._breaker.onProbe = fileSystem._probe;
    if (!fileSystem.isOutsideHome) {
      unawaited(fileSystem._refreshLearnedAddress());
    }
    return fileSystem;
  }

  @override
  final NetworkSource source;

  final String _hash;
  final PlexClient _plex;
  final bool _ownsClient;
  final _Candidate? _local;
  final _Candidate? _public;
  final int _pageSize;
  final Duration _publicDelay;
  final PlexLearnedAddressStore? _learned;

  /// The breaker of the server, shared with every connection to it (see plex_server_breaker.dart)
  final PlexServerBreaker _breaker;
  bool _closed = false;

  /// The address in use, from [open] on
  _Endpoint? _current;

  /// A new choice of the address under way, shared by the reads that failed together
  Future<void>? _choosing;

  /// The folders and files behind the paths listed so far, the root as the list of the sections
  final Map<String, _Node> _nodes = {'/': _Folder.root()};

  /// The sections listed so far, by key: kept when the keys are forgotten, a section key does not change at a rescan
  final Map<String, PlexSection> _sections = {};

  /// The entries of the paths listed so far, for [stat], with the sizes found by [stat] itself
  final Map<String, NetworkEntry> _entries = {};

  /// The listings of the folders, for looking a name up without asking the server again within [listingLifetime]
  final Map<String, ({List<NetworkEntry> entries, Duration at})> _listings = {};

  /// The listings under way, so that two callers wait for one
  final Map<String, Future<List<NetworkEntry>>> _browsing = {};

  /// The listing [open] made of the start folder, handed to the first [list] of it
  (String, List<NetworkEntry>)? _openListing;

  final Stopwatch _clock = Stopwatch()..start();

  /// The files whose size neither the listing nor the server tells, so that it is asked for once
  final Set<String> _unknownSizes = {};

  /// The folder keys that listed empty while their parent still gave them, by when: folders left empty, which are not
  /// checked against their parent again within [listingLifetime]
  final Map<String, Duration> _emptyKeys = {};

  /// How many times every key was forgotten (see [_rewalkOnce]), the calls walking again from the top, and what
  /// completes once none does
  int _generation = 0;
  int _walkingAgain = 0;
  Completer<void>? _walkedAgain;

  /// The reads of the files, keyed by part
  late final _ranges = HttpRangeReader(send: _sendRead, fail: _failRead, isClosed: () => _closed);

  /// Whether the server honours range requests on the parts of its media (see [HttpRangeReader.supportsRanges])
  @override
  bool? get supportsRanges => _ranges.supportsRanges;

  static const defaultPageSize = 200;

  /// Entries listed in one folder at most, as for DLNA; a folder that holds more shows the first ones
  static const maxEntriesPerFolder = 20000;
  static const listingLifetime = Duration(seconds: 60);

  /// How long the address at home has alone before the one outside home is tried too
  static const publicStartDelay = Duration(milliseconds: 400);

  /// Longest wait for the first bytes of a film ([waitForFirstBytes]): a server that just mounted its films again
  /// sent the first MiB of one in 74 s on 11 November 2026, while it read the middle of the same file at 14 Mbit/s
  static const filmStartTimeout = Duration(minutes: 3);

  /// What [waitForFirstBytes] reads: what a player reads first of a film
  static const filmStartBytes = 64 * 1024;

  /// Sizes of the pictures asked of the photo transcoder
  static const _minThumbnailSize = 16;
  static const _maxThumbnailSize = 2048;

  /// Whether the open connection goes through the address outside home
  @override
  bool get isOutsideHome => _current?.outsideHome ?? false;

  _Endpoint get _endpoint {
    final current = _current;
    if (current == null || _closed) {
      throw const NetworkFileSystemException('The share is closed');
    }
    return current;
  }

  /// [path] absolute, "/" separated, as for WebDAV
  static String normalizePath(String path) => WebDavFileSystem.normalizePath(path);

  static PlexLearnedAddressStore? _defaultLearnedStore() {
    try {
      return PlexLearnedAddressStore(StoreService.I);
    } on UnsupportedError {
      // The Store is not there (a background engine before its init): nothing learned, nothing kept
      return null;
    }
  }

  /// The IPv4 address of [host]: written in a plex.direct name, an address, or a name resolved (a DynDNS name typed for
  /// outside home)
  static Future<InternetAddress> _ipv4Of(String host) async {
    final named = parsePlexDirectHost(host.toLowerCase());
    if (named != null) {
      return named.address;
    }
    final address = InternetAddress.tryParse(host);
    if (address != null) {
      if (address.type != InternetAddressType.IPv4) {
        throw const PlexFileSystemException('IPv6 addresses are not supported yet', PlexFailure.failed);
      }
      return address;
    }
    final found = await InternetAddress.lookup(
      host,
      type: InternetAddressType.IPv4,
    ).timeout(const Duration(seconds: 8));
    if (found.isEmpty) {
      throw const SocketException('No IPv4 address');
    }
    return found.first;
  }

  @override
  Future<List<NetworkEntry>> list(String path) {
    final folder = normalizePath(path);
    final opened = _openListing;
    if (opened != null) {
      _openListing = null;
      if (opened.$1 == folder) {
        return Future.value(opened.$2);
      }
    }
    return _guard(() => _onServer(() => _rewalkOnce((again) => _browseFolder(folder, again))));
  }

  @override
  Future<NetworkEntry> stat(String path) {
    final target = normalizePath(path);
    if (target == '/') {
      return Future.value(NetworkEntry(sourceId: source.id, path: '/', isDirectory: true));
    }
    return _guard(
      () => _onServer(
        () => _rewalkOnce((again) async {
          var entry = _entries[target];
          if (entry == null) {
            await _meet(target, again);
            entry = _entries[target];
          }
          if (entry == null) {
            throw _notFound;
          }
          final node = _nodes[target];
          if (entry.isDirectory || entry.size != null || node is! _File) {
            return entry;
          }
          await _fileSize(target, node.file);
          // Still without a size when the server does not tell it: the bridge then streams the file without ranges
          return _entries[target] ?? entry;
        }),
      ),
    );
  }

  /// A read stopped by [abort] ends in [PlexRequestCancelled], which counts as no failure of the server (see
  /// NetworkAbortableReads)
  @override
  Future<Uint8List> readRange(String path, int offset, int asked, {Future<void>? abort}) {
    RangeError.checkNotNegative(offset, 'offset');
    RangeError.checkNotNegative(asked, 'length');
    final target = normalizePath(path);
    if (asked == 0) {
      return Future.value(Uint8List(0));
    }
    return _guard(
      () => _onServer(
        () => _rewalkOnce((again) async {
          final file = await _fileOf(target, again);
          // Some servers refuse a range that ends past the end of the file instead of giving what there is
          final size = await _fileSize(target, file);
          if (size != null && offset >= size) {
            return Uint8List(0);
          }
          final length = size == null ? asked : min(asked, size - offset);
          try {
            return await _ranges.read(
              _endpoint.base.resolve(file.partKey),
              'part:${file.partId ?? file.partKey}',
              offset,
              length,
              abort: abort,
            );
          } on NetworkReadAborted {
            throw const PlexRequestCancelled();
          } on PlexHttpStatus catch (error) {
            throw error.status == 404 || error.status == 410 ? const _PartGone() : error;
          }
        }),
      ),
    );
  }

  /// Waits for the first [length] bytes of the file at [path], [timeout] at most for the answer and then between two
  /// parts of it, before a player gets the film: a server that just mounted its films again takes over a minute to
  /// send them, where a player gives up after seconds. Stops when [cancel] completes (a [PlexRequestCancelled] then).
  /// Throws [plexFileUnreadable] when the server knows the film but cannot read its file, and what the user is told
  /// of any other failure.
  Future<void> waitForFirstBytes(
    String path, {
    int length = filmStartBytes,
    Duration timeout = filmStartTimeout,
    Future<void>? cancel,
  }) {
    final target = normalizePath(path);
    return _guard(
      () => _rewalkOnce((again) async {
        final file = await _fileOf(target, again);
        final response = await _plex.send(
          'GET',
          _endpoint.base.resolve(file.partKey),
          accept: '*/*',
          abort: cancel,
          timeout: timeout,
          headers: {'range': 'bytes=0-${length - 1}', 'accept-encoding': 'identity'},
        );
        final status = response.statusCode;
        if (status == 404 || status == 410) {
          await discardHttpBody(response);
          throw const _PartGone();
        }
        if (status == 416) {
          // An empty file: nothing to wait for
          await discardHttpBody(response);
          return;
        }
        if (status != 200 && status != 206) {
          await discardHttpBody(response);
          throw PlexHttpStatus(status);
        }
        await _readSome(response.stream, length, timeout, cancel);
      }),
    );
  }

  /// Reads [length] bytes of [body] at most, each part within [timeout], and stops the transfer; a
  /// [PlexRequestCancelled] once [cancel] completes
  static Future<void> _readSome(Stream<List<int>> body, int length, Duration timeout, Future<void>? cancel) async {
    final done = Completer<void>();
    var received = 0;
    Timer? timer;
    late final StreamSubscription<List<int>> subscription;
    void finish([Object? error]) {
      timer?.cancel();
      if (done.isCompleted) {
        return;
      }
      if (error == null) {
        done.complete();
      } else {
        done.completeError(error);
      }
    }

    void arm() {
      timer?.cancel();
      timer = Timer(timeout, () => finish(TimeoutException('No bytes in time', timeout)));
    }

    subscription = body.listen(
      (chunk) {
        received += chunk.length;
        if (received >= length) {
          finish();
        } else {
          arm();
        }
      },
      onError: (Object error) => finish(error),
      onDone: finish,
      cancelOnError: true,
    );
    arm();
    unawaited(cancel?.whenComplete(() => finish(const PlexRequestCancelled())));
    try {
      await done.future;
    } finally {
      // Stops the transfer: the player asks for the film itself
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
  }

  /// The part of the file at [path] for a copy on this device: `GET {Part.key}?download=1` with the token in its header,
  /// from [from] with a Range header. With download=1 the server gives the original file at a fair share of the
  /// bandwidth its playbacks leave, and answers 403 to an account whose owner forbids downloads, which a plain read of
  /// the part would get round: the copy asks it that way so that the owner's choice holds. The identity of the copy is
  /// the key of the part, which holds its change stamp, and the size the listing gave: a file replaced on the server
  /// starts the copy over.
  @override
  Future<NetworkDownloadStream> openDownload(String path, {int from = 0, Future<void>? abort}) {
    RangeError.checkNotNegative(from, 'from');
    final target = normalizePath(path);
    return _guard(
      () => _onServer(
        () => _rewalkOnce((again) async {
          final file = await _fileOf(target, again);
          final part = _endpoint.base.resolve(file.partKey);
          final uri = part.replace(queryParameters: {...part.queryParameters, 'download': '1'});
          final response = await _plex.send(
            'GET',
            uri,
            accept: '*/*',
            abort: abort,
            headers: {'accept-encoding': 'identity', if (from > 0) 'range': 'bytes=$from-'},
          );
          final status = response.statusCode;
          final identity = plexDownloadIdentity(file);
          if (status == 416) {
            // Nothing left after [from]: the copy holds the whole file, or the file got shorter (its identity tells)
            await discardHttpBody(response);
            final total = int.tryParse(
              RegExp(r'/\s*(\d+)\s*$').firstMatch(response.headers['content-range'] ?? '')?.group(1) ?? '',
            );
            return NetworkDownloadStream(
              start: from,
              total: total ?? file.size,
              identity: identity,
              fileName: file.fileName,
              bytes: const Stream.empty(),
            );
          }
          if (status == 404 || status == 410) {
            await discardHttpBody(response);
            throw const _PartGone();
          }
          if (status == 403) {
            await discardHttpBody(response);
            throw _downloadForbidden;
          }
          if (status != 200 && status != 206) {
            await discardHttpBody(response);
            throw PlexHttpStatus(status);
          }
          final range = status == 206 ? parseContentRange(response.headers['content-range']) : null;
          if (status == 206 && range == null) {
            await discardHttpBody(response);
            throw const PlexFileSystemException('The Plex server sent a part it did not name', PlexFailure.failed);
          }
          return NetworkDownloadStream(
            start: range?.start ?? 0,
            total: range?.total ?? response.contentLength ?? file.size,
            identity: identity,
            fileName: file.fileName,
            bytes: response.stream,
          );
        }),
      ),
    );
  }

  /// The folder of the items asked by their rating key ([pathOfItem]): no section is named so, its dot keeps it out
  /// of the names Plex gives
  static const itemFolder = '/.item';

  /// The path of the item [ratingKey] of the server, its first part, under [itemFolder]
  /// (`/.item/<ratingKey>/<file name>`), which the media bridge, the players and the watch records then take like any
  /// other: a film a phone asked this screen to play ("Play on the TV"). Found again by its key when the connection
  /// forgot it. Not found when the server has no such item, or one without a file.
  Future<String> pathOfItem(String ratingKey) {
    if (!RegExp(r'^[0-9]{1,12}$').hasMatch(ratingKey)) {
      return Future.error(_notFound);
    }
    return _guard(() => _onServer(() => _resolveItem(ratingKey)));
  }

  /// The rating key of the file at [path], when this connection listed it: what a phone sends a screen to play
  String? ratingKeyOf(String path) {
    final node = _nodes[normalizePath(path)];
    return node is _File ? node.file.ratingKey : null;
  }

  Future<String> _resolveItem(String ratingKey) async {
    final PlexListingPage page;
    try {
      page = await _plex.getJson(
        _endpoint.base.resolve('/library/metadata/${Uri.encodeComponent(ratingKey)}'),
        parsePlexListing,
      );
    } on PlexHttpStatus catch (error) {
      throw error.status == 404 || error.status == 400 ? _notFound : error;
    }
    final file = page.items.whereType<PlexFileItem>().firstOrNull;
    if (file == null) {
      throw _notFound;
    }
    final path = '$itemFolder/$ratingKey/${file.fileName.replaceAll('/', '_')}';
    _nodes[path] = _File(file, null);
    final known = _entries[path];
    _entries[path] = NetworkEntry(
      sourceId: source.id,
      path: path,
      isDirectory: false,
      size: file.size ?? (known?.isDirectory == false ? known?.size : null),
      modified: file.addedAt,
      mimeType: file.mimeType,
      width: file.width,
      height: file.height,
      durationMs: file.durationMs,
      // A film's title for the screen's player, as the films of a film library have (lot A1)
      title: file.isPoster ? file.title : null,
    );
    return path;
  }

  /// The rating key of a path under [itemFolder], null for any other path
  static String? _itemKeyOf(String path) {
    final match = RegExp(r'^/\.item/([0-9]{1,12})/[^/]+$').firstMatch(path);
    return match?.group(1);
  }

  /// The picture the photo transcoder of the server makes of [entry], about [size] pixels on its long side; null when
  /// the entry has none (a folder, a path not listed by this connection) or the server answers 404
  @override
  Future<Uint8List?> thumbnail(NetworkEntry entry, int size) {
    final node = _nodes[normalizePath(entry.path)];
    final file = node is _File ? node.file : null;
    final thumb = file?.thumb;
    if (file == null || thumb == null) {
      return Future.value(null);
    }
    final side = size.clamp(_minThumbnailSize, _maxThumbnailSize);
    // A film's poster is 2:3: asked at that shape, [size] being its height, rather than as a square that is cropped.
    // The films of a film library only, which have their title: the frames of "Other videos" stay square.
    final poster = file.isPoster && _entries[normalizePath(entry.path)]?.title != null;
    final width = poster ? max(_minThumbnailSize, (side * 2 / 3).round()) : side;
    return _guard(
      () => _onServer(() {
        final uri = _endpoint.base
            .resolve('/photo/:/transcode')
            .replace(
              queryParameters: {'width': '$width', 'height': '$side', 'minSize': '1', 'upscale': '0', 'url': thumb},
            );
        return _plex.getBytes(uri);
      }),
    );
  }

  /// The Plex item behind [path]: its ratingKey, its file and its library, from what this connection listed or from a
  /// path of [plexFilmPath]; null for a folder, a path not met yet that is no film path, or a file without ratingKey
  PlexItemRef? itemAt(String path) {
    final target = normalizePath(path);
    final node = _nodes[target];
    if (node is _File) {
      final ratingKey = node.file.ratingKey;
      return ratingKey == null
          ? null
          : PlexItemRef(ratingKey: ratingKey, partId: node.file.partId, section: node.section, path: target);
    }
    final film = parsePlexFilmPath(target);
    return film == null
        ? null
        : PlexItemRef(
            ratingKey: film.ratingKey,
            partId: film.partId,
            section: _sections[film.sectionKey],
            path: target,
          );
  }

  /// The library whose folder is at [path] (a folder of the root), null for any other path
  PlexSection? sectionAt(String path) {
    final node = _nodes[normalizePath(path)];
    return node is _Folder && !node.isRoot && !node.belowSection ? node.section : null;
  }

  /// The section of [key] once listed, null before
  PlexSection? sectionOf(String key) => _sections[key];

  /// The folder of the library [sectionKey] at the root of the share, where its folder view starts ("Show the folders"
  /// of the film page); the root is listed first when this connection has not listed it. Null for a library the server
  /// no longer lists.
  Future<String?> sectionFolder(String sectionKey) async {
    String? known() {
      for (final MapEntry(key: path, value: node) in _nodes.entries) {
        if (node is _Folder && !node.isRoot && !node.belowSection && node.section?.key == sectionKey) {
          return path;
        }
      }
      return null;
    }

    final found = known();
    if (found != null) {
      return found;
    }
    await list('/');
    return known();
  }

  /// Where "Show the folders" of the film page goes for the file [path] of a film of the library [sectionKey]: the
  /// folder the file was listed in, or, for a path of [plexFilmPath], the folder of its library; null when neither is
  /// known
  Future<String?> folderOfFilm(String? path, String? sectionKey) async {
    if (path != null && parsePlexFilmPath(path) == null) {
      return _parentOf(normalizePath(path));
    }
    return sectionKey == null ? null : sectionFolder(sectionKey);
  }

  /// The full item of the film [ratingKey] (/library/metadata/{ratingKey}?includeGuids=1): its texts, people, ids and
  /// the streams of its files. Not found once the server no longer has it.
  Future<PlexFilmDetails> filmDetails(String ratingKey) => _guard(() => _onServer(() => _detailsOf(ratingKey)));

  /// Largest segment of a conversion read (a few seconds of a 20 Mbit/s stream is under 20 MB)
  static const maxConversionSegment = 64 * 1024 * 1024;

  /// The server's conversion of the film at [path] (plex_transcode.dart): the decision is asked first, and null comes
  /// back when the server says it cannot convert the film (its answer goes to the log). [mediaIndex] and [partIndex]
  /// are the places of the file among the versions and files of the film (plexPartPlace); [maxVideoBitrateKbps] caps the
  /// video, lower than the default for a link slower than the file.
  Future<PlexConversion?> conversionOf(
    String path, {
    int mediaIndex = 0,
    int partIndex = 0,
    Duration offset = Duration.zero,
    List<String> audioCodecs = const ['eac3', 'ac3'],
    int maxVideoBitrateKbps = PlexTranscodeRequest.defaultMaxVideoBitrateKbps,
  }) => _guard(
    () => _onServer(() async {
      final item = itemAt(path);
      if (item == null) {
        throw const _Stale();
      }
      final request = PlexTranscodeRequest(
        ratingKey: item.ratingKey,
        session: newPlexTranscodeSession(),
        mediaIndex: mediaIndex,
        partIndex: partIndex,
        offset: offset,
        audioCodecs: audioCodecs,
        maxVideoBitrateKbps: maxVideoBitrateKbps,
      );
      final base = _endpoint.base;
      final decision = await _plex.getJson(
        request.decisionUri(base),
        parsePlexTranscodeDecision,
        headers: request.headers,
      );
      _log.info(decision.logLine);
      if (!decision.canConvert) {
        return null;
      }
      return PlexConversion(
        request: request,
        base: base,
        fetch: (uri, headers) async {
          final bytes = await _plex.getBytes(uri, accept: '*/*', maxSize: maxConversionSegment, headers: headers);
          if (bytes == null) {
            throw const NetworkFileSystemException('The conversion is gone from the server');
          }
          return bytes;
        },
      );
    }),
  );

  Future<PlexFilmDetails> _detailsOf(String ratingKey) async {
    final uri = _endpoint.base
        .resolve('/library/metadata/${Uri.encodeComponent(ratingKey)}')
        .replace(queryParameters: const {'includeGuids': '1'});
    final PlexFilmDetails? details;
    try {
      details = await _plex.getJson(uri, parsePlexFilmDetails);
    } on PlexHttpStatus catch (error) {
      throw error.status == 404 || error.status == 410 ? const _Stale() : error;
    }
    if (details == null) {
      throw const _Stale();
    }
    final section = details.sectionKey;
    if (section != null && !_sections.containsKey(section)) {
      // The film page may open before the root was listed (a film of the films page of lot A1)
      unawaited(_learnSections());
    }
    return details;
  }

  /// Lists the sections once, for a film met by its path before the root: their agent and language
  Future<void> _learnSections() async {
    try {
      final sections = await _plex.getJson(_endpoint.base.resolve('/library/sections'), parsePlexSections);
      for (final section in sections) {
        _sections[section.key] = section;
      }
    } catch (error) {
      _log.fine('The sections could not be read: ${plexErrorKind(error)}');
    }
  }

  /// One page of the films of the library [sectionKey] that [query] keeps, each with the path of [plexFilmPath] of its
  /// first file, recorded so that its tile, its page and the players open it at once
  Future<PlexFilmsResult> films(String sectionKey, PlexFilmsQuery query, {int start = 0, int size = defaultPageSize}) =>
      _guard(
        () => _onServer(() async {
          final uri = _endpoint.base
              .resolve('/library/sections/${Uri.encodeComponent(sectionKey)}/all')
              .replace(queryParameters: query.toQueryParameters());
          final PlexFilmsPage page;
          try {
            page = await _plex.getJson(
              uri,
              parsePlexFilmsPage,
              headers: {'x-plex-container-start': '$start', 'x-plex-container-size': '$size'},
            );
          } on PlexHttpStatus catch (error) {
            throw error.status == 404 || error.status == 410 ? const _Stale() : error;
          }
          final section = _sections[sectionKey];
          final entries = <NetworkEntry>[];
          for (final item in page.items) {
            final path = plexFilmPath(
              sectionKey: sectionKey,
              ratingKey: item.ratingKey,
              partId: item.partId,
              name: item.fileName,
            );
            entries.add(_recordFilm(path, _fileItemOf(item), section));
          }
          return PlexFilmsResult(entries: entries, items: page.items, count: page.count, totalSize: page.totalSize);
        }),
      );

  /// Every film of [sectionKey] that [query] keeps, [max] at most, page after page
  Future<List<({NetworkEntry entry, PlexFilmItem item})>> allFilms(
    String sectionKey,
    PlexFilmsQuery query, {
    int max = maxEntriesPerFolder,
  }) async {
    final found = <({NetworkEntry entry, PlexFilmItem item})>[];
    var start = 0;
    while (found.length < max) {
      final page = await films(sectionKey, query, start: start, size: _pageSize);
      for (final (index, entry) in page.entries.indexed) {
        found.add((entry: entry, item: page.items[index]));
      }
      if (page.count <= 0) {
        break;
      }
      start += page.count;
      final total = page.totalSize;
      if (total == null ? page.count < _pageSize : start >= total) {
        break;
      }
    }
    return found.length > max ? found.sublist(0, max) : found;
  }

  /// The filters the library [sectionKey] offers (/library/sections/{key}/filters)
  Future<List<PlexSectionFilter>> sectionFilters(String sectionKey) => _guard(
    () => _onServer(
      () => _plex.getJson(
        _endpoint.base.resolve('/library/sections/${Uri.encodeComponent(sectionKey)}/filters'),
        parsePlexSectionFilters,
      ),
    ),
  );

  /// The values of [filter] of the library [sectionKey], from its key as the server gave it
  Future<List<PlexFilterChoice>> filterChoices(String sectionKey, PlexSectionFilter filter) => _guard(
    () => _onServer(() {
      final key = _keyBase.resolve('/library/sections/${Uri.encodeComponent(sectionKey)}/').resolve(filter.key);
      return _plex.getJson(
        _endpoint.base.resolve(key.hasQuery ? '${key.path}?${key.query}' : key.path),
        parsePlexFilterChoices,
      );
    }),
  );

  /// A picture of the server ([serverPath], the thumb or art of an item) through its photo transcoder, [width] by
  /// [height] at most; null for an address outside the server (the pictures of the cast on Plex's own servers, which
  /// the device never loads) or a 404
  Future<Uint8List?> picture(String serverPath, {required int width, required int height}) {
    if (!serverPath.startsWith('/')) {
      return Future.value(null);
    }
    final w = width.clamp(_minThumbnailSize, _maxThumbnailSize);
    final h = height.clamp(_minThumbnailSize, _maxThumbnailSize);
    return _guard(
      () => _onServer(() {
        final uri = _endpoint.base
            .resolve('/photo/:/transcode')
            .replace(
              queryParameters: {'width': '$w', 'height': '$h', 'minSize': '1', 'upscale': '0', 'url': serverPath},
            );
        return _plex.getBytes(uri);
      }),
    );
  }

  /// The subtitle file [stream] beside a film, as it is on the server's disk, in UTF-8 (GET /library/streams/{id}, its
  /// key, with encoding=utf-8); null when the server has no such file. Small: [maxSubtitleSize] at most.
  ///
  /// Read on a Plex Media Server 1.42.1 (11 November 2026, 26 side files): format=srt converts nothing, a path with an
  /// extension other than the stream's codec answers 404 (a .srt path for a file Plex calls WebVTT), and
  /// encoding=utf-8 turns a Latin-1 file into UTF-8 and leaves a UTF-8 one as it is. The text's own format is read by
  /// subtitleTextFormatOf: a file Plex calls WebVTT from its name may hold SubRip or ASS text.
  Future<Uint8List?> subtitleFile(PlexStream stream) {
    if (!stream.isSidecar || !stream.isTextSubtitle) {
      return Future.value(null);
    }
    return _guard(
      () => _onServer(() {
        final uri = _endpoint.base
            .resolve('/library/streams/${stream.id}')
            .replace(queryParameters: const {'encoding': 'utf-8'});
        return _plex.getBytes(uri, accept: '*/*', maxSize: maxSubtitleSize);
      }),
    );
  }

  /// Largest subtitle file read
  static const maxSubtitleSize = 4 * 1024 * 1024;

  /// Tells the server which audio track and which subtitles the account picked for the part [partId] (PUT
  /// /library/parts/{id} with allParts=1): Plex's own apps start with the same choice. [subtitleStreamId] 0 turns the
  /// subtitles off; a null one is left as it is.
  Future<void> selectStreams(int partId, {int? audioStreamId, int? subtitleStreamId}) {
    if (audioStreamId == null && subtitleStreamId == null) {
      return Future.value();
    }
    return _guard(
      () => _onServer(() async {
        final uri = _endpoint.base
            .resolve('/library/parts/$partId')
            .replace(
              queryParameters: {
                'audioStreamID': ?audioStreamId?.toString(),
                'subtitleStreamID': ?subtitleStreamId?.toString(),
                'allParts': '1',
              },
            );
        final response = await _plex.send('PUT', uri);
        await discardHttpBody(response);
        if (response.statusCode != 200 && response.statusCode != 204) {
          throw PlexHttpStatus(response.statusCode);
        }
      }),
    );
  }

  /// Makes [path] known to this connection when it was not listed: a path of [plexFilmPath] through the item of its
  /// film, a path of [pathOfItem] through its rating key, any other through the listing of its parent
  Future<void> _meet(String path, bool again) async {
    final itemKey = _itemKeyOf(path);
    if (itemKey != null) {
      await _resolveItem(itemKey);
      return;
    }
    final film = parsePlexFilmPath(path);
    if (film == null) {
      await _listingOf(_parentOf(path), again);
      return;
    }
    final details = await _detailsOf(film.ratingKey);
    final part = details.parts.where((part) => part.id == film.partId).firstOrNull;
    if (part == null) {
      // The film has other files now: the path is not there any more
      throw const _Stale();
    }
    final media = details.mediaOf(part);
    final added = _entries[path]?.modified;
    final item = PlexFileItem(
      partKey: part.key,
      fileName: part.fileName ?? path.split('/').last,
      partId: part.id,
      size: part.size,
      addedAt: added,
      mimeType: plexMimeTypeOf(part.container),
      width: media?.width,
      height: media?.height,
      durationMs: part.durationMs ?? details.durationMs,
      thumb: details.thumb,
      ratingKey: details.ratingKey,
      title: details.title,
      year: details.year,
      isPoster: true,
    );
    _recordFilm(path, item, details.sectionKey == null ? null : _sections[details.sectionKey]);
  }

  NetworkEntry _recordFilm(String path, PlexFileItem item, PlexSection? section) {
    _nodes[path] = _File(item, section);
    final known = _entries[path];
    final entry = NetworkEntry(
      sourceId: source.id,
      path: path,
      isDirectory: false,
      size: item.size ?? known?.size,
      modified: item.addedAt ?? known?.modified,
      mimeType: item.mimeType,
      width: item.width,
      height: item.height,
      durationMs: item.durationMs,
      title: item.title,
    );
    _entries[path] = entry;
    return entry;
  }

  static PlexFileItem _fileItemOf(PlexFilmItem film) => PlexFileItem(
    partKey: film.partKey,
    fileName: film.fileName,
    partId: film.partId,
    size: film.size,
    addedAt: film.addedAt,
    mimeType: film.mimeType,
    width: film.width,
    height: film.height,
    durationMs: film.durationMs,
    thumb: film.thumb,
    ratingKey: film.ratingKey,
    title: film.title,
    year: film.year,
    isPoster: true,
  );

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    if (_breaker.onProbe == _probe) {
      _breaker.onProbe = null;
    }
    await _ranges.close();
    if (_ownsClient) {
      _plex.close();
    }
  }

  /// The address that answers first with the machine identifier of the source: the one at home, then the one outside
  /// home [_publicDelay] later or as soon as the one at home fails. The other request is stopped once one wins. A server
  /// with another machine identifier behind the right certificate is refused.
  Future<_Endpoint> _choose() async {
    final local = _local;
    final public = _public;
    if (local == null && public == null) {
      throw const PlexFileSystemException('This Plex server has no address', PlexFailure.unreachable);
    }
    final won = Completer<_Endpoint>();
    final stop = Completer<void>();
    final errors = <(_Candidate, Object)>[];
    var running = 0;

    Future<void> attempt(_Candidate candidate) async {
      running++;
      final watch = Stopwatch()..start();
      try {
        final base = await candidate.base();
        if (won.isCompleted) {
          return;
        }
        final identity = await _plex.getJson(
          base.resolve('/identity'),
          parsePlexIdentity,
          withToken: false,
          abort: stop.future,
        );
        if (identity == null) {
          throw const FormatException('No identity');
        }
        final expected = source.discoveryId?.toLowerCase();
        if (expected != null && identity.machineIdentifier.toLowerCase() != expected) {
          throw const PlexFileSystemException('Another Plex server answers at this address', PlexFailure.otherServer);
        }
        if (!won.isCompleted) {
          _log.fine('${candidate.label} answered in ${watch.elapsedMilliseconds} ms');
          won.complete(_Endpoint(base, candidate.outsideHome));
        }
      } catch (error) {
        if (!won.isCompleted) {
          _log.fine('${candidate.label} failed after ${watch.elapsedMilliseconds} ms: ${plexErrorKind(error)}');
          errors.add((candidate, error));
        }
      } finally {
        running--;
      }
    }

    var publicStarted = false;
    Timer? delay;

    // Called once each attempt ended: when none is left and none won, the choice failed
    void settle() {
      if (running == 0 && !won.isCompleted && (public == null || publicStarted)) {
        won.completeError(_choiceError(errors));
      }
    }

    void startPublic() {
      delay?.cancel();
      if (public == null || publicStarted || won.isCompleted) {
        return;
      }
      publicStarted = true;
      unawaited(attempt(public).whenComplete(settle));
    }

    if (local == null) {
      startPublic();
    } else {
      if (public != null) {
        delay = Timer(_publicDelay, startPublic);
      }
      unawaited(
        attempt(local).whenComplete(() {
          startPublic();
          settle();
        }),
      );
    }
    try {
      return await won.future;
    } finally {
      delay?.cancel();
      if (!stop.isCompleted) {
        stop.complete();
      }
    }
  }

  /// What to tell when no address answered: another server first; a server that answered in this run stopped
  /// answering; else what the address outside home said (at home the address at home would have answered), else what
  /// the one at home said
  NetworkFileSystemException _choiceError(List<(_Candidate, Object)> errors) {
    for (final (_, error) in errors) {
      if (error is PlexFileSystemException && error.failure == PlexFailure.otherServer) {
        return error;
      }
    }
    // A server that answered in this run stopped, wherever the phone is: on 11 November 2026 one that stopped at home
    // was told as one to reach from outside home
    final reached = _breaker.everReached;
    final outside = errors.where((e) => e.$1.outsideHome).firstOrNull;
    if (outside != null) {
      return plexErrorOf(outside.$2, outsideHome: true, reachedBefore: reached, sourceId: source.id);
    }
    return errors.isEmpty
        ? const PlexFileSystemException('The Plex server does not answer', PlexFailure.unreachable)
        : plexErrorOf(errors.first.$2, reachedBefore: reached, sourceId: source.id);
  }

  /// Runs [action], and once more after a new choice of the address when the network failed under it (the phone left
  /// the Wi-Fi, or came home); a second failure goes to the caller
  Future<T> _onServer<T>(Future<T> Function() action) async {
    final used = _endpoint;
    try {
      return await action();
    } catch (error) {
      if (_closed || !isPlexNetworkFailure(error)) {
        rethrow;
      }
      _log.info('${used.label} stopped answering (${plexErrorKind(error)}): choosing the address again');
      await _chooseAgain(used);
      return action();
    }
  }

  Future<void> _chooseAgain(_Endpoint failed) async {
    if (!identical(_current, failed)) {
      // Another call chose again meanwhile
      return;
    }
    final choosing = _choosing ??= () async {
      try {
        final chosen = await _choose();
        if (!_closed) {
          _current = chosen;
          _log.info('Going on ${chosen.label}');
        }
      } finally {
        _choosing = null;
      }
    }();
    await choosing;
  }

  /// Keeps what the server tells of its address outside home, for the next connection away from home. Never fails:
  /// the connection works without it.
  Future<void> _refreshLearnedAddress() async {
    final store = _learned;
    final current = _current;
    if (store == null || current == null || current.outsideHome) {
      return;
    }
    try {
      final told = await _plex.learnPublicAddress(current.base, _hash);
      if (told == null || _closed) {
        return;
      }
      final known = store.read(source.id);
      if (known != null &&
          known.host == told.host &&
          known.port == told.port &&
          known.mapping == told.mapping &&
          told.at.difference(known.at) < const Duration(days: 1)) {
        return;
      }
      await store.write(source.id, told);
      _log.fine('The server told its address outside home');
    } catch (error) {
      _log.fine('The address outside home could not be kept: ${plexErrorKind(error)}');
    }
  }

  /// The file at [path], from the listing of its parent when it was not met yet
  Future<PlexFileItem> _fileOf(String path, bool again) async {
    var node = _nodes[path];
    if (node == null) {
      await _meet(path, again);
      node = _nodes[path];
    }
    if (node == null) {
      throw _notFound;
    }
    if (node is! _File) {
      throw const PlexFileSystemException('This is a folder, not a file', PlexFailure.failed);
    }
    return node.file;
  }

  /// The folder at [path], from the listing of its parent when it was not met yet
  Future<_Folder> _folderOf(String path, bool again) async {
    var node = _nodes[path];
    if (node == null) {
      await _listingOf(_parentOf(path), again);
      node = _nodes[path];
    }
    if (node == null) {
      throw _notFound;
    }
    if (node is! _Folder) {
      throw const PlexFileSystemException('This is a file, not a folder', PlexFailure.failed);
    }
    return node;
  }

  /// The listing of [folder] made within [listingLifetime], else a new one
  Future<List<NetworkEntry>> _listingOf(String folder, bool again) async {
    final listing = _listings[folder];
    if (listing != null && _clock.elapsed - listing.at < listingLifetime) {
      return listing.entries;
    }
    return _browseFolder(folder, again);
  }

  /// Lists every page of [folder] and records its entries. On the first walk ([again] false), a folder below a section
  /// that lists empty is checked against a new listing of its parent: Plex answers a folder key it no longer knows with
  /// an empty listing rather than an error, and it lists folders left empty too (see [_folderAfterEmpty]).
  Future<List<NetworkEntry>> _browseFolder(String folder, bool again) {
    final running = _browsing[folder];
    if (running != null) {
      return running;
    }
    late final Future<List<NetworkEntry>> browsing;
    browsing = () async {
      try {
        final node = await _folderOf(folder, again);
        final watch = Stopwatch()..start();
        final List<NetworkEntry> entries;
        if (node.isRoot) {
          entries = await _listSections();
        } else {
          var listed = node;
          var items = await _listItems(listed);
          if (items.isEmpty && listed.belowSection && !again && !_isKnownEmpty(listed.key)) {
            listed = await _folderAfterEmpty(folder, listed);
            if (listed.key != node.key) {
              items = await _listItems(listed);
            }
          }
          if (items.isEmpty && listed.belowSection) {
            _emptyKeys[listed.key] = _clock.elapsed;
          }
          entries = _record(folder, listed, items);
        }
        entries.sort(compareNetworkEntries);
        final listed = List<NetworkEntry>.unmodifiable(entries);
        _listings[folder] = (entries: listed, at: _clock.elapsed);
        _log.fine('list: ${listed.length} entries in ${watch.elapsedMilliseconds} ms');
        return listed;
      } finally {
        // The next listing of the folder asks the server again
        if (identical(_browsing[folder], browsing)) {
          // Its callers have it, errors included
          _browsing.remove(folder)?.ignore();
        }
      }
    }();
    _browsing[folder] = browsing;
    return browsing;
  }

  /// The folder at [folder] as a new listing of its parent gives it, once its key [node] listed empty: the same key for a
  /// folder left empty, another one after a rescan. Not found when the parent no longer has it. One request (a page of
  /// the parent), where forgetting every key would walk again from the root and drop the thumbnails shown meanwhile.
  Future<_Folder> _folderAfterEmpty(String folder, _Folder node) async {
    final siblings = await _browseFolder(_parentOf(folder), false);
    final current = _nodes[folder];
    if (current is! _Folder || !siblings.any((entry) => entry.path == folder)) {
      throw _notFound;
    }
    return current;
  }

  bool _isKnownEmpty(String key) {
    final at = _emptyKeys[key];
    return at != null && _clock.elapsed - at < listingLifetime;
  }

  /// The sections the app shows, a folder each, at the root
  Future<List<NetworkEntry>> _listSections() async {
    final sections = await _plex.getJson(_endpoint.base.resolve('/library/sections'), parsePlexSections);
    final entries = <NetworkEntry>[];
    for (final (:item, :name) in plexSectionEntryNames(sections)) {
      _sections[item.key] = item;
      final path = '/$name';
      final known = _nodes[path];
      // A section that switched to its albums stays so
      _nodes[path] = known is _Folder && known.section?.key == item.key
          ? known
          : _Folder(key: '/library/sections/${Uri.encodeComponent(item.key)}/folder', section: item);
      final entry = NetworkEntry(sourceId: source.id, path: path, isDirectory: true);
      _entries[path] = entry;
      entries.add(entry);
    }
    return entries;
  }

  /// Every item of the folder [node], the folder view of a section falling back to its albums for photos
  Future<List<PlexListItem>> _listItems(_Folder node) async {
    final section = node.section;
    try {
      return await _listAll(node.key);
    } on PlexHttpStatus catch (error) {
      final missing = error.status == 404 || error.status == 410;
      if (section != null && section.isPhoto && !node.albums && (missing || error.status == 400)) {
        _log.info('The folder view of a photo section did not answer (HTTP ${error.status}): showing its albums');
        node
          ..key = '/library/sections/${Uri.encodeComponent(section.key)}/all'
          ..albums = true;
        return _listAll(node.key);
      }
      // A key that a rescan changed, or a section removed: the walk from the root finds out
      throw missing ? const _Stale() : error;
    }
  }

  /// Every page of the listing at [key], [maxEntriesPerFolder] elements at most
  Future<List<PlexListItem>> _listAll(String key) async {
    final items = <PlexListItem>[];
    var start = 0;
    while (true) {
      final page = await _plex.getJson(
        _endpoint.base.resolve(key),
        parsePlexListing,
        headers: {'x-plex-container-start': '$start', 'x-plex-container-size': '$_pageSize'},
      );
      items.addAll(page.items.map((item) => _resolved(item, key)));
      final count = page.count;
      if (count <= 0) {
        break;
      }
      start += count;
      final total = page.totalSize;
      final more = total == null ? count >= _pageSize : start < total;
      if (!more) {
        break;
      }
      if (start >= maxEntriesPerFolder) {
        _log.warning('A Plex folder holds more than $maxEntriesPerFolder entries; the first ones only are listed');
        break;
      }
    }
    return items;
  }

  /// [item] with its folder key made absolute: relative to the listing [key] it came from
  static PlexListItem _resolved(PlexListItem item, String key) {
    if (item is! PlexFolderItem || item.key.startsWith('/')) {
      return item;
    }
    final resolved = _keyBase.resolve(key).resolve(item.key);
    return PlexFolderItem(
      key: resolved.hasQuery ? '${resolved.path}?${resolved.query}' : resolved.path,
      title: item.title,
    );
  }

  static final _keyBase = Uri.parse('https://plex.invalid');

  /// Records the [items] of [folder] under unique names, and gives their entries
  List<NetworkEntry> _record(String folder, _Folder parent, List<PlexListItem> items) {
    final entries = <NetworkEntry>[];
    for (final (:item, :name) in uniqueEntryNames(items, (item) => item.name, (item) => item is PlexFolderItem)) {
      final path = folder == '/' ? '/$name' : '$folder/$name';
      final NetworkEntry entry;
      switch (item) {
        case PlexFolderItem(:final key):
          _nodes[path] = _Folder(key: key, section: parent.section, albums: parent.albums, belowSection: true);
          entry = NetworkEntry(sourceId: source.id, path: path, isDirectory: true);
        case PlexFileItem():
          _nodes[path] = _File(item, parent.section);
          // A size found by stat stays, unless the server tells one now
          final known = _entries[path];
          entry = NetworkEntry(
            sourceId: source.id,
            path: path,
            isDirectory: false,
            size: item.size ?? (known?.isDirectory == false ? known?.size : null),
            modified: item.addedAt,
            mimeType: item.mimeType,
            width: item.width,
            height: item.height,
            durationMs: item.durationMs,
            // The film's title under its picture and in the title of its page, not the name of the file: in a film
            // library only, "Other videos" keeping the names of their files
            title: item.isPoster && (parent.section?.isFilms ?? false) ? item.title : null,
          );
      }
      _entries[path] = entry;
      entries.add(entry);
    }
    return entries;
  }

  /// The size of the file at [path]: the one of its listing, else the one [_sizeOf] finds, kept with its entry
  Future<int?> _fileSize(String path, PlexFileItem file) async {
    final entry = _entries[path];
    final known = entry?.size ?? file.size;
    if (known != null) {
      return known;
    }
    if (_unknownSizes.contains(path)) {
      return null;
    }
    final size = await _sizeOf(file);
    if (size == null) {
      _unknownSizes.add(path);
    } else if (entry != null) {
      _entries[path] = NetworkEntry(
        sourceId: entry.sourceId,
        path: entry.path,
        isDirectory: false,
        size: size,
        modified: entry.modified,
        mimeType: entry.mimeType,
        width: entry.width,
        height: entry.height,
        durationMs: entry.durationMs,
        title: entry.title,
      );
    }
    return size;
  }

  /// The size of [file] by a request for its first byte: the total of the Content-Range of a 206, or the length of a
  /// 200 (the whole file, dropped at once); null when neither tells
  Future<int?> _sizeOf(PlexFileItem file) async {
    final response = await _plex.send(
      'GET',
      _endpoint.base.resolve(file.partKey),
      accept: '*/*',
      headers: const {'range': 'bytes=0-0', 'accept-encoding': 'identity'},
    );
    final status = response.statusCode;
    final size = switch (status) {
      206 => int.tryParse(RegExp(r'/\s*(\d+)\s*$').firstMatch(response.headers['content-range'] ?? '')?.group(1) ?? ''),
      200 => response.contentLength,
      _ => null,
    };
    if ((status == 200 || status == 206) && (response.contentLength ?? 2) > 1) {
      // The whole file: only the headers were wanted
      try {
        await response.stream.listen(null).cancel();
      } catch (_) {
        // Nothing to do with a failure to stop a transfer nobody reads
      }
    } else {
      await discardHttpBody(response);
    }
    if (status == 404 || status == 410) {
      throw const _PartGone();
    }
    if (status != 200 && status != 206) {
      throw PlexHttpStatus(status);
    }
    return size;
  }

  Future<(http.StreamedResponse, Uri)> _sendRead(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Future<void>? abort,
  }) async => (await _plex.send(method, uri, headers: headers, accept: '*/*', abort: abort), uri);

  Future<Never> _failRead(http.StreamedResponse response, String key) async {
    await discardHttpBody(response);
    throw PlexHttpStatus(response.statusCode);
  }

  /// Runs [action], and once more after forgetting every key when the server no longer knows one (a rescan gives new
  /// ids); a second miss is a path that is not there any more. The calls that meet stale keys together (a rescan under
  /// many reads) forget them once, and never while another call walks again: its walk would lose what it found.
  Future<T> _rewalkOnce<T>(Future<T> Function(bool again) action) async {
    final generation = _generation;
    try {
      return await action(false);
    } on _Stale {
      await _forgetKeys(generation);
      _walkingAgain++;
      try {
        return await action(true);
      } on _PartGone {
        // The film is still there (its item or its folder was found again), its file is not: a volume not mounted
        throw plexFileUnreadable;
      } on _Stale {
        throw _notFound;
      } finally {
        if (--_walkingAgain == 0) {
          final walked = _walkedAgain;
          _walkedAgain = null;
          walked?.complete();
        }
      }
    }
  }

  /// Forgets every key, unless another call did since [generation]: the walk that follows serves this call too
  Future<void> _forgetKeys(int generation) async {
    if (generation != _generation) {
      return;
    }
    while (_walkingAgain > 0) {
      await (_walkedAgain ??= Completer<void>()).future;
    }
    if (generation != _generation) {
      return;
    }
    _generation++;
    _log.info('The server no longer knows a key it gave: walking the libraries again from the top');
    _nodes
      ..clear()
      ..['/'] = _Folder.root();
    _entries.clear();
    _unknownSizes.clear();
    _listings.clear();
    _emptyKeys.clear();
    // A listing under way holds an old key: the new walk must not wait for it
    _browsing.clear();
    _openListing = null;
  }

  /// Runs [action], with every failure turned into a [NetworkFileSystemException] without the token, an address, a
  /// path or a title
  ///
  /// Every call goes through the breaker of the server: refused at once while it is open (but for its probe), and
  /// told whether the server answered.
  Future<T> _guard<T>(Future<T> Function() action) async {
    final permit = _breaker.admit();
    if (permit == null) {
      _log.fine('Not asked: the server stopped answering (next probe in ${_breaker.retryIn.inSeconds} s)');
      throw _breaker.everReached
          ? plexStoppedAnswering(sourceId: source.id)
          : (_lastFailure ?? const PlexFileSystemException('The Plex server does not answer', PlexFailure.unreachable));
    }
    try {
      final result = await action();
      _breaker.answered(permit);
      return result;
    } on PlexRequestCancelled {
      _breaker.released(permit);
      rethrow;
    } on _PartGone {
      _breaker.answered(permit);
      throw plexFileUnreadable;
    } on _Stale {
      _breaker.answered(permit);
      throw _notFound;
    } catch (error) {
      if (_closed) {
        _breaker.released(permit);
        throw plexErrorOf(error, outsideHome: _current?.outsideHome ?? false);
      }
      final network = isPlexNetworkFailure(error);
      // Read before the failure is counted: the server answered in this run, so it stopped
      final reached = _breaker.everReached;
      final mapped = plexErrorOf(
        error,
        outsideHome: _current?.outsideHome ?? false,
        reachedBefore: reached,
        sourceId: source.id,
      );
      if (network) {
        _breaker.failed(permit);
        _lastFailure = mapped;
      } else {
        // An answer of the server, whatever it said
        _breaker.answered(permit);
      }
      throw mapped;
    }
  }

  /// What the last failure of the network was told as, for the calls the breaker refuses before the server ever
  /// answered (the address outside home to set up, for one)
  NetworkFileSystemException? get _lastFailure => switch (_breaker.lastFailure) {
    final NetworkFileSystemException failure => failure,
    _ => null,
  };
  set _lastFailure(NetworkFileSystemException? value) => _breaker.lastFailure = value;

  /// The probe of the breaker: /identity at the address in use, through [_guard] like any call
  Future<void> _probe() async {
    if (_closed) {
      return;
    }
    await _guard(
      () => _onServer(() => _plex.getJson(_endpoint.base.resolve('/identity'), parsePlexIdentity, withToken: false)),
    );
  }

  static const _downloadForbidden = PlexFileSystemException(
    'The owner of the Plex server does not allow this account to download',
    PlexFailure.tokenForbidden,
    isAuthentication: true,
    isDownloadForbidden: true,
  );

  static const _notFound = PlexFileSystemException(
    'This item is no longer on the Plex server',
    PlexFailure.failed,
    isNotFound: true,
  );

  static String _parentOf(String path) {
    final slash = path.lastIndexOf('/');
    return slash <= 0 ? '/' : path.substring(0, slash);
  }

  // The films of the film libraries (plex_film_list.dart): read page by page, their files under paths of their own

  @override
  PlexSection? filmLibraryAt(String path) {
    final section = sectionAt(path);
    return section != null && section.isFilms ? section : null;
  }

  @override
  String get filmsSourceId => source.id;

  @override
  Future<List<({PlexSection section, String folderPath})>> filmLibraries() async {
    await list('/');
    return [
      for (final MapEntry(key: path, value: node) in _nodes.entries)
        if (node is _Folder && !node.isRoot && !node.belowSection && (node.section?.isFilms ?? false))
          (section: node.section!, folderPath: path),
    ];
  }

  @override
  Future<List<int?>> filmYears(PlexFilmListQuery query) async => [
    for (final film in await _lightPass(query)) film.year,
  ];

  /// The light pass of [query]: the year and the titles of each of its films, in its order. The titles of the last
  /// passes stay for the search without accents (filmsByFoldedTitle), by query without its title.
  Future<List<({int? year, PlexFilmTitles titles})>> _lightPass(PlexFilmListQuery query) => _guard(
    () => _onServer(() async {
      final films = <({int? year, PlexFilmTitles titles})>[];
      var start = 0;
      while (start < PlexFilmListQuery.maxFilms) {
        final page = await _plex.getJson(
          _filmsUri(query, light: true),
          parsePlexYearsPage,
          headers: {'x-plex-container-start': '$start', 'x-plex-container-size': '${PlexFilmListQuery.yearsPageSize}'},
        );
        for (final (index, year) in page.years.indexed) {
          films.add((year: year, titles: page.titles[index]));
        }
        if (page.count <= 0) {
          break;
        }
        start += page.count;
        final total = page.totalSize;
        if (total == null ? page.count < PlexFilmListQuery.yearsPageSize : start >= total) {
          break;
        }
      }
      if (query.searchedTitle == null) {
        _lightTitles.remove(query);
        _lightTitles[query] = [for (final film in films) film.titles];
        while (_lightTitles.length > _lightTitlesKept) {
          _lightTitles.remove(_lightTitles.keys.first);
        }
      }
      return films;
    }),
  );

  /// The titles of the films of the last light passes, by query (no title searched), the last one at the end
  final Map<PlexFilmListQuery, List<PlexFilmTitles>> _lightTitles = {};

  /// How many lists of titles stay (a filter or a sort is another list)
  static const _lightTitlesKept = 4;

  /// How many films one request of their items asks (/library/metadata/{key,key,...})
  static const _itemsPerRequest = 50;

  @override
  Future<List<PlexFilm>> filmsByFoldedTitle(
    PlexFilmListQuery query,
    String text, {
    Set<String> except = const {},
    int limit = plexFoldedSearchLimit,
  }) async {
    final list = query.copyWith(clearTitle: true);
    final titles = _lightTitles[list] ?? [for (final film in await _lightPass(list)) film.titles];
    final keys = <String>[];
    final seen = <String>{...except};
    for (final film in titles) {
      if (keys.length >= limit) {
        break;
      }
      if (!seen.contains(film.ratingKey) && plexTitleMatches(film, text)) {
        seen.add(film.ratingKey);
        keys.add(film.ratingKey);
      }
    }
    if (keys.isEmpty) {
      return const [];
    }
    return _guard(
      () => _onServer(() async {
        final films = <PlexFilm>[];
        for (var start = 0; start < keys.length; start += _itemsPerRequest) {
          final batch = keys.skip(start).take(_itemsPerRequest).map(Uri.encodeComponent).join(',');
          final page = await _plex.getJson(_endpoint.base.resolve('/library/metadata/$batch'), parsePlexFilmListPage);
          films.addAll(page.films);
        }
        _recordFilms(query.sectionKey, films);
        return films;
      }),
    );
  }

  @override
  Future<PlexFilmListPage> filmsPage(PlexFilmListQuery query, {required int start, required int size}) => _guard(
    () => _onServer(() async {
      final page = await _plex.getJson(
        _filmsUri(query),
        parsePlexFilmListPage,
        headers: {'x-plex-container-start': '$start', 'x-plex-container-size': '$size'},
      );
      _recordFilms(query.sectionKey, page.films);
      return page;
    }),
  );

  /// The server's own search, which "performs spell checking, looks for partial matches" and is meant to be called as
  /// the user types; a server without it (404, 400) finds nothing
  @override
  Future<List<PlexFilm>> searchFilms(String sectionKey, String text) => _guard(
    () => _onServer(() async {
      final uri = _endpoint.base
          .resolve('/hubs/search')
          .replace(queryParameters: {'query': text, 'sectionId': sectionKey, 'limit': '$_searchLimit'});
      try {
        final films = await _plex.getJson(uri, _hubFilmsOf(sectionKey));
        _recordFilms(sectionKey, films);
        return films;
      } on PlexHttpStatus catch (error) {
        if (error.status == 404 || error.status == 400 || error.status == 501) {
          return const <PlexFilm>[];
        }
        rethrow;
      }
    }),
  );

  /// The films a spelling tolerant search adds at most, per hub
  static const _searchLimit = 30;

  /// The parser of a search of [sectionKey], made apart from this connection: it may run in another isolate
  static List<PlexFilm> Function(Object? json) _hubFilmsOf(String sectionKey) =>
      (json) => parsePlexHubFilms(json, sectionKey);

  Uri _filmsUri(PlexFilmListQuery query, {bool light = false}) =>
      _endpoint.base.resolve(query.path).replace(queryParameters: query.queryParameters(light: light));

  /// Records the files of [films] under their paths (see plexFilmPartPath), for the reads, the bridge and the pictures
  void _recordFilms(String sectionKey, List<PlexFilm> films) {
    for (final film in films) {
      for (final part in film.parts) {
        final path = plexFilmPartPath(sectionKey, film.ratingKey, part);
        _nodes[path] = _File(part, _sections[sectionKey]);
        // A size found by stat stays, unless the server tells one now
        final known = _entries[path]?.size;
        _entries[path] = plexFilmPartEntry(source.id, path, part, title: film.title, knownSize: known);
      }
    }
  }
}

/// The identity of a copy of [file] (see NetworkDownloadStream.identity): the key of its part, whose change stamp
/// moves when the file changes, and its size when the listing gives it
String plexDownloadIdentity(PlexFileItem file) => '${file.partKey}|${file.size ?? ''}';

/// The first offset and the total of a Content-Range header ("bytes 100-199/1000"), the total null when it is "*";
/// null when the header is missing or malformed
({int start, int? total})? parseContentRange(String? header) {
  final match = RegExp(r'^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$').firstMatch(header ?? '');
  if (match == null) {
    return null;
  }
  return (start: int.parse(match.group(1)!), total: int.tryParse(match.group(3)!));
}

/// The address outside home of a Plex server: the one typed by the user, through the port typed, else the port the
/// server told (the one its router forwards), else 32400; else the one the server told, through the port typed alone
/// when there is one. Null when there is neither.
({String host, int port})? plexPublicAddress(PlexServerInfo plex, PlexLearnedAddress? told) {
  final typed = plex.publicHost?.trim();
  if (typed != null && typed.isNotEmpty) {
    return (host: typed, port: plex.publicPort ?? told?.port ?? plexDefaultPort);
  }
  if (told != null) {
    return (host: told.host, port: plex.publicPort ?? told.port);
  }
  return null;
}

/// An address the server may answer at, resolved when it is tried (a DynDNS name)
class _Candidate {
  const _Candidate(this.outsideHome, this.base);

  final bool outsideHome;
  final Future<Uri> Function() base;

  String get label => outsideHome ? 'The address outside home' : 'The address at home';
}

/// The address in use
class _Endpoint {
  const _Endpoint(this.base, this.outsideHome);

  /// `https://<ipv4-dashes>.<hash>.plex.direct:<port>`
  final Uri base;
  final bool outsideHome;

  String get label => outsideHome ? 'The address outside home' : 'The address at home';
}

sealed class _Node {}

/// A folder: the root (the sections), a section, or a folder of a section
class _Folder extends _Node {
  _Folder({required this.key, this.section, this.albums = false, this.belowSection = false}) : isRoot = false;

  _Folder.root() : key = '/library/sections', section = null, albums = false, belowSection = false, isRoot = true;

  /// The request path of its listing
  String key;
  final PlexSection? section;

  /// Whether the photo section it belongs to is listed by albums (its folder view did not answer)
  bool albums;

  /// A folder whose key came from a listing, which a rescan may change
  final bool belowSection;
  final bool isRoot;
}

class _File extends _Node {
  _File(this.file, this.section);

  final PlexFileItem file;

  /// The library it was listed in, null when not known
  final PlexSection? section;
}

/// The server does not know a key it gave any more: 404 on a listing or a part
class _Stale implements Exception {
  const _Stale();

  @override
  String toString() => 'Stale Plex key';
}

/// The server answers 404 for the part of a file it listed: looked for again once (a rescan gives new keys), then the
/// file is one the server cannot read now ([plexFileUnreadable])
class _PartGone extends _Stale {
  const _PartGone();

  @override
  String toString() => 'Plex part not found';
}

/// The Plex item behind a path of a [PlexFileSystem] (see [PlexFileSystem.itemAt])
class PlexItemRef {
  const PlexItemRef({required this.ratingKey, required this.path, this.partId, this.section});

  final String ratingKey;

  /// The path it was asked for
  final String path;

  /// Its file, null when the listing did not tell
  final int? partId;

  /// Its library, null when not known yet
  final PlexSection? section;

  /// Whether a tap on it opens the film page: an item of a library of films, or of a library not known yet that
  /// [path] says is a film
  bool get opensFilmPage => section?.isFilms ?? parsePlexFilmPath(path) != null;
}

/// One page of [PlexFileSystem.films]: the entries of the films, their paths those of [plexFilmPath], and the films
/// themselves in the same order
class PlexFilmsResult {
  const PlexFilmsResult({required this.entries, required this.items, required this.count, this.totalSize});

  final List<NetworkEntry> entries;
  final List<PlexFilmItem> items;
  final int count;
  final int? totalSize;
}
