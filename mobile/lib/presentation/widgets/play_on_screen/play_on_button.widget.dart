// "Play on..." as a button of an actions row: the film page of a Plex film (lot A2 of release 45) puts it beside
// Play. It opens the sheet of the linked screens (play_on.sheet.dart) for what [request] gives at the press (the
// position may have moved), and tells [onPlaying] once the film plays on a screen. Hidden where there is nothing to
// send: a TV, the Quest and the computers are the screens, and a file whose rating key is not known has no request.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on.sheet.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';

/// Whether this device sends films to screens: a phone or a tablet, Android or iOS
bool canPlayOnScreens(WidgetRef ref) =>
    !CurrentPlatform.isDesktop && !ref.watch(tvModeProvider) && ref.watch(isHorizonOsProvider).valueOrNull == false;

class PlayOnButton extends ConsumerWidget {
  const PlayOnButton({super.key, required this.request, this.onPlaying, this.tonal = true});

  /// The film at the press; null hides nothing but does nothing either
  final PlayOnRequest? Function() request;
  final VoidCallback? onPlaying;

  /// A tonal button with its label (an actions row), else an icon button (an app bar)
  final bool tonal;

  Future<void> _open(BuildContext context) async {
    final film = request();
    if (film == null) {
      return;
    }
    if (await showPlayOnSheet(context, film)) {
      onPlaying?.call();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!canPlayOnScreens(ref)) {
      return const SizedBox.shrink();
    }
    final label = context.t.play_on_title;
    if (!tonal) {
      return IconButton(
        key: const Key('play_on_button'),
        icon: const Icon(Icons.cast_rounded),
        tooltip: label,
        onPressed: () => unawaited(_open(context)),
      );
    }
    return FilledButton.tonalIcon(
      key: const Key('play_on_button'),
      icon: const Icon(Icons.cast_rounded),
      label: Text(label),
      onPressed: () => unawaited(_open(context)),
    );
  }
}
