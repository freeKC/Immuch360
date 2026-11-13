import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/share_publisher.dart';
import 'package:immich_mobile/desktop/ai/ui/share_conversion.dart';
import 'package:immich_mobile/desktop/selection/desktop_selection.dart';
import 'package:immich_mobile/desktop/selection/network_selection.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/services/folder_contents.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_list.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/presentation/pages/network/network_shares.page.dart';
import 'package:immich_mobile/presentation/widgets/network/film_download.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_status.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_upload.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/plex_film_filter_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_save_launch.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_viewer_launch.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/film_downloads.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_discovery.provider.dart';
import 'package:immich_mobile/providers/network/network_selection.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/network/network_splat.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/providers/splat/splat_viewer.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:logging/logging.dart';

final _log = Logger('NetworkBrowserPage');

/// What the browser shows of a folder: its folders, then its photos and videos with their media bridge URLs, then on a
/// Meta Quest the files that may be Gaussian splats of other tools (lot S5)
typedef _Folder = ({
  List<NetworkEntry> folders,
  List<NetworkEntry> media,
  Map<String, Uri> urls,
  List<NetworkEntry> splats,
});

/// The photos and videos of a share folder in the order the browser shows them ([entries]), with their media bridge
/// URLs by path ([urls]), and the one opened among them ([index]): the immersive viewer goes from it to the previous
/// and next ones.
class NetworkFolderMedia {
  const NetworkFolderMedia({required this.entries, required this.urls, required this.index});

  final List<NetworkEntry> entries;
  final Map<String, Uri> urls;
  final int index;

  /// The photos and videos of the folder with their URLs, and the index among them of [entry], the file a page shows
  /// from [url]: the one at [index], else the one at its path. [entry] alone when it is not in the folder.
  ({List<({NetworkEntry entry, Uri url})> items, int index}) around(NetworkEntry entry, Uri url) {
    final opened = index >= 0 && index < entries.length && entries[index].path == entry.path
        ? index
        : entries.indexWhere((media) => media.path == entry.path);
    if (opened < 0) {
      return (items: [(entry: entry, url: url)], index: 0);
    }
    final items = <({NetworkEntry entry, Uri url})>[];
    var position = 0;
    for (final (i, media) in entries.indexed) {
      if (i == opened) {
        // The page's own entry and URL for the file it shows
        position = items.length;
        items.add((entry: entry, url: url));
        continue;
      }
      // A file without a URL cannot be opened
      final mediaUrl = urls[media.path];
      if (mediaUrl != null) {
        items.add((entry: media, url: mediaUrl));
      }
    }
    return (items: items, index: position);
  }
}

/// The page of the photo or video next to the one at [path] in [folder] ([step] 1 for the next one, -1 for the previous
/// one), with the folder around it: what the arrows of a remote open from a photo or a video. Null at either end of the
/// folder, and without a folder (a camera clip opens on its own).
///
/// The pages open it in their own place (replaceRoute). auto_route keys a page by its route name, so the navigator
/// updates the route in place from one video to the next: the page carries a key of its own file, so that the next
/// file gets a new page, with its own player, rather than the old page and the old player under the new name.
PageRouteInfo? networkFolderNeighbourRoute(String sourceId, NetworkFolderMedia? folder, String path, int step) {
  if (folder == null) {
    return null;
  }
  final entries = folder.entries;
  final current = folder.index >= 0 && folder.index < entries.length && entries[folder.index].path == path
      ? folder.index
      : entries.indexWhere((entry) => entry.path == path);
  final next = current + step;
  if (current < 0 || next < 0 || next >= entries.length) {
    return null;
  }
  final entry = entries[next];
  final around = NetworkFolderMedia(entries: entries, urls: folder.urls, index: next);
  final key = networkFilePageKey(sourceId, entry.path);
  return entry.isVideo
      ? NetworkVideoRoute(key: key, sourceId: sourceId, path: entry.path, folder: around)
      : NetworkPhotoRoute(key: key, sourceId: sourceId, path: entry.path, folder: around);
}

/// The key of the page of a photo or a video of a share: one page, and one player, per file
Key networkFilePageKey(String sourceId, String path) => ValueKey('network-file:$sourceId:$path');

