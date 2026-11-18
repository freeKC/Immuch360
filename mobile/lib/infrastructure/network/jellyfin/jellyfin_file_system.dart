// The NetworkFileSystem of a Jellyfin or Emby server: its libraries as folders, read with the token of the signed in
// user (see jellyfin_client.dart).
//
// "/" lists the libraries the app shows (films, series, home videos and photos, music videos, folders, mixed). A film
// library lists its films, sorted by their sort name and paged by 200, each a file under the name of its file on the
// server's disk, with its title and year under its poster. A series library lists its series as folders, a series its
// seasons, a season its episodes, titled "S01E02 Name". The other libraries show the server's folders and files as it
// lists them. The server knows items by id, which this file system maps paths to as it lists, as the DLNA and Plex
// ones do; a path not met yet (after a restart) is found by listing its parents. Items also have paths of their own,
// whatever lists them (jellyfinItemPath: /.items/{itemId}/{mediaSourceId}/{name}), for the film page and the history.
//
// The file name is the base name of the media source's path when the server gives it (it keeps the words the app
// reads in a name: "360", "sbs", "3D"); else the title, the 3D layout the server read (" hsbs", " sbs", " htb", " tb")
// and the container. The 360 projection is read from the file itself by the app's probes, so a hidden path never loses
// it. Files are read with Range requests as they are on the disk (the static stream of a video, the File route of any
// other item), never through the server's conversion, which would drop the 360 and 3D metadata. The posters and
// thumbnails come from the server's images, read in Dart with the token (see NetworkThumbnailSource).
//
// Rule of every share client of the app: no URL of the server crosses a pigeon call to Kotlin or Swift, nor reaches an
// image widget. The players and viewers only ever get the http://127.0.0.1 URLs of the media bridge. Logs tell request
// kinds, statuses and timings, never the token, an address, a path or a title.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/media_server_item.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/entry_names.dart';
import 'package:immich_mobile/infrastructure/network/http_range_reader.dart';
import 'package:immich_mobile/infrastructure/network/isolate_http_client.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_client.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_routes.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart' show plexAppVersion;
import 'package:immich_mobile/infrastructure/network/webdav_file_system.dart';
import 'package:logging/logging.dart';

final _log = Logger('JellyfinFileSystem');

/// The libraries the app lists: their collection types (null for a library of mixed content)
const jellyfinShownLibraries = {'movies', 'tvshows', 'homevideos', 'photos', 'musicvideos', 'folders', null};

/// The base URL of [source]: http or https, its host, its port (8096 or 8920 by default) and its base path
Uri jellyfinBaseOf(NetworkSource source) {
  var host = source.host.trim();
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  if (host.isEmpty) {
    throw const NetworkFileSystemException('No server address');
  }
  var path = source.share.trim();
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.isNotEmpty && !path.startsWith('/')) {
    path = '/$path';
  }
  return Uri(
    scheme: source.useTls ? 'https' : 'http',
    host: host,
    port: source.port ?? (source.useTls ? jellyfinDefaultTlsPort : jellyfinDefaultPort),
    path: path,
  );
}

/// The path of the item [itemId] (its media source [mediaSourceId], "-" for none) whatever lists it
String jellyfinItemPath(String itemId, String? mediaSourceId, String name) =>
    '${JellyfinFileSystem.itemFolder}/${Uri.encodeComponent(itemId)}/${Uri.encodeComponent(mediaSourceId ?? '-')}/'
    '$name';

/// The words the app reads in a file name for the 3D layout the server read (Video3DFormat)
String jellyfin3DSuffix(String? format) => switch (format) {
  'HalfSideBySide' => ' hsbs',
  'FullSideBySide' => ' sbs',
  'HalfTopAndBottom' => ' htb',
  'FullTopAndBottom' => ' tb',
  _ => '',
};

/// The name of the file of [item] in a listing: the base name of its path on the server when given, else its title,
/// the 3D layout the server read and its container
String jellyfinEntryName(JellyfinItem item) {
  final source = item.firstSource;
  final path = source?.path ?? item.path;
  if (path != null) {
    final base = path.split(RegExp(r'[/\\]')).last.trim();
    if (base.contains('.') && !base.startsWith('.')) {
      return safeEntryName(base);
    }
  }
  final container = (source?.container ?? item.container)?.split(',').first.trim();
  final extension = container != null && container.isNotEmpty
      ? container
      : item.isPhoto
      ? 'jpg'
      : 'mp4';
  final title = safeEntryName(item.name.isEmpty ? item.id : item.name);
  return '$title${jellyfin3DSuffix(source?.video3DFormat ?? item.video3DFormat)}.$extension';
}

