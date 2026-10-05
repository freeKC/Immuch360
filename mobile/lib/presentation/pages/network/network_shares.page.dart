import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/network/phone_share.page.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// Where a share lives, as an address the user would recognise: smb://nas/media, https://cloud.example.com/dav
String networkSourceAddress(NetworkSource source) {
  final port = source.port == null ? '' : ':${source.port}';
  return switch (source.type) {
    NetworkSourceType.smb => 'smb://${source.host}$port/${source.share}',
    // DLNA: the device description URL
    NetworkSourceType.webdav || NetworkSourceType.dlna =>
      '${source.useTls ? 'https' : 'http'}://${source.host}$port'
          '${source.share.isEmpty || source.share.startsWith('/') ? '' : '/'}${source.share}',
  };
}

IconData networkSourceIcon(NetworkSourceType type) => switch (type) {
  NetworkSourceType.smb => Icons.dns_outlined,
  NetworkSourceType.webdav => Icons.cloud_outlined,
  NetworkSourceType.dlna => Icons.perm_media_outlined,
};

/// The network shares the user added (SMB, WebDAV, DLNA media servers): tap one to browse it, add one, edit one
@RoutePage()
class NetworkSharesPage extends ConsumerWidget {
  const NetworkSharesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(networkSourcesProvider);

    void addShare() => context.pushRoute(NetworkShareEditRoute());

    return Scaffold(
      appBar: AppBar(
        title: Text(context.t.network_shares),
        elevation: 0,
        centerTitle: false,
        actions: [
          IconButton(onPressed: addShare, icon: const Icon(Icons.add_rounded), tooltip: context.t.network_share_add),
        ],
      ),
      body: SafeArea(
        child: sources.isEmpty
            // The tile of the phone share first, on phones (it hides itself elsewhere)
            ? Column(
                children: [
                  const PhoneShareTile(),
                  Expanded(child: _NoShares(onAdd: addShare)),
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
                  for (final source in sources) _NetworkShareTile(source: source),
                ],
              ),
      ),
    );
  }
}

class _NetworkShareTile extends StatelessWidget {
  const _NetworkShareTile({required this.source});

  final NetworkSource source;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 20, right: 8),
      leading: Icon(networkSourceIcon(source.type), color: context.primaryColor, size: 28),
      title: Text(source.name, style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500)),
      subtitle: Text(networkSourceAddress(source), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        icon: const Icon(Icons.edit_outlined),
        tooltip: context.t.network_share_edit,
        onPressed: () => context.pushRoute(NetworkShareEditRoute(source: source)),
      ),
      onTap: () => context.pushRoute(NetworkBrowserRoute(sourceId: source.id, path: source.rootPath)),
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