/// The folders and the photos and videos of a network share, or of a folder of this device chosen in On this device
/// (NetworkSourceType.deviceFolder), from [path]: tap a folder to go into it, a photo or a video to open it. On a Meta Quest with Gaussian splats on, the .spz and .ply files that are splats come after them
/// (see SplatFileGrid): neither previous nor next of a photo, never sent to the server. Files of other kinds are left
/// out. A long press on a photo or a video, or the Select button, picks files to send to the Immich server.
@RoutePage()
class NetworkBrowserPage extends ConsumerStatefulWidget {
  const NetworkBrowserPage({super.key, required this.sourceId, required this.path});

  final String sourceId;

  /// Absolute inside the share, "/" separated, starting with "/"
  final String path;

  @override
  ConsumerState<NetworkBrowserPage> createState() => _NetworkBrowserPageState();
}

class _NetworkBrowserPageState extends ConsumerState<NetworkBrowserPage> {
  late Future<_Folder> _folder = _load();

  /// The photos and videos of the folder last read, for the selection
  List<NetworkEntry> _media = const [];

  /// The files of this folder that may be splats: those whose head says so are picked with the photos and videos, and
  /// sent as splat photos
  List<NetworkEntry> _splats = const [];

  /// The splats of [_splats] whose head was read and says they are splats (a .ply mesh is not)
  List<NetworkEntry> get _readSplats => [
    for (final entry in _splats)
      if (ref.read(splatProbeProvider(splatFileKeyOf(entry))).valueOrNull is SplatHead) entry,
  ];

  /// Whether the folder was read once, so that a share found on the network is looked for once only (see [_relocate])
  bool _readOnce = false;

  /// Whether the share is being looked for on the network, for the message of the page
  bool _relocating = false;

  /// Immuch360 Desktop: the clicks and keys of a selection on the photos and videos, Control A on the splats too
  /// (lib/desktop/selection)
  final _desktopSelection = DesktopNetworkSelectionKey();

  /// The filters of a library of films of a Plex server, while the page shows the films they keep instead of the
  /// folders (lot A2, request 7); null for the folder view
  PlexFilmsQuery? _filmQuery;

  /// The library of films of a Plex server whose folder this is, null for any other folder: the page offers its
  /// filters
  PlexSection? get _filmSection {
    final connection = ref.read(networkConnectionsProvider).opened(widget.sourceId);
    if (connection is! PlexFileSystem) {
      return null;
    }
    final section = connection.sectionAt(widget.path);
    return section != null && section.isFilms ? section : null;
  }

  NetworkFolderKey get _folderKey => (sourceId: widget.sourceId, path: widget.path);

  @override
  void initState() {
    super.initState();
    // The places of drone videos that the server had not read in time are set now that it may have (see
    // VideoLocationService.retryPending): a small file read, and nothing more when it is empty
    try {
      if (ref.read(hasServerProvider)) {
        unawaited(ref.read(videoLocationServiceProvider).retryPending());
      }
    } catch (error) {
      // A chore of the background: the page does not depend on it
      _log.fine('Could not go through the places waiting for the server: $error');
    }
  }

  Future<_Folder> _load() async {
    final first = !_readOnce;
    _readOnce = true;
    try {
      return await _read();
    } on NetworkFileSystemException catch (error) {
      if (!first || !await _relocate(error)) {
        rethrow;
      }
      return _read();
    }
  }

