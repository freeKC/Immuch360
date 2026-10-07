import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_shares.page.dart';

/// The servers found on the network, above the fields of a new share, Plex server or camera. [filter] keeps the ones
/// the page is about (all of them when null); [scanningText] and [noneFoundText] replace the texts of the share form.
class FoundServersList extends StatelessWidget {
  const FoundServersList({
    super.key,
    required this.servers,
    required this.scanning,
    required this.scanned,
    required this.onScan,
    required this.onSelected,
    this.filter,
    this.scanningText,
    this.noneFoundText,
    this.showEnterByHand = true,
  });

  final List<DiscoveredServer> servers;
  final bool scanning;
  final bool scanned;
  final VoidCallback onScan;
  final ValueChanged<DiscoveredServer> onSelected;
  final bool Function(DiscoveredServer server)? filter;
  final String? scanningText;
  final String? noneFoundText;

  /// The line that tells the fields below take any server
  final bool showEnterByHand;

  @override
  Widget build(BuildContext context) {
    final labelStyle = context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold);
    final hintStyle = context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant);
    final filter = this.filter;
    final shown = filter == null ? servers : servers.where(filter).toList();
    return Column(
      key: const Key('network_share_discovery'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(context.t.network_share_scan_title, style: labelStyle)),
            if (scanning)
              const SizedBox.square(
                key: Key('network_share_scan_progress'),
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              TextButton.icon(
                key: const Key('network_share_scan_again'),
                onPressed: onScan,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(
                  context.t.network_share_scan_again,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        if (shown.isNotEmpty)
          Text(context.t.network_share_scan_tap_to_fill, style: hintStyle)
        else if (scanning)
          Text(scanningText ?? context.t.network_share_scan_scanning, style: hintStyle)
        else if (scanned)
          Text(noneFoundText ?? context.t.network_share_scan_none_found, style: hintStyle),
        for (final server in shown)
          // One address and port may serve several DLNA media servers, whose tiles have the same key
          KeyedSubtree(
            key: ValueKey(server.mergeKey),
            child: ListTile(
              key: Key('network_share_found_${server.type.name}_${server.host}_${server.port}'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(server.isPhoneShare ? Icons.smartphone : networkSourceIcon(server.type)),
              title: Text(server.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                server.host.contains(':') ? '[${server.host}]:${server.port}' : '${server.host}:${server.port}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                server.isPhoneShare
                    ? context.t.network_share_scan_type_phone
                    : switch (server.type) {
                        NetworkSourceType.smb => context.t.network_share_scan_type_smb,
                        NetworkSourceType.webdav => context.t.network_share_scan_type_webdav,
                        NetworkSourceType.dlna => context.t.network_share_scan_type_dlna,
                        NetworkSourceType.plex => context.t.network_share_scan_type_plex,
                        NetworkSourceType.tapo => context.t.network_share_scan_type_tapo,
                      },
                style: context.textTheme.labelMedium?.copyWith(
                  color: context.primaryColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
              onTap: () => onSelected(server),
            ),
          ),
        if (showEnterByHand) ...[
          const SizedBox(height: 8),
          Text(context.t.network_share_scan_enter_by_hand, style: hintStyle),
        ],
        const Divider(height: 24),
      ],
    );
  }
}
