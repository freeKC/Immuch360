// "View in headset" in the controls of the players (headset_view.dart), next to the audio and subtitle track buttons:
// the Immich viewer (VideoControls), the network page (NetworkVideoControls) and the 360 player (SphericalControls).
// It shows only where it can be of use: the switch of Settings, Videos on, Windows, a build with the plugin's option,
// an OpenXR runtime registered on this computer, and a page whose video can go to the headset. The menu: the layouts
// the page offers (around you for a 360 video; on a flat screen in 2D, 3D side by side or 3D over under for a film,
// the one its file name tells marked), or "Not available for this file yet" in their place (a raw 360 file drawn by two
// players), then while a view runs its state, Recenter, Lying down and Stop.
//
// Keyboard, in every player: H starts the marked layout or stops the view, Shift+H recenters (DesktopShell, through
// desktopWindowKeyOf; no viewer or player of the app uses H).

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/xr/headset_view.dart';
import 'package:immich_mobile/desktop/video/xr/headset_view_service.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// The label of [choice] in the menu
String headsetChoiceLabel(Translations t, HeadsetChoice choice) => switch (choice) {
  HeadsetChoice.around => t.headset_view_around,
  HeadsetChoice.screen2d => t.headset_view_screen_2d,
  HeadsetChoice.screenSideBySide => t.headset_view_screen_sbs,
  HeadsetChoice.screenOverUnder => t.headset_view_screen_ou,
};

sealed class _Item {
  const _Item();
}

class _Choice extends _Item {
  const _Choice(this.choice);
  final HeadsetChoice choice;
}

class _Recenter extends _Item {
  const _Recenter();
}

class _LyingDown extends _Item {
  const _LyingDown();
}

class _Stop extends _Item {
  const _Stop();
}

class HeadsetViewButton extends ConsumerWidget {
  const HeadsetViewButton({super.key, this.shadows, this.color = Colors.white});

  final List<Shadow>? shadows;

  /// The icon's colour: white over a video
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(headsetViewServiceProvider);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final target = service.target;
        if (target == null || !service.available) {
          return const SizedBox.shrink();
        }
        final t = context.t;
        final running = service.running;
        final marked = running && identical(service.shown, target) ? service.choice : target.preselected();
        // Read when the menu opens: the page's video may have changed since this build
        bool notAvailable() => target.notAvailable?.call() != null;
        return PopupMenuButton<_Item>(
          key: const Key('headset_view_button'),
          tooltip: running && service.statusText.isNotEmpty ? service.statusText : t.headset_view_button,
          icon: Icon(running ? Icons.view_in_ar : Icons.view_in_ar_outlined, color: color, shadows: shadows),
          onSelected: (item) => unawaited(_on(service, item, context.locale)),
          itemBuilder: (context) => [
            if (running && service.statusText.isNotEmpty)
              PopupMenuItem<_Item>(
                key: const Key('headset_view_status'),
                enabled: false,
                child: Text(service.statusText),
              ),
            if (notAvailable())
              PopupMenuItem<_Item>(
                key: const Key('headset_view_not_available'),
                enabled: false,
                child: Text(t.headset_view_not_available),
              )
            else
              for (final choice in target.choices)
                CheckedPopupMenuItem<_Item>(
                  key: Key('headset_view_${choice.name}'),
                  value: _Choice(choice),
                  checked: choice == marked,
                  child: Text(headsetChoiceLabel(t, choice)),
                ),
            if (running) ...[
              const PopupMenuDivider(),
              PopupMenuItem<_Item>(
                key: const Key('headset_view_recenter'),
                value: const _Recenter(),
                child: Text(t.headset_view_recenter),
              ),
              CheckedPopupMenuItem<_Item>(
                key: const Key('headset_view_lying_down'),
                value: const _LyingDown(),
                checked: service.lyingDown,
                child: Text(t.headset_view_lying_down),
              ),
              PopupMenuItem<_Item>(
                key: const Key('headset_view_stop'),
                value: const _Stop(),
                child: Text(t.headset_view_stop),
              ),
            ],
          ],
        );
      },
    );
  }

  static Future<void> _on(HeadsetViewService service, _Item item, Locale locale) => switch (item) {
    _Choice(:final choice) => service.start(choice, locale: locale),
    _Recenter() => service.recenter(),
    _LyingDown() => service.setLyingDown(!service.lyingDown),
    _Stop() => service.stop(),
  };
}