/// The title shown for [item]: a film's name and year (unless the name holds it), an episode's "S01E02 Name"; null for
/// the other files, which show their file name
String? jellyfinTitleOf(JellyfinItem item) {
  if (item.isMovie) {
    final year = item.productionYear;
    return year == null || item.name.contains('$year') ? item.name : '${item.name} ($year)';
  }
  if (item.isEpisode) {
    final season = item.parentIndexNumber;
    final episode = item.indexNumber;
    if (season == null || episode == null) {
      return item.name;
    }
    String two(int n) => n.toString().padLeft(2, '0');
    return 'S${two(season)}E${two(episode)} ${item.name}';
  }
  return null;
}

/// A [NetworkFileSystem] over a Jellyfin or Emby server, see [open]
class JellyfinFileSystem
    implements
        NetworkFileSystem,
        NetworkThumbnailSource,
        NetworkRangeReads,
        NetworkAbortableReads,
        NetworkPlaybackReports,
        MediaServerItemSource {
  JellyfinFileSystem._(this.source, this.client, this.userId, this.info, this._pageSize);

  /// Checks that the server at the address of [source] is the one of its server id, without the token, then the
  /// token with the signed in user, then lists the start folder. Throws a [JellyfinException]: otherServer when
  /// another server answers (no token is sent to it), tokenRefused (isAuthentication) when the token is missing or
  /// refused.
  ///
  /// [client] is used instead of a client of its own (off the UI isolate); [installId] instead of the install's
  /// (StoreKey.jellyfinDeviceId); [appVersion] instead of the app's.
  static Future<JellyfinFileSystem> open(
    NetworkSource source,
    String? token, {
    http.Client? client,
    String? installId,
    String? appVersion,
    @visibleForTesting int pageSize = defaultPageSize,
  }) async {
    if (source.type != NetworkSourceType.jellyfin) {
      throw ArgumentError.value(source.type, 'source.type', 'Not a Jellyfin source');
    }
    final server = source.jellyfin;
    if (server == null) {
      throw JellyfinException.of(JellyfinFailure.otherServer);
    }
    if (token == null || token.isEmpty) {
      throw JellyfinException.of(JellyfinFailure.tokenRefused);
    }
    final watch = Stopwatch()..start();
    final routes = JellyfinRoutes(
      jellyfinBaseOf(source),
      server.isEmby ? JellyfinProduct.emby : JellyfinProduct.jellyfin,
      server.version,
    );
    final jellyfin = JellyfinClient(
      client ?? jellyfinHttpClient(),
      routes: routes,
      deviceId: jellyfinDeviceIdOf(installId ?? await jellyfinInstallId(), source.id),
      appVersion: appVersion ?? await plexAppVersion(),
    );
    JellyfinFileSystem? fileSystem;
    var step = 'info';
    try {
      final JellyfinPublicInfo info;
      try {
        info = await jellyfin.publicInfo();
      } catch (error) {
        throw jellyfinErrorOf(error);
      }
      if (info.id != server.serverId) {
        _log.info('Another server answers at the address of the source: no token sent');
        throw JellyfinException.of(JellyfinFailure.otherServer);
      }
      step = 'user';
      // The version and product of now: a server updated since the sign in may have moved its routes
      final live = JellyfinClient(
        jellyfin.httpClient,
        routes: JellyfinRoutes(routes.base, info.product, info.version),
        deviceId: jellyfin.deviceId,
        token: token,
        appVersion: jellyfin.appVersion,
      );
      try {
        await live.me(server.userId);
      } catch (error) {
        throw jellyfinErrorOf(error);
      }
      step = 'list';
      fileSystem = JellyfinFileSystem._(source, live, server.userId, info, pageSize);
      final root = normalizePath(source.rootPath);
      fileSystem._openListing = (root, await fileSystem.list(root));
    } catch (error) {
      if (fileSystem != null) {
        await fileSystem.close();
      } else {
        jellyfin.close();
      }
      final failure = error is JellyfinException ? error : jellyfinErrorOf(error);
      lastOpenFailure = (
        step: step,
        status: failure is JellyfinException ? failure.status : null,
        failure: failure is JellyfinException ? failure.failure : JellyfinFailure.serverError,
      );
      _log.info('Open failed at $step: ${jellyfinErrorKind(failure)}');
      throw failure;
    }
    _log.info(
      'Opened ${fileSystem.info.product.name} ${fileSystem.info.version ?? ''} in ${watch.elapsedMilliseconds} ms',
    );
    return fileSystem;
  }

  /// The step and status of the last open that failed, for the diagnostics line of the pages
  static ({String step, int? status, JellyfinFailure failure})? lastOpenFailure;

  @override
  final NetworkSource source;

  /// The requests to the server, with the token
  final JellyfinClient client;

  /// The signed in user
  final String userId;

  /// What the server told of itself at the open
  final JellyfinPublicInfo info;

  final int _pageSize;
  bool _closed = false;

  JellyfinRoutes get routes => client.routes;
  JellyfinProduct get product => info.product;

  static const defaultPageSize = 200;

  /// Entries listed in one folder at most, as for DLNA and Plex; a folder that holds more shows the first ones
  static const maxEntriesPerFolder = 20000;
  static const listingLifetime = Duration(seconds: 60);

  /// The folder of the paths of their own of the items
  static const itemFolder = '/.items';

  /// Steps of the sizes asked of the server's images, so that the cache holds few sizes of one picture
  static const thumbnailStep = 120;
  static const _maxThumbnailSize = 1920;

  /// The nodes behind the paths listed so far, the root as the list of the libraries
  final Map<String, _Node> _nodes = {'/': const _Node.root()};

  /// The entries of the paths listed so far, for [stat], with the sizes found by [stat] itself
  final Map<String, NetworkEntry> _entries = {};

  final Map<String, ({List<NetworkEntry> entries, Duration at})> _listings = {};
  final Map<String, Future<List<NetworkEntry>>> _browsing = {};
  (String, List<NetworkEntry>)? _openListing;
  final Stopwatch _clock = Stopwatch()..start();
  final Set<String> _unknownSizes = {};

  /// The last request that failed after the open, for the diagnostics line: its step and status
  ({String step, int? status})? lastFailure;

  late final _ranges = HttpRangeReader(send: _sendRead, fail: _failRead, isClosed: () => _closed);

  /// Whether the server honours range requests on its files (see [HttpRangeReader.supportsRanges])
  @override
  bool? get supportsRanges => _ranges.supportsRanges;

  /// [path] absolute, "/" separated, as for WebDAV
  static String normalizePath(String path) => WebDavFileSystem.normalizePath(path);

  /// The item behind [path], null when it was not met (or is no item: the root)
  JellyfinItem? itemAt(String path) => _nodes[normalizePath(path)]?.item;

  /// The media source of the file at [path], null when none or not met
  String? mediaSourceAt(String path) => _nodes[normalizePath(path)]?.mediaSourceId;

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
    return _guard('list', () => _browseFolder(folder));
  }

  @override
  Future<NetworkEntry> stat(String path) {
    final target = normalizePath(path);
    if (target == '/') {
      return Future.value(NetworkEntry(sourceId: source.id, path: '/', isDirectory: true));
    }
    return _guard('stat', () async {
      final node = await _resolve(target);
      final entry = _entries[target] ?? _entryOf(target, node);
      _entries[target] = entry;
      if (entry.isDirectory || entry.size != null) {
        return entry;
      }
      await _fileSize(target, node);
      // Still without a size when the server does not tell it: the bridge then streams the file without ranges
      return _entries[target] ?? entry;
    });
  }

  @override
  Future<Uint8List> readRange(String path, int offset, int asked, {Future<void>? abort}) {
    RangeError.checkNotNegative(offset, 'offset');
    RangeError.checkNotNegative(asked, 'length');
    final target = normalizePath(path);
    if (asked == 0) {
      return Future.value(Uint8List(0));
    }
    return _guard('read', () async {
      final node = await _resolve(target);
      if (node.kind != _Kind.file) {
        throw NetworkFileSystemException('$target is not a file');
      }
      final size = await _fileSize(target, node);
      if (size != null && offset >= size) {
        return Uint8List(0);
      }
      final length = size == null ? asked : min(asked, size - offset);
      return _ranges.read(_fileUri(node), 'item:${node.item!.id}', offset, length, abort: abort);
    });
  }

  /// The play session of each file playing, by path: one per viewing, as the server's own apps do; a conversion
  /// gives its own (see the PlaySessionId of PlaybackInfo)
  final Map<String, ({String id, bool converted})> _playSessions = {};

  /// The play session [id] of a conversion of the file at [path], for its reports
  void usePlaySession(String path, String id) => _playSessions[normalizePath(path)] = (id: id, converted: true);

  static String _newPlaySession() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  Future<void> playbackStarted(String path, Duration position, {bool converted = false}) {
    final target = normalizePath(path);
    final known = _playSessions[target];
    _playSessions[target] = known != null && known.converted == converted
        ? known
        : (id: _newPlaySession(), converted: converted);
    return _report(JellyfinReport.start, target, position);
  }

  @override
  Future<void> playbackProgress(String path, Duration position, {bool paused = false}) =>
      _report(JellyfinReport.progress, normalizePath(path), position, paused: paused);

  @override
  Future<void> playbackStopped(String path, Duration position) async {
    final target = normalizePath(path);
    try {
      await _report(JellyfinReport.stopped, target, position);
    } finally {
      _playSessions.remove(target);
    }
  }

  Future<void> _report(JellyfinReport kind, String path, Duration position, {bool paused = false}) =>
      _guard('report', () async {
        final node = await _resolve(path);
        final item = node.item;
        final mediaSource = node.mediaSourceId ?? item?.firstSource?.id;
        if (item == null || mediaSource == null || _closed) {
          return;
        }
        final session = _playSessions[path] ??= (id: _newPlaySession(), converted: false);
        await client.report(
          kind,
          itemId: item.id,
          mediaSourceId: mediaSource,
          positionMs: position.inMilliseconds,
          playSessionId: session.id,
          paused: paused,
          converted: session.converted,
        );
      });

  /// The items met so far, by id, for their pictures
  final Map<String, JellyfinItem> _items = {};

  JellyfinItem _keep(JellyfinItem item) => _items[item.id] = item;

  @override
  String? itemPageAt(String path) {
    final item = _nodes[normalizePath(path)]?.item;
    return item != null && (item.isMovie || item.isSeries) ? item.id : null;
  }

  @override
  Future<MediaServerItem> itemDetails(String itemId) =>
      _guard('item', () async => jellyfinMediaServerItem(_keep(await client.item(userId, itemId))));

  @override
  Future<List<MediaServerItem>> seasonsOf(String seriesId) => _guard(
    'seasons',
    () async => [for (final season in await client.seasons(userId, seriesId)) jellyfinMediaServerItem(_keep(season))],
  );

  @override
  Future<List<MediaServerItem>> episodesOf(String seriesId, String seasonId) => _guard(
    'episodes',
    () async => [
      for (final episode in await client.episodes(userId, seriesId, seasonId: seasonId))
        if (episode.isVideo) jellyfinMediaServerItem(_keep(episode)),
    ],
  );

  @override
  Future<MediaServerItem?> nextEpisodeOf(String seriesId) => _guard('next up', () async {
    final next = await client.nextUp(userId, seriesId);
    return next == null ? null : jellyfinMediaServerItem(_keep(next));
  });

  @override
  Future<Uint8List?> itemPicture(String itemId, int size) async {
    final item = _items[itemId];
    return item == null || _closed ? null : pictureOf(item, size);
  }

  /// The path of its own of the item [itemId] (see [jellyfinItemPath]), its node and entry known
  @override
  Future<String> pathOfItem(String itemId) => _guard('item', () async {
    final item = _keep(await client.item(userId, itemId));
    final name = jellyfinEntryName(item);
    final path = jellyfinItemPath(item.id, item.firstSource?.id, name);
    final node = _Node.of(item);
    _nodes[path] = node;
    _entries[path] = _entryOf(path, node);
    return path;
  });

  @override
  Future<Uint8List?> thumbnail(NetworkEntry entry, int size) async {
    final node = _nodes[normalizePath(entry.path)];
    final item = node?.item;
    if (item == null || _closed) {
      return null;
    }
    return pictureOf(item, size);
  }

  /// The Primary image of [item] about [size] pixels high (a poster at 2:3 for a film or a series), null when it has
  /// none or the server could not give it
  Future<Uint8List?> pictureOf(JellyfinItem item, int size) async {
    final tag = item.primaryImageTag;
    if (tag == null && !item.isPhoto) {
      return null;
    }
    final step = (((max(size, 1) + thumbnailStep - 1) ~/ thumbnailStep) * thumbnailStep).clamp(
      thumbnailStep,
      _maxThumbnailSize,
    );
    final poster = item.isMovie || item.isSeries || item.isSeason;
    final uri = poster
        ? routes.image(item.id, 'Primary', fillWidth: step * 2 ~/ 3, fillHeight: step, tag: tag)
        : routes.image(item.id, 'Primary', maxWidth: step, maxHeight: step, tag: tag);
    try {
      return await client.bytes(uri);
    } catch (error) {
      _log.fine('No picture: ${jellyfinErrorKind(error)}');
      return null;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _ranges.close();
    client.close();
  }

  /// The node at [path], from the listing of its parent when it was not met yet (or from the server for a path of its
  /// own of an item)
  Future<_Node> _resolve(String path) async {
    final known = _nodes[path];
    if (known != null) {
      return known;
    }
    if (path.startsWith('$itemFolder/')) {
      final parts = path.substring(itemFolder.length + 1).split('/');
      if (parts.length < 3) {
        throw NetworkFileSystemException('$path was not found', isNotFound: true);
      }
      final item = await client.item(userId, Uri.decodeComponent(parts[0]));
      final sourceId = Uri.decodeComponent(parts[1]);
      final node = _Node.of(item, mediaSourceId: sourceId == '-' ? null : sourceId);
      _nodes[path] = node;
      _entries[path] = _entryOf(path, node);
      return node;
    }
    await _listingOf(_parentOf(path));
    final found = _nodes[path];
    if (found == null) {
      throw NetworkFileSystemException('$path was not found', isNotFound: true);
    }
    return found;
  }

  Future<List<NetworkEntry>> _listingOf(String folder) async {
    final listing = _listings[folder];
    if (listing != null && _clock.elapsed - listing.at < listingLifetime) {
      return listing.entries;
    }
    return _browseFolder(folder);
  }

  Future<List<NetworkEntry>> _browseFolder(String folder) {
    final running = _browsing[folder];
    if (running != null) {
      return running;
    }
    late final Future<List<NetworkEntry>> browsing;
    browsing = () async {
      try {
        final node = await _resolve(folder);
        if (node.kind == _Kind.file) {
          throw NetworkFileSystemException('$folder is not a folder');
        }
        final items = await _childrenOf(node);
        final entries = <NetworkEntry>[];
        final named = uniqueEntryNames<_Node>(
          items,
          (child) => child.kind == _Kind.file ? jellyfinEntryName(child.item!) : safeEntryName(child.item!.name),
          (child) => child.kind != _Kind.file,
        );
        for (final (:item, :name) in named) {
          final path = folder == '/' ? '/$name' : '$folder/$name';
          _nodes[path] = item;
          if (item.item case final met?) {
            _keep(met);
          }
          final entry = _entryOf(path, item);
          final known = _entries[path];
          _entries[path] = known != null && entry.size == null && known.size != null
              ? _withSize(entry, known.size!)
              : entry;
          entries.add(_entries[path]!);
        }
        // Films and episodes keep the order of the server (by sort name, by number); folders first all the same
        final ordered = node.keepsServerOrder
            ? [...entries.where((e) => e.isDirectory), ...entries.where((e) => !e.isDirectory)]
            : (entries..sort(compareNetworkEntries));
        final listed = List<NetworkEntry>.unmodifiable(ordered);
        _listings[folder] = (entries: listed, at: _clock.elapsed);
        return listed;
      } finally {
        if (identical(_browsing[folder], browsing)) {
          _browsing.remove(folder)?.ignore();
        }
      }
    }();
    _browsing[folder] = browsing;
    return browsing;
  }

  /// The children of [node] as the server lists them
  Future<List<_Node>> _childrenOf(_Node node) async {
    final item = node.item;
    switch (node.kind) {
      case _Kind.root:
        final views = await client.views(userId);
        return [
          for (final view in views)
            if (jellyfinShownLibraries.contains(view.collectionType)) _Node.library(view),
        ];
      case _Kind.library when node.item!.collectionType == 'movies':
        return [
          for (final film in await _all(item!.id, types: 'Movie', recursive: true))
            if (film.isVideo) _Node.of(film),
        ];
      case _Kind.library when node.item!.collectionType == 'tvshows':
        return [for (final series in await _all(item!.id, types: 'Series', recursive: true)) _Node.of(series)];
      case _Kind.series:
        return [for (final season in await client.seasons(userId, item!.id)) _Node.of(season)];
      case _Kind.season:
        final seriesId = item!.seriesId;
        final episodes = seriesId == null
            ? await _all(item.id)
            : await client.episodes(userId, seriesId, seasonId: item.id);
        return [
          for (final episode in episodes)
            if (episode.isVideo) _Node.of(episode),
        ];
      case _Kind.library || _Kind.folder:
        return [
          for (final child in await _all(item!.id))
            if (child.isFolder || child.isVideo || child.isPhoto) _Node.of(child),
        ];
      case _Kind.file:
        return const [];
    }
  }

  /// Every page of the children of [parentId], [maxEntriesPerFolder] at most
  Future<List<JellyfinItem>> _all(String parentId, {String? types, bool recursive = false}) async {
    final all = <JellyfinItem>[];
    var start = 0;
    while (true) {
      final page = await client.items(
        userId,
        parentId: parentId,
        startIndex: start,
        limit: _pageSize,
        includeItemTypes: types,
        recursive: recursive,
      );
      all.addAll(page.items);
      start += page.items.length;
      final total = page.totalRecordCount;
      final more = page.items.isNotEmpty && (total == null ? page.items.length == _pageSize : start < total);
      if (!more) {
        break;
      }
      if (start >= maxEntriesPerFolder) {
        _log.warning('A folder holds more than $maxEntriesPerFolder items; the first ones only are listed');
        break;
      }
    }
    return all;
  }

  NetworkEntry _entryOf(String path, _Node node) {
    final item = node.item;
    if (item == null || node.kind != _Kind.file) {
      return NetworkEntry(sourceId: source.id, path: path, isDirectory: true);
    }
    final media = item.mediaSources.where((s) => s.id == node.mediaSourceId).firstOrNull ?? item.firstSource;
    final video = media?.video;
    return NetworkEntry(
      sourceId: source.id,
      path: path,
      isDirectory: false,
      size: media?.size,
      width: video?.width ?? item.width,
      height: video?.height ?? item.height,
      durationMs: media?.runTimeMs ?? item.runTimeMs,
      title: jellyfinTitleOf(item),
    );
  }

  static NetworkEntry _withSize(NetworkEntry entry, int size) => NetworkEntry(
    sourceId: entry.sourceId,
    path: entry.path,
    isDirectory: entry.isDirectory,
    size: size,
    modified: entry.modified,
    mimeType: entry.mimeType,
    thumbnailUrl: entry.thumbnailUrl,
    width: entry.width,
    height: entry.height,
    durationMs: entry.durationMs,
    title: entry.title,
  );

  /// The original file of [node]: the static stream of a video with a media source, the File route otherwise
  Uri _fileUri(_Node node) {
    final item = node.item!;
    final mediaSource = node.mediaSourceId ?? item.firstSource?.id;
    return item.isVideo && mediaSource != null ? routes.videoStream(item.id, mediaSource) : routes.file(item.id);
  }

  Future<int?> _fileSize(String path, _Node node) async {
    final entry = _entries[path];
    final known = entry?.size;
    if (known != null) {
      return known;
    }
    if (_unknownSizes.contains(path)) {
      return null;
    }
    final response = await client.send(
      'GET',
      _fileUri(node),
      accept: '*/*',
      headers: {'range': 'bytes=0-0', 'accept-encoding': 'identity'},
    );
    final status = response.statusCode;
    final size = switch (status) {
      206 => int.tryParse(RegExp(r'/\s*(\d+)\s*$').firstMatch(response.headers['content-range'] ?? '')?.group(1) ?? ''),
      200 => response.contentLength,
      _ => null,
    };
    try {
      await response.stream.listen(null).cancel();
    } catch (_) {
      // Nothing to do with a failure to stop a transfer nobody reads
    }
    if (status != 200 && status != 206) {
      throw JellyfinHttpStatus(status);
    }
    if (size == null) {
      _unknownSizes.add(path);
    } else if (entry != null) {
      _entries[path] = _withSize(entry, size);
    }
    return size;
  }

  Future<(http.StreamedResponse, Uri)> _sendRead(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Future<void>? abort,
  }) async {
    if (_closed) {
      throw const NetworkFileSystemException('The share is closed');
    }
    try {
      return (await client.send(method, uri, headers: headers, accept: '*/*', abort: abort), uri);
    } on JellyfinRequestCancelled {
      throw http.RequestAbortedException(uri);
    }
  }

  Future<Never> _failRead(http.StreamedResponse response, String key) async {
    await discardHttpBody(response);
    throw JellyfinHttpStatus(response.statusCode);
  }

  /// Runs [action], with the errors of the network and the statuses turned into [JellyfinException]; a read stopped
  /// by its caller passes through
  Future<T> _guard<T>(String step, Future<T> Function() action) async {
    try {
      return await action();
    } on NetworkReadAborted {
      rethrow;
    } catch (error) {
      final mapped = error is JellyfinHttpStatus && error.status == 404
          ? const NetworkFileSystemException('The item was not found on the server', isNotFound: true)
          : jellyfinErrorOf(error);
      lastFailure = (
        step: step,
        status: mapped is JellyfinException ? mapped.status : (error is JellyfinHttpStatus ? error.status : null),
      );
      if (error is! NetworkFileSystemException) {
        _log.info('$step failed: ${jellyfinErrorKind(error)}');
      }
      throw mapped;
    }
  }

  static String _parentOf(String path) {
    final slash = path.lastIndexOf('/');
    return slash <= 0 ? '/' : path.substring(0, slash);
  }
}

