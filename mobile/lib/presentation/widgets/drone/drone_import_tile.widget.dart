// The "DJI drone" tile of the Network shares page, under "Share this phone on the network": opens the DJI drone page.
// Shown on Android phones and tablets only (not the Quest build, not the TV layout), while Settings, Advanced, "DJI
// drones (experimental)" is on, as it is by default.

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

/// Whether the DJI drone page can be offered here: an Android phone or tablet, not the Quest build, not the TV layout.
/// Tests replace it.
final droneImportSupportedProvider = Provider.autoDispose<bool>((ref) {
  if (!CurrentPlatform.isAndroid) {
    return false;
  }
  return ref.watch(isHorizonOsProvider).valueOrNull == false && !ref.watch(tvModeProvider);
});

/// Whether the DJI drone tile shows: supported here, and the setting on
final droneImportEnabledProvider = Provider.autoDispose<bool>(
  (ref) => ref.watch(droneImportSupportedProvider) && ref.watch(appConfigProvider.select((c) => c.djiImportEnabled)),
);

class DroneImportTile extends ConsumerWidget {
  const DroneImportTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(droneImportEnabledProvider)) {
      return const SizedBox.shrink();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          key: const Key('drone_import_tile'),
          contentPadding: const EdgeInsets.only(left: 20, right: 8),
          leading: Icon(Icons.flight_rounded, color: context.primaryColor, size: 28),
          title: Text(
            context.t.dji_import_title,
            style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500),
          ),
          subtitle: Text(context.t.dji_import_tile_subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.pushRoute(const DroneImportRoute()),
        ),
        const Divider(height: 1, indent: 20, endIndent: 20),
      ],
    );
  }
}
