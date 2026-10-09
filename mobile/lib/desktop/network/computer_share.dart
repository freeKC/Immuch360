// "Share this computer on the network", the desktop side of the phone share (phone_share.page.dart and
// phone_share.provider.dart): the same read only WebDAV server, announcement and credentials, serving the folder
// library (DesktopShareFilesApi), with what a computer needs on top.
//
// - Public networks. The share speaks WebDAV with Basic authentication over plain HTTP: on a laptop in a café or a
//   hotel that would show the user's folders and password to strangers. Windows tells the category the user gave each
//   network (network_category.dart). The share does not start while one of its addresses is on a network marked
//   public, unless the user chooses "Share for this session" for it; a public network joined while the share runs is
//   left out until the user says so on the page (interface_rank.dart decides what the server listens on).
// - The firewall. Windows Defender Firewall asks at the first listening socket whether the app may receive
//   connections; refusing, or a user who is not an administrator, leaves a block rule. The page says so before the
//   first start, and keeps saying it, since a blocked share looks like a headset that cannot find the computer.
//
// Windows only for now: macOS and Linux have no network category in a common API. They get the share once it asks for
// confirmation on a network it has not seen before.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/network/interface_rank.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher.dart';

final _log = Logger('ComputerShare');

/// Whether the share of the computer is offered: on Windows, where the public network rule can be applied
bool get computerShareAvailable => CurrentPlatform.isWindows;

/// Opens the network page of the Windows settings, where the connected network shows its properties and its profile
/// (public or private)
Future<void> openWindowsNetworkSettings() async {
  try {
    await launchUrl(Uri.parse('ms-settings:network-status'));
  } catch (error) {
    _log.warning('The network settings of Windows did not open: $error');
  }
}

/// What the share of the computer reads of the network, replaced in tests
@immutable
class ComputerShareNetwork {
  const ComputerShareNetwork({
    this.candidates = desktopShareCandidates,
    this.openSettings = openWindowsNetworkSettings,
    this.refreshEvery = const Duration(seconds: 10),
  });

  /// The addresses the share could use, before the public network rule
  final Future<List<RankedAddress>> Function() candidates;
  final Future<void> Function() openSettings;

  /// How often the page looks again for a public network while it shows
  final Duration refreshEvery;
}

final computerShareNetworkProvider = Provider<ComputerShareNetwork>((_) => const ComputerShareNetwork());

/// The addresses of public networks the share leaves out now, looked for again while the page shows
final computerSharePublicNetworksProvider = FutureProvider.autoDispose<List<RankedAddress>>((ref) async {
  final network = ref.watch(computerShareNetworkProvider);
  // Again when the share comes up or its addresses change, and every few seconds: joining a network changes nothing
  // the share hears of
  ref.watch(phoneShareProvider.select((state) => (state.status, state.addresses)));
  final again = Timer(network.refreshEvery, ref.invalidateSelf);
  ref.onDispose(again.cancel);
  try {
    return (await network.candidates()).where(isLeftOutAsPublic).toList();
  } catch (error) {
    _log.fine('The networks of the share are not known: $error');
    return const [];
  }
});

/// Asked before the share starts on a computer: false keeps it off. While one of the addresses of the share is on a
/// network Windows marks as public, the user chooses: not now, the Windows settings to mark it private, or sharing on
/// it for this session.
Future<bool> confirmComputerShare(BuildContext context) async {
  final network = ProviderScope.containerOf(context, listen: false).read(computerShareNetworkProvider);
  List<RankedAddress> candidates;
  try {
    candidates = await network.candidates();
  } catch (error) {
    // Nothing is known of the networks: the share would not listen on any address either
    _log.fine('The networks of the share are not known: $error');
    candidates = const [];
  }
  final public = candidates.where(isLeftOutAsPublic).toList();
  if (public.isEmpty) {
    return true;
  }
  if (!context.mounted) {
    return false;
  }
  final answer = await showDialog<_PublicNetworkAnswer>(
    context: context,
    builder: (context) => const _PublicNetworkDialog(),
  );
  switch (answer) {
    case _PublicNetworkAnswer.shareAnyway:
      _log.info('Computer share allowed on a public network for this session');
      allowPublicNetworksForSession(public);
      return true;
    case _PublicNetworkAnswer.settings:
      await network.openSettings();
      return false;
    case _PublicNetworkAnswer.cancel || null:
      return false;
  }
}