/// What the film and series page shows of [item]
MediaServerItem jellyfinMediaServerItem(JellyfinItem item) {
  final source = item.firstSource;
  final audio = [...?source?.streams.where((s) => s.isAudio)];
  // The default track first, then the others in their order
  final ordered = [...audio.where((s) => s.isDefault), ...audio.where((s) => !s.isDefault)];
  final userData = item.userData;
  return MediaServerItem(
    id: item.id,
    kind: item.isMovie
        ? MediaServerItemKind.film
        : item.isSeries
        ? MediaServerItemKind.series
        : item.isSeason
        ? MediaServerItemKind.season
        : item.isEpisode
        ? MediaServerItemKind.episode
        : MediaServerItemKind.other,
    title: item.name,
    year: item.productionYear,
    durationMs: source?.runTimeMs ?? item.runTimeMs,
    overview: item.overview,
    positionMs: userData?.positionMs,
    played: userData?.played ?? false,
    seasonNumber: item.isSeason ? item.indexNumber : item.parentIndexNumber,
    episodeNumber: item.isEpisode ? item.indexNumber : null,
    seriesId: item.seriesId,
    videoCodec: source?.video?.codec,
    videoHeight: source?.video?.height,
    audio: [
      for (final stream in ordered)
        if (stream.codec case final codec?) (codec: codec, channels: stream.channels),
    ],
    stereo: source?.video3DFormat ?? item.video3DFormat,
    versions: max(1, item.mediaSources.length),
  );
}

