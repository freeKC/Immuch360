import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/network/phone_share.page.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// The port of a Plex Media Server when the source has none
const _plexDefaultPort = 32400;

/// Where a share lives, as an address the user would recognise: smb://nas/media, https://cloud.example.com/dav,
/// plex://192.168.1.20:32400, tapo://192.168.1.30. Never a translated sentence: it is shown inside other texts.
String networkSourceAddress(NetworkSource source) {
  final port = source.port == null ? '' : ':${source.port}';
  return switch (source.type) {
    NetworkSourceType.smb => 'smb://${source.host}$port/${source.share}',
    // DLNA: the device description URL
    NetworkSourceType.webdav || NetworkSourceType.dlna =>
      '${source.useTls ? 'https' : 'http'}://${source.host}$port'
          '${source.share.isEmpty || source.share.startsWith('/') ? '' : '/'}${source.share}',
    // A server paired from outside home has no local address: its address outside home then
    NetworkSourceType.plex =>
      source.host.isEmpty && source.plex?.publicHost != null
          ? 'plex://${source.plex!.publicHost}:${source.plex!.publicPort ?? _plexDefaultPort}'
          : 'plex://${source.host}:${source.port ?? _plexDefaultPort}',
    NetworkSourceType.tapo => 'tapo://${source.host}',
  };
}

/// No Plex logo: it is a trade mark
IconData networkSourceIcon(NetworkSourceType type) => switch (type) {
  NetworkSourceType.smb => Icons.dns_outlined,
  NetworkSourceType.webdav => Icons.cloud_outlined,
  NetworkSourceType.dlna => Icons.perm_media_outlined,
  NetworkSourceType.plex => Icons.video_library_outlined,
  NetworkSourceType.tapo => Icons.videocam_outlined,
};

/// The page that opens a source: its own pages for a camera, which is not browsed as folders; the browser at the start
/// folder for a share
PageRouteInfo networkSourceOpenRoute(NetworkSource source) => switch (source.type) {
  NetworkSourceType.tapo => CameraRoute(sourceId: source.id),
  NetworkSourceType.smb ||
  NetworkSourceType.webdav ||
  NetworkSourceType.dlna ||
  NetworkSourceType.plex => NetworkBrowserRoute(sourceId: source.id, path: source.rootPath),
};

/// The page that edits a source; [focusCredentials] opens it on its password or token, after the server refused them
PageRouteInfo networkSourceEditRoute(NetworkSource source, {bool focusCredentials = false}) => switch (source.type) {
  NetworkSourceType.smb || NetworkSourceType.webdav || NetworkSourceType.dlna => NetworkShareEditRoute(source: source),
  NetworkSourceType.plex => PlexServerEditRoute(source: source, focusToken: focusCredentials),
  NetworkSourceType.tapo => CameraEditRoute(source: source),
};

/// Asks what to add (a network share, a Plex Media Server, a Tapo camera) and opens its page
Future<void> _add(BuildContext context) async {
  final route = await showModalBottomSheet<PageRouteInfo>(context: context, builder: (context) => const _AddChoices());
  if (route != null && context.mounted) {
    await context.pushRoute(route);
  }
}

/// The network shares and the cameras the user added (SMB, WebDAV, DLNA media servers, Plex Media Servers, then the
/// Tapo cameras): tap one to open it, add one, edit one
@RoutePage()
class NetworkSharesPage extends ConsumerWidget {
  const NetworkSharesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(networkSourcesProvider);
    final shares = sources.where((source) => source.type != NetworkSourceType.tapo).toList();
    final cameras = sources.where((source) => source.type == NetworkSourceType.tapo).toList();

