// The "Drone" card of the Library (p2/design-final-2026-10-24.md, section 2), beside Network shares: a remote plugged
// into the phone with a cable and a drone's card over USB are not network shares, and a pilot looks for "Drone". On
// phones, tablets and in the Quest window, while one of the two DJI settings is on; not on a TV, iOS or a computer.
// One function offered here opens it directly (the Quest opens the watch page), two open the Drone page.

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/drone_import_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// Where the Drone card goes
enum DroneCardTarget {
  /// No DJI function here: no card
  none,

  /// Two functions: the Drone page lists them
  page,

  /// The live screen of the phone
  live,

  /// The watch page of a headset
  watch,

  /// The DJI drone page, to import photos and videos
  photos,
}

/// One function opens straight away, two open the page, so that a later function on the headset turns the Quest card
/// into the page with no other change
DroneCardTarget droneCardTarget({required bool liveOffered, required bool importOffered, required bool headset}) {
  if (liveOffered && importOffered) {
    return DroneCardTarget.page;
  }
  if (liveOffered) {
    return headset ? DroneCardTarget.watch : DroneCardTarget.live;
  }
  return importOffered ? DroneCardTarget.photos : DroneCardTarget.none;
}

/// The card's target on this device: the import is never offered on the Quest nor the live video on a TV
final droneCardProvider = Provider.autoDispose<DroneCardTarget>(
  (ref) => droneCardTarget(
    liveOffered: ref.watch(djiLinkEnabledProvider),
    importOffered: ref.watch(droneImportEnabledProvider),
    headset: ref.watch(isHorizonOsProvider).valueOrNull ?? false,
  ),
  dependencies: [djiLinkEnabledProvider, droneImportEnabledProvider, isHorizonOsProvider],
);

/// The page or the function the card opens
PageRouteInfo? droneCardRoute(DroneCardTarget target) => switch (target) {
  DroneCardTarget.none => null,
  DroneCardTarget.page => const DroneRoute(),
  DroneCardTarget.live => const DjiLiveRoute(),
  DroneCardTarget.watch => const DjiWatchRoute(),
  DroneCardTarget.photos => const DroneImportRoute(),
};

/// The square card, built as the Network shares one: the primary colour gradient, an aircraft, the label under it. A
/// place, not a status: no picture, no counter.
class DroneCollectionCard extends ConsumerWidget {
  const DroneCollectionCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final route = droneCardRoute(ref.watch(droneCardProvider));
    if (route == null) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final isTablet = constraints.maxWidth > 600;
        final widthFactor = isTablet ? 0.25 : 0.5;
        final size = context.width * widthFactor - 20.0;
        return RemoteFocusable(
          key: const Key('drone_card'),
          onTap: () => context.pushRoute(route),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: size,
                width: size,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.all(Radius.circular(20)),
                    gradient: LinearGradient(
                      colors: [context.colorScheme.primary.withAlpha(30), context.colorScheme.primary.withAlpha(25)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                  child: Center(child: Icon(Icons.flight_rounded, size: size / 3, color: context.primaryColor)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  context.t.drone_title,
                  style: context.textTheme.titleSmall?.copyWith(
                    color: context.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
