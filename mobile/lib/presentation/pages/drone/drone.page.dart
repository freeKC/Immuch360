// The Drone page of the Library (p2/design-final-2026-10-24.md, 2.4), on a phone or a tablet where both DJI functions
// are offered: "DJI live video" and "Photos and videos from the drone". Nothing else: no state, no counter. A device
// with one function never shows it, the Drone card opens that function directly.

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/drone_import_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

@RoutePage()
class DronePage extends ConsumerWidget {
  const DronePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(djiLinkEnabledProvider);
    final photos = ref.watch(droneImportEnabledProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.t.drone_title), elevation: 0, centerTitle: false),
      body: RemoteInitialFocus(
        enabled: ref.watch(tvModeProvider),
        child: SafeArea(
          child: ListView(
            key: const Key('drone_page'),
            padding: const EdgeInsets.only(top: 8, bottom: 32),
            children: [
              const DjiLinkTile(),
              const DroneImportTile(),
              // Reached with both settings off only by an old route: say where they are
              if (!live && !photos)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(context.t.drone_page_none, key: const Key('drone_page_none')),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
