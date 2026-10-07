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
import 'package:immich_mobile/infrastructure/network/webdav_file_system.dart';
import 'package:immich_mobile/providers/network/plex_learned_addresses.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('PlexFileSystem');

/// A [NetworkFileSystem] over a Plex Media Server, see [open]
class PlexFileSystem implements NetworkFileSystem, NetworkThumbnailSource, NetworkRemoteEndpoint {
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
  bool _closed = false;

  /// The address in use, from [open] on
  _Endpoint? _current;

  /// A new choice of the address under way, shared by the reads that failed together
  Future<void>? _choosing;

  /// The folders and files behind the paths listed so far, the root as the list of the sections
  final Map<String, _Node> _nodes = {'/': _Folder.root()};

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

  static const defaultPageSize = 200;

  /// Entries listed in one folder at most, as for DLNA; a folder that holds more shows the first ones
  static const maxEntriesPerFolder = 20000;
  static const listingLifetime = Duration(seconds: 60);

  /// How long the address at home has alone before the one outside home is tried too
  static const publicStartDelay = Duration(milliseconds: 400);

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
            await _listingOf(_parentOf(target), again);
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

  @override
  Future<Uint8List> readRange(String path, int offset, int asked) {
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
            );
          } on PlexHttpStatus catch (error) {
            throw error.status == 404 || error.status == 410 ? const _Stale() : error;
          }
        }),
      ),
    );
  }

  /// The picture the photo transcoder of the server makes of [entry], about [size] pixels on its long side; null when
  /// the entry has none (a folder, a path not listed by this connection) or the server answers 404
  @override
  Future<Uint8List?> thumbnail(NetworkEntry entry, int size) {
    final node = _nodes[normalizePath(entry.path)];
    final thumb = node is _File ? node.file.thumb : null;
    if (thumb == null) {
      return Future.value(null);
    }
    final side = size.clamp(_minThumbnailSize, _maxThumbnailSize);
    return _guard(
      () => _onServer(() {
        final uri = _endpoint.base
            .resolve('/photo/:/transcode')
            .replace(
              queryParameters: {'width': '$side', 'height': '$side', 'minSize': '1', 'upscale': '0', 'url': thumb},
            );
        return _plex.getBytes(uri);
      }),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
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

  /// What to tell when no address answered: another server first, then what the address outside home said (at home the
  /// address at home would have answered), else what the one at home said
  NetworkFileSystemException _choiceError(List<(_Candidate, Object)> errors) {
    for (final (_, error) in errors) {
      if (error is PlexFileSystemException && error.failure == PlexFailure.otherServer) {
        return error;
      }
    }
    final outside = errors.where((e) => e.$1.outsideHome).firstOrNull;
    if (outside != null) {
      return plexErrorOf(outside.$2, outsideHome: true);
    }
    return errors.isEmpty
        ? const PlexFileSystemException('The Plex server does not answer', PlexFailure.unreachable)
        : plexErrorOf(errors.first.$2);
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
      await _listingOf(_parentOf(path), again);
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
          _nodes[path] = _File(item);
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
      throw const _Stale();
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
  }) async => (await _plex.send(method, uri, headers: headers, accept: '*/*'), uri);

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
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on _Stale {
      throw _notFound;
    } catch (error) {
      throw plexErrorOf(error, outsideHome: _current?.outsideHome ?? false);
    }
  }

  static const _notFound = PlexFileSystemException(
    'This item is no longer on the Plex server',
    PlexFailure.failed,
    isNotFound: true,
  );

  static String _parentOf(String path) {
    final slash = path.lastIndexOf('/');
    return slash <= 0 ? '/' : path.substring(0, slash);
  }
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
  _File(this.file);

  final PlexFileItem file;
}

/// The server does not know a key it gave any more: 404 on a listing or a part
class _Stale implements Exception {
  const _Stale();

  @override
  String toString() => 'Stale Plex key';
}
