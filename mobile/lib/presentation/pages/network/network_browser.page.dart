import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_status.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_upload.widget.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_selection.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// What the browser shows of a folder: its folders, then its photos and videos with their media bridge URLs
typedef _Folder = ({List<NetworkEntry> folders, List<NetworkEntry> media, Map<String, Uri> urls});

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

/// The folders and the photos and videos of a network share, from [path]: tap a folder to go into it, a photo or a
/// video to open it. Files of other kinds are left out. A long press on a photo or a video, or the Select button,
/// picks files to send to the Immich server.
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

  NetworkFolderKey get _folderKey => (sourceId: widget.sourceId, path: widget.path);

  Future<_Folder> _load() async {
    final connections = ref.read(networkConnectionsProvider);
    final fileSystem = await connections.fileSystem(widget.sourceId);
    // Hidden entries (".DS_Store", "._IMG.JPG" resource forks, ".thumbnails") are not media of the share
    final entries = (await fileSystem.list(widget.path)).where((entry) => !entry.name.startsWith('.')).toList();
    final media = entries.where((entry) => entry.isMedia).toList();
    final urls = <String, Uri>{};
    for (final entry in media) {
      urls[entry.path] = await connections.mediaUrl(widget.sourceId, entry.path);
    }
    if (mounted) {
      setState(() => _media = media);
    }
    return (folders: entries.where((entry) => entry.isDirectory).toList(), media: media, urls: urls);
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
    final selection = ref.read(networkSelectionProvider(_folderKey));
    if (selection.isActive && !entry.isDirectory) {
      // A tap picks or leaves out while picking files
      ref.read(networkSelectionProvider(_folderKey).notifier).toggle(entry.path);
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

  /// Picks [entry], and starts picking files when the browser was not
  void _select(NetworkEntry entry) {
    final notifier = ref.read(networkSelectionProvider(_folderKey).notifier);
    if (ref.read(networkSelectionProvider(_folderKey)).isActive) {
      notifier.toggle(entry.path);
    } else {
      notifier.start(entry.path);
    }
  }

  Future<void> _upload() async {
    final selection = ref.read(networkSelectionProvider(_folderKey));
    final entries = _media.where((entry) => selection.contains(entry.path)).toList();
    if (entries.isEmpty) {
      return;
    }
    ref.read(networkSelectionProvider(_folderKey).notifier).end();
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
    final source = ref.watch(networkSourceProvider(widget.sourceId));
    final selection = ref.watch(networkSelectionProvider(_folderKey));
    final isUploading = ref.watch(networkUploadProvider.select((upload) => upload.isRunning));
    final selectionNotifier = ref.read(networkSelectionProvider(_folderKey).notifier);

    return PopScope(
      // Back while picking files stops picking first
      canPop: !selection.isActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          selectionNotifier.end();
        }
      },
      child: Scaffold(
        appBar: selection.isActive
            ? _selectionAppBar(selection, selectionNotifier)
            : _appBar(source, selectionNotifier),
        bottomNavigationBar: isUploading
            ? const NetworkUploadProgressBar()
            : selection.isActive
            ? _SelectionBar(count: selection.paths.length, onUpload: () => unawaited(_upload()))
            : null,
        body: _buildBody(selection),
      ),
    );
  }

  PreferredSizeWidget _appBar(NetworkSource? source, NetworkSelectionNotifier selection) {
    return AppBar(
      title: Text(_title(source)),
      elevation: 0,
      centerTitle: false,
      actions: [
        if (_media.isNotEmpty)
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
      title: Text(context.t.network_upload_selected(count: selection.paths.length)),
      actions: [
        IconButton(
          icon: const Icon(Icons.select_all_rounded),
          tooltip: context.t.network_upload_select_all,
          onPressed: () => notifier.toggleAll(_media.map((entry) => entry.path)),
        ),
      ],
    );
  }

  Widget _buildBody(NetworkSelection selection) {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<_Folder>(
          future: _folder,
          builder: (context, snapshot) {
            // A refresh keeps the folder on screen until the new list comes
            final folder = snapshot.data;
            if (folder != null) {
              return _FolderView(
                folder: folder,
                selection: selection,
                onOpen: (entry) => _open(entry, folder),
                onSelect: _select,
              );
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return _Filled(child: NetworkLoadingView(message: context.t.network_share_loading));
            }
            return _Filled(
              child: NetworkErrorView(error: snapshot.error ?? 'unknown error', onRetry: () => unawaited(_refresh())),
            );
          },
        ),
      ),
    );
  }
}

/// At the bottom of the browser while picking files: the button that sends them to the server, or why there is none
class _SelectionBar extends ConsumerWidget {
  const _SelectionBar({required this.count, required this.onUpload});

  final int count;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasServer = ref.watch(hasServerProvider);
    return Material(
      color: context.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: hasServer
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
  const _FolderView({required this.folder, required this.selection, required this.onOpen, required this.onSelect});

  final _Folder folder;
  final NetworkSelection selection;
  final void Function(NetworkEntry entry) onOpen;

  /// A long press on a photo or a video
  final void Function(NetworkEntry entry) onSelect;

  @override
  Widget build(BuildContext context) {
    final folders = folder.folders;
    final media = folder.media;
    if (folders.isEmpty && media.isEmpty) {
      return const _Filled(child: NetworkEmptyFolderView());
    }
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverList.builder(
          itemCount: folders.length,
          itemBuilder: (context, index) {
            final entry = folders[index];
            return NetworkFolderTile(key: ValueKey(entry.path), entry: entry, onTap: () => onOpen(entry));
          },
        ),
        if (media.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 24),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 160,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
              ),
              itemCount: media.length,
              itemBuilder: (context, index) {
                final entry = media[index];
                return NetworkMediaTile(
                  key: ValueKey(entry.path),
                  entry: entry,
                  url: folder.urls[entry.path],
                  onTap: () => onOpen(entry),
                  onLongPress: () => onSelect(entry),
                  isSelected: selection.isActive ? selection.contains(entry.path) : null,
                );
              },
            ),
          ),
      ],
    );
  }
}