enum _PublicNetworkAnswer { cancel, settings, shareAnyway }

/// Under the focus ring of the remote control layout, as the close dialog: its three answers are reached with Tab, and
/// Material only tints a focused button, too faintly to tell which one Enter would choose (design 4.7)
class _PublicNetworkDialog extends StatelessWidget {
  const _PublicNetworkDialog();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return TvFocusRing(
      child: AlertDialog(
        key: const Key('computer_share_public_network'),
        icon: const Icon(Icons.public),
        title: Text(t.desktop_public_network_title),
        content: Text(t.desktop_public_network_body),
        actions: [
          // Not sharing is the answer of a key pressed without reading
          TextButton(
            key: const Key('computer_share_public_network_cancel'),
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(_PublicNetworkAnswer.cancel),
            child: Text(t.cancel),
          ),
          TextButton(
            key: const Key('computer_share_public_network_settings'),
            onPressed: () => Navigator.of(context).pop(_PublicNetworkAnswer.settings),
            child: Text(t.local_session_permission_settings),
          ),
          TextButton(
            key: const Key('computer_share_public_network_anyway'),
            onPressed: () => Navigator.of(context).pop(_PublicNetworkAnswer.shareAnyway),
            child: Text(t.desktop_public_network_share_anyway),
          ),
        ],
      ),
    );
  }
}

/// What the page of the share says on a computer, above its read only notice: the firewall question Windows asks at
/// the first start, and, while the share runs, a public network it leaves out with "Share for this session"
class ComputerShareNotices extends ConsumerWidget {
  const ComputerShareNotices({super.key});

  Future<void> _shareAnyway(WidgetRef ref, List<RankedAddress> public) async {
    allowPublicNetworksForSession(public);
    _log.info('Computer share allowed on a public network for this session');
    final controller = ref.read(phoneShareProvider.notifier);
    final state = ref.read(phoneShareProvider);
    ref.invalidate(computerSharePublicNetworksProvider);
    // The server listens on the new address within seconds by itself; the page would show it within a minute. With
    // nobody connected, a restart shows it at once.
    if (state.status == PhoneShareStatus.on && state.clients == 0) {
      await controller.stop();
      await controller.start();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final isOn = ref.watch(phoneShareProvider.select((state) => state.status == PhoneShareStatus.on));
    final List<RankedAddress> public = isOn
        ? (ref.watch(computerSharePublicNetworksProvider).valueOrNull ?? const [])
        : const [];
    final shade = context.colorScheme.onSurface.withAlpha(180);
    final style = context.textTheme.bodyMedium?.copyWith(color: shade);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (public.isNotEmpty)
          Padding(
            key: const Key('computer_share_public_left_out'),
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.public_off, size: 20, color: context.colorScheme.error),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.desktop_public_network_title, style: context.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(t.desktop_public_network_body, style: style),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton(
                          key: const Key('computer_share_public_left_out_anyway'),
                          onPressed: () => unawaited(_shareAnyway(ref, public)),
                          child: Text(t.desktop_public_network_share_anyway),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (CurrentPlatform.isWindows)
          Padding(
            key: const Key('computer_share_firewall'),
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.shield_outlined, size: 20, color: shade),
                const SizedBox(width: 12),
                Expanded(child: Text(t.desktop_firewall_hint, style: style)),
              ],
            ),
          ),
      ],
    );
  }
}
