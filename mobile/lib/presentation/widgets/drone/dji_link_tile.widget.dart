// The "DJI live video" row of the Drone page (p2/design-final-2026-10-24.md, 2.4): on a phone it opens the live
// screen, which reads a DJI remote controller plugged into the phone with a cable. Offered on Android phones and
// tablets, in the Meta Quest build and on Android TV, while Settings, Advanced, "DJI live video (experimental)" is on,
// as it is by default. The Quest and a TV only watch a phone's relay (p2/design-tv-2026-10-24.md, 2.1): their Drone
// card opens the watch page directly. A phone switched to the TV layout keeps hiding it: the live screen is built for
// touch.

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// Whether this device only watches a phone's relay: the Meta Quest (Horizon OS) and a television. It never sends,
/// never takes the cable, and its Drone card opens the watch page directly.
final djiReceiverOnlyProvider = Provider.autoDispose<bool>(
  (ref) => (ref.watch(isHorizonOsProvider).valueOrNull ?? false) || ref.watch(tvDeviceProvider).isTelevision,
  dependencies: [isHorizonOsProvider, tvDeviceProvider],
);

/// Whether the DJI live video can be offered here: an Android phone, tablet or headset out of the TV layout, or a
/// television whatever its layout setting. Tests replace it.
/// The dependencies are declared so that a test, or a part of the app that overrides one of them in a scope of its
/// own, gets this answer from the same override rather than from the real device.
final djiLinkSupportedProvider = Provider.autoDispose<bool>((ref) {
  if (!CurrentPlatform.isAndroid) {
    return false;
  }
  return ref.watch(tvDeviceProvider).isTelevision || !ref.watch(tvModeProvider);
}, dependencies: [tvModeProvider, tvDeviceProvider]);

/// Whether the DJI live video is offered: supported here, and the setting on
final djiLinkEnabledProvider = Provider.autoDispose<bool>(
  (ref) => ref.watch(djiLinkSupportedProvider) && ref.watch(appConfigProvider.select((c) => c.djiLinkEnabled)),
  dependencies: [djiLinkSupportedProvider, appConfigProvider],
);

class DjiLinkTile extends ConsumerWidget {
  const DjiLinkTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(djiLinkEnabledProvider)) {
      return const SizedBox.shrink();
    }
    final receiverOnly = ref.watch(djiReceiverOnlyProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          key: const Key('dji_link_tile'),
          contentPadding: const EdgeInsets.only(left: 20, right: 8),
          leading: Icon(Icons.settings_remote_rounded, color: context.primaryColor, size: 28),
          title: Text(
            context.t.dji_live_title,
            style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500),
          ),
          subtitle: Text(context.t.dji_live_tile_subtitle_phone, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.pushRoute(receiverOnly ? const DjiWatchRoute() : const DjiLiveRoute()),
        ),
        const Divider(height: 1, indent: 20, endIndent: 20),
      ],
    );
  }
}