  /// Looks for the share on the network when it was found there (it has a discovery id) and its first reading failed
  /// for another reason than the credentials or a missing folder: a phone or a box given another address by the
  /// router, a media server restarted on another port. True once it answered elsewhere and was saved with its new
  /// address; a share with credentials only once the user accepted the new address (see [_acceptsAddress]).
  Future<bool> _relocate(NetworkFileSystemException error) async {
    final source = ref.read(networkSourceProvider(widget.sourceId));
    if (source == null || source.discoveryId == null || error.isAuthentication || error.isNotFound) {
      return false;
    }
    if (mounted) {
      setState(() => _relocating = true);
    }
    try {
      final relocated = await ref.read(networkSourceRelocatorProvider).relocate(source);
      if (relocated == null || !mounted) {
        return false;
      }
      // DLNA has no authentication. A Plex server only gets its token over the connection pinned to the certificate of
      // the stored hash, and the relocator kept only a server announcing that hash: nothing goes to another one. Any
      // other share would send its user name and password to the new address.
      final asks = relocated.type != NetworkSourceType.dlna && relocated.type != NetworkSourceType.plex;
      if (asks && !await _acceptsAddress(source, relocated)) {
        _log.info('${source.name} was not moved to ${relocated.host}:${relocated.port ?? ''}: the user declined');
        return false;
      }
      _log.info('${source.name} answers at ${relocated.host}:${relocated.port ?? ''} now');
      // A null password keeps the stored one. The source changing closes the connection to the old address.
      await ref.read(networkSourcesProvider.notifier).update(relocated);
      return true;
    } catch (relocationError, stackTrace) {
      _log.warning('Could not look for ${source.name} on the network', relocationError, stackTrace);
      return false;
    } finally {
      if (mounted) {
        setState(() => _relocating = false);
      }
    }
  }