/// The HTTP client of a Jellyfin or Emby server in the app: off the UI isolate, as Plex since release 47, so that a
/// film read through the bridge does not wait for the frames
http.Client jellyfinHttpClient() => IsolateHttpClient(
  () => HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 15),
);

enum _Kind { root, library, folder, series, season, file }

/// What a path stands for on the server
class _Node {
  const _Node(this.kind, this.item, {this.mediaSourceId});

  const _Node.root() : kind = _Kind.root, item = null, mediaSourceId = null;

  _Node.library(JellyfinItem this.item) : kind = _Kind.library, mediaSourceId = null;

  /// A folder, a series, a season, or a file (its first media source unless [mediaSourceId] says another)
  factory _Node.of(JellyfinItem item, {String? mediaSourceId}) {
    if (item.isSeries) {
      return _Node(_Kind.series, item);
    }
    if (item.isSeason) {
      return _Node(_Kind.season, item);
    }
    if (item.isFolder) {
      return _Node(_Kind.folder, item);
    }
    return _Node(_Kind.file, item, mediaSourceId: mediaSourceId ?? item.firstSource?.id);
  }

  final _Kind kind;
  final JellyfinItem? item;
  final String? mediaSourceId;

  /// Whether the server's order is the one to show: films by sort name, episodes by number, seasons by number
  bool get keepsServerOrder =>
      kind == _Kind.series ||
      kind == _Kind.season ||
      (kind == _Kind.library && (item?.collectionType == 'movies' || item?.collectionType == 'tvshows'));
}
