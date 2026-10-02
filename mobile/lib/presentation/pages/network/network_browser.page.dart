import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_status.widget.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// What the browser shows of a folder: its folders, then its photos and videos with their media bridge URLs
typedef _Folder = ({List<NetworkEntry> folders, List<NetworkEntry> media, Map<String, Uri> urls});

/// The folders and the photos and videos of a network share, from [path]: tap a folder to go into it, a photo or a
/// video to open it. Files of other kinds are left out.
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

  void _open(NetworkEntry entry) {
    final PageRouteInfo route = entry.isDirectory
        ? NetworkBrowserRoute(sourceId: widget.sourceId, path: _withoutTrailingSlash(entry.path))
        : entry.isVideo
        ? NetworkVideoRoute(sourceId: widget.sourceId, path: entry.path)
        : NetworkPhotoRoute(sourceId: widget.sourceId, path: entry.path);
    unawaited(context.pushRoute(route));
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

    return Scaffold(
      appBar: AppBar(title: Text(_title(source)), elevation: 0, centerTitle: false),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: FutureBuilder<_Folder>(
            future: _folder,
            builder: (context, snapshot) {
              // A refresh keeps the folder on screen until the new list comes
              final folder = snapshot.data;
              if (folder != null) {
                return _FolderView(folder: folder, onOpen: _open);
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
  const _FolderView({required this.folder, required this.onOpen});

  final _Folder folder;
  final void Function(NetworkEntry entry) onOpen;

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
                );
              },
            ),
          ),
      ],
    );
  }
}