  /// Whether the user accepts to move [source] to the address of [relocated]. The id the share was found by is only
  /// what a device of the network announces, which any other device may announce as well.
  Future<bool> _acceptsAddress(NetworkSource source, NetworkSource relocated) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => ConfirmDialog(
        title: context.t.network_share_relocate_title,
        content: context.t.network_share_relocate_confirm(
          name: source.name,
          previous: networkSourceAddress(source),
          address: networkSourceAddress(relocated),
        ),
        ok: context.t.network_share_save,
      ),
    );
    return accepted == true && mounted;
  }

  Future<_Folder> _read() async {
    final connections = ref.read(networkConnectionsProvider);
    // A folder of the device found gone keeps failing through the connection that found it gone: Retry, a refresh or
    // a new visit read it through a new one, which answers once the folder is back
    await connections.closeIfUnplugged(widget.sourceId);
    final fileSystem = await connections.fileSystem(widget.sourceId);
    final query = _filmQuery;
    final section = fileSystem is PlexFileSystem ? fileSystem.sectionAt(widget.path) : null;
    if (query != null && section != null && fileSystem is PlexFileSystem) {
      return _readFilms(fileSystem, section, query);
    }
    // Hidden entries (".DS_Store", "._IMG.JPG" resource forks, ".thumbnails") and files of other kinds are left out, the
    // same for every folder source (see FolderContents)
    final contents = FolderContents.of(await fileSystem.list(widget.path));
    final media = contents.media;
    final urls = <String, Uri>{};
    for (final entry in media) {
      urls[entry.path] = await connections.mediaUrl(widget.sourceId, entry.path);
    }
    if (mounted) {
      setState(() => _media = media);
    }
    // The platform is asked whether this is a Meta Quest only for a folder that holds .spz or .ply files
    final candidates = contents.splatCandidates;
    final splats = candidates.isNotEmpty && await _splatsShown() ? candidates : const <NetworkEntry>[];
    if (mounted) {
      setState(() => _splats = splats);
    }
    return (folders: contents.folders, media: media, urls: urls, splats: splats);
  }

  /// The films of [section] that [query] keeps, in the server's order, in place of the folders: each under its own path
  /// (plexFilmPath), which its page and the players open
  Future<_Folder> _readFilms(PlexFileSystem fileSystem, PlexSection section, PlexFilmsQuery query) async {
    final connections = ref.read(networkConnectionsProvider);
    final films = await fileSystem.allFilms(section.key, query);
    final media = [for (final film in films) film.entry];
    final urls = <String, Uri>{};
    for (final entry in media) {
      urls[entry.path] = await connections.mediaUrl(widget.sourceId, entry.path);
    }
    if (mounted) {
      setState(() {
        _media = media;
        _splats = const [];
      });
    }
    return (folders: const <NetworkEntry>[], media: media, urls: urls, splats: const <NetworkEntry>[]);
  }

  /// Opens the filters of the library of films of this folder; the films they keep show in place of the folders, the
  /// folders again once they are cleared
  Future<void> _openFilmFilters(PlexSection section) async {
    final picked = await showPlexFilmFilters(
      context,
      ref,
      sourceId: widget.sourceId,
      sectionKey: section.key,
      current: _filmQuery ?? const PlexFilmsQuery(),
    );
    if (picked == null || !mounted) {
      return;
    }
    _setFilmQuery(picked.isFiltered || picked.sort != PlexFilmSort.yearNewest ? picked : null);
  }

  void _setFilmQuery(PlexFilmsQuery? query) {
    if (query == _filmQuery) {
      return;
    }
    ref.read(networkSelectionProvider(_folderKey).notifier).end();
    setState(() {
      _filmQuery = query;
      _folder = _load();
    });
  }

  /// Whether the splats of other tools are listed (see networkSplatsEnabledProvider), once the platform told whether
  /// this is a Meta Quest and whether this build offers them: the folder may be read before it did. The computers,
  /// phones and tablets list them for their splat viewer.
  Future<bool> _splatsShown() async {
    try {
      if (await ref.read(isHorizonOsProvider.future)) {
        if (!await ref.read(splatsInThisBuildProvider.future)) {
          return false;
        }
      } else if (!mounted || !ref.read(splatFlatViewerProvider)) {
        return false;
      }
    } catch (error) {
      _log.fine('Could not tell whether this Meta Quest build shows the splats: $error');
      return false;
    }
    return mounted && ref.read(networkSplatsEnabledProvider);
  }

  /// Reads the folder again; what was shown stays until the new list comes
  Future<void> _refresh() async {
    // The videos that had no frame are tried again
    ref.read(networkVideoThumbnailServiceProvider).forgetFailures();
    ref.invalidate(networkVideoThumbnailProvider);
    final folder = _load();
    setState(() {
      _folder = folder;
    });
    try {
      await folder;
    } catch (_) {
      // Shown in the page
    }
  }

  void _open(NetworkEntry entry, _Folder folder) {
    // Immuch360 Desktop: Control, Shift and the clicks while picking go to the selection
    if (CurrentPlatform.isDesktop && desktopNetworkClick(_desktopSelection, entry)) {
      return;
    }
    final selection = ref.read(networkSelectionProvider(_folderKey));
    if (selection.isActive && !entry.isDirectory) {
      // A tap picks or leaves out while picking files
      ref.read(networkSelectionProvider(_folderKey).notifier).toggle(entry.path);
      return;
    }
    final connection = ref.read(networkConnectionsProvider).opened(widget.sourceId);
    // A film library of a Plex server opens on its films page (lot A1), whose menu shows its folders
    if (entry.isDirectory) {
      final folderPath = _withoutTrailingSlash(entry.path);
      final films = switch (connection) {
        final PlexFilmsSource source => source.filmLibraryAt(folderPath),
        _ => null,
      };
      if (films != null) {
        unawaited(
          context.pushRoute(
            PlexFilmsLibraryRoute(
              sourceId: widget.sourceId,
              sectionKey: films.key,
              title: films.title,
              folderPath: folderPath,
            ),
          ),
        );
        return;
      }
    }
    // A film of a Plex library of films opens its page first (lot A2, request 8); other videos play at once
    final film = !entry.isDirectory && entry.isVideo && connection is PlexFileSystem
        ? connection.itemAt(entry.path)
        : null;
    if (film != null && film.opensFilmPage) {
      unawaited(
        context.pushRoute(PlexFilmRoute(sourceId: widget.sourceId, ratingKey: film.ratingKey, path: entry.path)),
      );
      return;
    }
    // The photo and video pages get the folder around the file, for previous and next in the immersive viewer
    final media = entry.isDirectory
        ? null
        : NetworkFolderMedia(entries: folder.media, urls: folder.urls, index: folder.media.indexOf(entry));
    final PageRouteInfo route = entry.isDirectory
        ? NetworkBrowserRoute(sourceId: widget.sourceId, path: _withoutTrailingSlash(entry.path))
        : entry.isVideo
        ? NetworkVideoRoute(sourceId: widget.sourceId, path: entry.path, folder: media)
        : NetworkPhotoRoute(sourceId: widget.sourceId, path: entry.path, folder: media);
    unawaited(context.pushRoute(route));
  }

  /// Opens the splat [entry]: in the splat viewer at once on a computer, a phone or a tablet that shows it, on its
  /// page otherwise
  void _openSplat(NetworkEntry entry) {
    unawaited(openSplatFile(context, ref, (sourceId: widget.sourceId, path: entry.path, size: entry.size)));
  }

  /// Picks [entry], and starts picking files when the browser was not
  void _select(NetworkEntry entry) {
    final notifier = ref.read(networkSelectionProvider(_folderKey).notifier);
    if (ref.read(networkSelectionProvider(_folderKey)).isActive) {
      notifier.toggle(entry.path);
    } else {
      notifier.start(entry.path);
    }
    if (CurrentPlatform.isDesktop) {
      desktopNetworkAnchor(_desktopSelection, entry);
    }
  }

  /// Whether the picked films may be downloaded to this device: videos of a Plex server, where films are copied
  bool _canDownloadSelection(NetworkSource? source, {required bool tvMode}) =>
      !tvMode &&
      ref.watch(filmDownloadOfferedProvider) &&
      filmDownloadSourceType(source?.type) &&
      _media.any((entry) => entry.isVideo);

  /// Downloads the picked videos: one through the sheet that tells its size and the free room, several straight into
  /// the queue (Download only on Wi-Fi holds them on mobile data)
  Future<void> _downloadSelection() async {
    final selection = ref.read(networkSelectionProvider(_folderKey));
    final videos = [
      for (final entry in _media)
        if (entry.isVideo && selection.contains(entry.path)) entry,
    ];
    if (videos.isEmpty) {
      return;
    }
    ref.read(networkSelectionProvider(_folderKey).notifier).end();
    if (videos.length == 1) {
      await startFilmDownload(context, ref, videos.single);
      return;
    }
    final downloads = ref.read(filmDownloadsProvider.notifier);
    // The question of the notifications of Android 13 and later, as for one film: the copies start either way
    await filmDownloadNotificationsOn(ref);
    for (final entry in videos) {
      await downloads.download(entry);
    }
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.t.film_download_started)));
    }
  }

  Future<void> _upload() async {
    final selection = ref.read(networkSelectionProvider(_folderKey));
    final entries = [
      ..._media.where((entry) => selection.contains(entry.path)),
      ..._readSplats.where((entry) => selection.contains(entry.path)),
    ];
    if (entries.isEmpty) {
      return;
    }
    ref.read(networkSelectionProvider(_folderKey).notifier).end();
    // One splat alone: the sheet of Save to Immich, its poster shown first (plan of 3 November 2026, section 6.2)
    final only = entries.length == 1 ? entries.single : null;
    if (only != null && only.isSplatCandidate && only.size != null) {
      await showSplatSaveSheet(
        context,
        ref,
        SplatSaveScene(path: only.path, length: only.size!, sourceId: widget.sourceId, modified: only.modified),
      );
      return;
    }
    await uploadNetworkEntries(context, ref, widget.sourceId, entries);
  }

  static String _withoutTrailingSlash(String path) =>
      path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;

  /// The name of the folder, or of the share at its start folder
  String _title(NetworkSource? source) {
    final path = _withoutTrailingSlash(widget.path);
    if (source == null) {
      return context.t.network_shares;
    }
    if (path == '/' || path.isEmpty || path == _withoutTrailingSlash(source.rootPath)) {
      return source.name;
    }
    return path.split('/').last;
  }

  @override
  Widget build(BuildContext context) {
    // Immuch360 Desktop: a version "Make 3D (AI)" put in this folder shows at once, with its badge
    // (lib/desktop/ai/creator/share_publisher.dart)
    if (CurrentPlatform.isDesktop) {
      ref.listen(
        shareFolderChangesProvider.select((changes) => changes[shareFolderChangeKey(widget.sourceId, widget.path)]),
        (_, _) => unawaited(_refresh()),
      );
    }
    final source = ref.watch(networkSourceProvider(widget.sourceId));
    final selection = ref.watch(networkSelectionProvider(_folderKey));
    final isUploading = ref.watch(networkUploadProvider.select((upload) => upload.isRunning));
    final selectionNotifier = ref.read(networkSelectionProvider(_folderKey).notifier);
    // On a TV the app is a viewer: no picking files to send to the server
    final tvMode = ref.watch(tvModeProvider);

    return PopScope(
      // Back while picking files stops picking first, and on the films a filter keeps, goes back to the folders
      canPop: !selection.isActive && _filmQuery == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        if (selection.isActive) {
          selectionNotifier.end();
        } else {
          _setFilmQuery(null);
        }
      },
      child: Scaffold(
        appBar: selection.isActive
            ? _selectionAppBar(selection, selectionNotifier)
            : _appBar(source, selectionNotifier, tvMode: tvMode),
        bottomNavigationBar: isUploading
            ? const NetworkUploadProgressBar()
            : selection.isActive
            ? _SelectionBar(
                count: selection.paths.length,
                onUpload: () => unawaited(_upload()),
                downloadAction: _canDownloadSelection(source, tvMode: tvMode)
                    ? IconButton.filledTonal(
                        key: const Key('network_browser_download'),
                        icon: const Icon(Icons.download_rounded),
                        tooltip: context.t.film_download_action,
                        onPressed: selection.paths.isEmpty ? null : () => unawaited(_downloadSelection()),
                      )
                    : null,
                // Immuch360 Desktop: "Make 3D (AI)" next to Upload to Immich (lib/desktop/ai/ui/share_conversion.dart)
                desktopAction: CurrentPlatform.isDesktop
                    ? DesktopShareMakeImmersiveButton(
                        entries: [
                          for (final entry in _media)
                            if (selection.contains(entry.path)) entry,
                        ],
                        onLaunched: selectionNotifier.end,
                      )
                    : null,
              )
            : null,
        body: _buildBody(selection, source, tvMode: tvMode),
      ),
    );
  }

  PreferredSizeWidget _appBar(NetworkSource? source, NetworkSelectionNotifier selection, {required bool tvMode}) {
    final connection = ref.watch(networkConnectionsProvider).opened(widget.sourceId);
    return AppBar(
      title: Text(_title(source)),
      elevation: 0,
      centerTitle: false,
      actions: [
        // The share is read through its address outside home (a Plex server over mobile data): slower, and counted
        // by the server as a remote stream
        if (connection case final NetworkRemoteEndpoint remote when remote.isOutsideHome)
          Tooltip(
            key: const Key('network_browser_remote_endpoint'),
            message: context.t.network_share_remote_endpoint,
            child: const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.public)),
          ),
        // The filters of a library of films of a Plex server (lot A2, request 7)
        if (_filmSection case final PlexSection section)
          IconButton(
            key: const Key('network_browser_plex_filters'),
            icon: Icon(_filmQuery == null ? Icons.filter_list_rounded : Icons.filter_alt_rounded),
            tooltip: context.t.filters,
            onPressed: () => unawaited(_openFilmFilters(section)),
          ),
        // Pull to refresh is a gesture: a remote control gets a button
        if (tvMode)
          IconButton(
            key: const Key('network_browser_refresh'),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: context.t.refresh,
            onPressed: () => unawaited(_refresh()),
          ),
        if ((_media.isNotEmpty || _splats.isNotEmpty) && !tvMode)
          IconButton(
            icon: const Icon(Icons.checklist_rounded),
            tooltip: context.t.network_upload_select,
            onPressed: selection.start,
          ),
      ],
    );
  }

  PreferredSizeWidget _selectionAppBar(NetworkSelection selection, NetworkSelectionNotifier notifier) {
    return AppBar(
      elevation: 0,
      centerTitle: false,
      leading: IconButton(icon: const Icon(Icons.close_rounded), tooltip: context.t.cancel, onPressed: notifier.end),
      title: withDesktopSelectionHint(context, Text(context.t.network_upload_selected(count: selection.paths.length))),
      actions: [
        IconButton(
          icon: const Icon(Icons.select_all_rounded),
          // The splats go too where they are listed, as splat photos
          tooltip: _splats.isEmpty ? context.t.network_upload_select_all : context.t.network_upload_select_all_splats,
          onPressed: () => notifier.toggleAll([..._media, ..._readSplats].map((entry) => entry.path)),
        ),
      ],
    );
  }

  Widget _buildBody(NetworkSelection selection, NetworkSource? source, {required bool tvMode}) {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<_Folder>(
          future: _folder,
          builder: (context, snapshot) {
            // A refresh keeps the folder on screen until the new list comes
            final folder = snapshot.data;
            if (folder != null) {
              return withDesktopNetworkSelection(
                key: _desktopSelection,
                folder: _folderKey,
                // The splats whose head was read come after the photos and videos, as Select all of the bar takes them
                media: () => [..._media, ..._readSplats],
                enabled: !tvMode,
                onUpload: () => unawaited(_upload()),
                child: _FolderView(
                  folder: folder,
                  selection: selection,
                  onOpen: (entry) => _open(entry, folder),
                  onOpenSplat: _openSplat,
                  onSelect: tvMode ? null : _select,
                  focusFirst: tvMode,
                  filmsFiltered: _filmQuery != null,
                  onClearFilms: () => _setFilmQuery(null),
                ),
              );
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return _Filled(
                child: NetworkLoadingView(
                  message: _relocating && source != null
                      ? context.t.network_share_relocating(name: source.name)
                      : context.t.network_share_loading,
                ),
              );
            }
            return _Filled(
              child: NetworkErrorView(
                error: snapshot.error ?? 'unknown error',
                onRetry: () => unawaited(_refresh()),
                source: source,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A tile with its name under it, the title a media server gives when it gives one (a Plex film): the grids whose
/// files have titles. The tile says the name to a screen reader, the caption does not repeat it.
class _Caption extends StatelessWidget {
  const _Caption({required this.entry, required this.child});

  final NetworkEntry entry;
  final Widget child;

  /// The height of the caption under the picture, two lines, with the text scale of [scaler]
  static double heightOf(TextScaler scaler) => 6 + 2 * scaler.scale(12) * 1.25 + 2;

  @override
  Widget build(BuildContext context) {
    final caption = ExcludeSemantics(
      child: Container(
        // Two lines whatever the title, so that the picture above stays square
        height: heightOf(MediaQuery.textScalerOf(context)),
        alignment: AlignmentDirectional.topStart,
        padding: const EdgeInsets.fromLTRB(2, 6, 2, 0),
        child: Text(
          entry.shownName,
          key: const Key('network_media_caption'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, height: 1.25, color: context.colorScheme.onSurface),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: child),
        // The whole title when the pointer rests on it
        if (CurrentPlatform.isDesktop) Tooltip(message: entry.shownName, child: caption) else caption,
      ],
    );
  }
}

/// At the bottom of the browser while picking files: the button that sends them to the server, or why there is none;
/// on a computer, "Make 3D (AI)" next to it ([desktopAction])
class _SelectionBar extends ConsumerWidget {
  const _SelectionBar({required this.count, required this.onUpload, this.desktopAction, this.downloadAction});

  final int count;
  final VoidCallback onUpload;
  final Widget? desktopAction;

  /// Download to this device, for the films of a Plex server (see FilmDownloadsNotifier)
  final Widget? downloadAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasServer = ref.watch(hasServerProvider);
    return Material(
      color: context.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: _withDesktopAction(
            hasServer
                ? FilledButton.icon(
                    icon: const Icon(Icons.backup_outlined),
                    label: Text(context.t.network_upload_action),
                    onPressed: count > 0 ? onUpload : null,
                  )
                : Row(
                    children: [
                      Icon(Icons.info_outline_rounded, color: context.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 12),
                      Expanded(child: Text(context.t.network_upload_needs_server)),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

extension on _SelectionBar {
  /// [upload] alone, or with the action of a computer after it
  Widget _withDesktopAction(Widget upload) {
    final action = desktopAction;
    final download = downloadAction;
    return action == null && download == null
        ? upload
        : Row(
            children: [
              Expanded(child: upload),
              if (download != null) ...[const SizedBox(width: 12), download],
              if (action != null) ...[const SizedBox(width: 12), action],
            ],
          );
  }
}

/// [child] over the whole page, which can still be pulled down to refresh
class _Filled extends StatelessWidget {
  const _Filled({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [SliverFillRemaining(hasScrollBody: false, child: child)],
    );
  }
}

class _FolderView extends StatelessWidget {
  const _FolderView({
    required this.folder,
    required this.selection,
    required this.onOpen,
    required this.onOpenSplat,
    required this.onSelect,
    this.focusFirst = false,
    this.filmsFiltered = false,
    this.onClearFilms,
  });

  /// The films a filter of a Plex library keeps, in place of its folders: their count and Clear above them
  final bool filmsFiltered;
  final VoidCallback? onClearFilms;

  final _Folder folder;
  final NetworkSelection selection;
  final void Function(NetworkEntry entry) onOpen;

  /// A tap on a splat: its page
  final void Function(NetworkEntry entry) onOpenSplat;

  /// A long press on a photo or a video; null on a TV, where nothing is picked
  final void Function(NetworkEntry entry)? onSelect;

  /// A remote control starts on the first folder, else on the first photo or video
  final bool focusFirst;

  @override
  Widget build(BuildContext context) {
    final folders = folder.folders;
    final media = folder.media;
    final filtered = filmsFiltered
        ? _FilmsFilteredBar(count: media.length, onClear: onClearFilms, autofocus: focusFirst && media.isEmpty)
        : null;
    if (folders.isEmpty && media.isEmpty && folder.splats.isEmpty) {
      return filtered == null
          ? const _Filled(child: NetworkEmptyFolderView())
          : _Filled(
              child: Column(
                children: [
                  filtered,
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(context.t.plex_films_filter_empty, textAlign: TextAlign.center),
                      ),
                    ),
                  ),
                ],
              ),
            );
    }
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (filtered != null) SliverToBoxAdapter(child: filtered),
        SliverList.builder(
          itemCount: folders.length,
          itemBuilder: (context, index) {
            final entry = folders[index];
            return NetworkFolderTile(
              key: ValueKey(entry.path),
              entry: entry,
              onTap: () => onOpen(entry),
              autofocus: focusFirst && index == 0,
            );
          },
        ),
        if (media.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 24),
            // The films of a Plex server have their title under the picture, the square kept above it; the other
            // shares keep their square cells
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final captioned = media.any((entry) => entry.title != null);
                final caption = captioned ? _Caption.heightOf(MediaQuery.textScalerOf(context)) : 0.0;
                final columns = (constraints.crossAxisExtent / (160 + 4)).ceil().clamp(1, 1000);
                final cell = (constraints.crossAxisExtent - (columns - 1) * 4) / columns;
                return SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 160,
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                    mainAxisExtent: captioned ? cell + caption : null,
                  ),
                  itemCount: media.length,
                  itemBuilder: (context, index) {
                    final entry = media[index];
                    final tile = NetworkMediaTile(
                      key: ValueKey(entry.path),
                      entry: entry,
                      url: folder.urls[entry.path],
                      onTap: () => onOpen(entry),
                      onLongPress: onSelect == null ? null : () => onSelect!(entry),
                      isSelected: selection.isActive ? selection.contains(entry.path) : null,
                      autofocus: focusFirst && folders.isEmpty && index == 0,
                    );
                    // Immuch360 Desktop: a right click opens the menu of the selection
                    final shown = withDesktopNetworkTile(context, entry, tile);
                    return captioned ? _Caption(entry: entry, child: shown) : shown;
                  },
                );
              },
            ),
          ),
        // The splats after the photos and videos, out of their order (lot S5)
        if (folder.splats.isNotEmpty)
          SplatFileGrid(
            entries: folder.splats,
            // A tap picks or leaves out while picking files, as on a photo
            onOpen: (entry) => selection.isActive && onSelect != null ? onSelect!(entry) : onOpenSplat(entry),
            onSelect: onSelect,
            isSelected: selection.isActive ? (entry) => selection.contains(entry.path) : null,
          ),
      ],
    );
  }
}

/// Above the films a filter of a Plex library keeps: how many, and Clear, which brings the folders back
class _FilmsFilteredBar extends StatelessWidget {
  const _FilmsFilteredBar({required this.count, required this.onClear, this.autofocus = false});

  final int count;
  final VoidCallback? onClear;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('network_browser_films_filtered'),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(context.t.plex_films_filter_count(count: count), style: context.textTheme.titleSmall),
          ),
          TextButton.icon(
            autofocus: autofocus,
            icon: const Icon(Icons.filter_alt_off_rounded),
            label: Text(context.t.clear),
            onPressed: onClear,
          ),
        ],
      ),
    );
  }
}