    void add() => unawaited(_add(context));
    // A remote control starts on the first share, or on the add button when there is none
    final tvMode = ref.watch(tvModeProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(context.t.network_shares),
        elevation: 0,
        centerTitle: false,
        actions: [
          IconButton(onPressed: add, icon: const Icon(Icons.add_rounded), tooltip: context.t.network_share_add),
        ],
      ),
      body: RemoteInitialFocus(
        enabled: tvMode,
        child: SafeArea(
          child: sources.isEmpty
              // The tile of the phone share first, on phones (it hides itself elsewhere)
              ? Column(
                  children: [
                    const PhoneShareTile(),
                    Expanded(child: _NoShares(onAdd: add)),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.only(top: 8, bottom: 32),
                  children: [
                    const PhoneShareTile(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                      child: Text(
                        context.t.network_shares_description,
                        style: context.textTheme.bodyMedium?.copyWith(
                          color: context.colorScheme.onSurface.withAlpha(180),
                        ),
                      ),
                    ),
                    for (final source in shares) _NetworkShareTile(source: source, tvMode: tvMode),
                    if (cameras.isNotEmpty) ...[
                      Padding(
                        key: const Key('network_shares_cameras_header'),
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
                        child: Text(
                          context.t.camera_cameras,
                          style: context.textTheme.titleSmall?.copyWith(
                            color: context.primaryColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      for (final camera in cameras) _CameraTile(source: camera, tvMode: tvMode),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

class _NetworkShareTile extends StatelessWidget {
  const _NetworkShareTile({required this.source, required this.tvMode});

  final NetworkSource source;
  final bool tvMode;

  @override
  Widget build(BuildContext context) {
    return _SourceRow(
      tvMode: tvMode,
      leading: Icon(networkSourceIcon(source.type), color: context.primaryColor, size: 28),
      title: Text(source.name, style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500)),
      subtitle: Text(networkSourceAddress(source), maxLines: 1, overflow: TextOverflow.ellipsis),
      edit: IconButton(
        icon: const Icon(Icons.edit_outlined),
        tooltip: context.t.network_share_edit,
        onPressed: () => context.pushRoute(networkSourceEditRoute(source)),
      ),
      onTap: () => context.pushRoute(networkSourceOpenRoute(source)),
    );
  }
}

/// A row of the list, which opens its source, with the edit button at its end. On a TV the button sits next to the
/// row rather than inside it: the arrows go to what lies beyond the edge of the focused item, and Right from a row
/// found nothing, its button being within the row; the button was reached only with Down from the add button.
class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.tvMode,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.edit,
    required this.onTap,
  });

  final bool tvMode;
  final Widget leading;
  final Widget title;
  final Widget subtitle;
  final Widget edit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tile = ListTile(
      contentPadding: EdgeInsets.only(left: 20, right: tvMode ? 0 : 8),
      leading: leading,
      title: title,
      subtitle: subtitle,
      trailing: tvMode ? null : edit,
      onTap: onTap,
    );
    if (!tvMode) {
      return tile;
    }
    return Row(
      children: [
        Expanded(child: tile),
        Padding(padding: const EdgeInsets.only(right: 8), child: edit),
      ],
    );
  }
}

/// A Tapo camera in the list: its name, its model when known and its address. Nothing read from the camera here:
/// the list would call each camera every time it shows.
class _CameraTile extends StatelessWidget {
  const _CameraTile({required this.source, required this.tvMode});

  final NetworkSource source;
  final bool tvMode;

  @override
  Widget build(BuildContext context) {
    final model = source.camera?.model;
    final address = networkSourceAddress(source);
    return _SourceRow(
      tvMode: tvMode,
      leading: Icon(networkSourceIcon(source.type), color: context.primaryColor, size: 28),
      title: Text(source.name, style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500)),
      subtitle: Text(model == null ? address : '$model, $address', maxLines: 1, overflow: TextOverflow.ellipsis),
      edit: IconButton(
        icon: const Icon(Icons.edit_outlined),
        tooltip: context.t.camera_edit,
        onPressed: () => context.pushRoute(networkSourceEditRoute(source)),
      ),
      onTap: () => context.pushRoute(networkSourceOpenRoute(source)),
    );
  }
}

/// What the add button offers, in a bottom sheet that gives back the route of the page to open
class _AddChoices extends StatelessWidget {
  const _AddChoices();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('network_add_choose_share'),
              leading: const Icon(Icons.lan_outlined),
              title: Text(context.t.network_add_choose_share),
              onTap: () => Navigator.of(context).pop(NetworkShareEditRoute()),
            ),
            ListTile(
              key: const Key('network_add_choose_plex'),
              leading: const Icon(Icons.video_library_outlined),
              title: Text(context.t.network_add_choose_plex),
              onTap: () => Navigator.of(context).pop(PlexServerEditRoute()),
            ),
            ListTile(
              key: const Key('network_add_choose_camera'),
              leading: const Icon(Icons.videocam_outlined),
              title: Text(context.t.network_add_choose_camera),
              onTap: () => Navigator.of(context).pop(CameraEditRoute()),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoShares extends StatelessWidget {
  const _NoShares({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lan_outlined, size: 100, color: context.colorScheme.onSurface.withAlpha(128)),
            const SizedBox(height: 20),
            Text(context.t.network_share_no_shares, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded),
              label: Text(
                context.t.network_share_add,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
