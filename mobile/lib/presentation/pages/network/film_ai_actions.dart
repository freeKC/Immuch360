// "Make 3D (AI)" and "Make a splat scene (AI)" of a film of a media server (release 53): in the row after Play of the
// Plex film page (a builder of filmPageActions, film_page_actions.dart) and of the page of a Jellyfin or Emby film
// (media_server_item.page.dart), on a computer, as the menu of the page of a video of a share offers them
// (network_video.page.dart). The dialogs are those of a video of a share: the film is copied by its job and the
// result goes to the folder of my choice, said in the dialog before anything runs.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart' show ConversionKind;
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart'
    show aiFeaturesEnabledProvider, offeredConversionKindsProvider;
import 'package:immich_mobile/desktop/ai/ui/share_conversion.dart' show shareConversionOpenerProvider;
import 'package:immich_mobile/desktop/ai/ui/splat_dialog.dart' show aiSplatScenesOnProvider, shareSplatOpenerProvider;
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/network/film_page_actions.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

/// What a film page offers of the AI: on a computer only (never a phone, a TV or a Quest), as the page of a video
/// of a share
({bool make3d, bool splat}) filmAiOffers(WidgetRef ref) {
  final desktop = CurrentPlatform.isDesktop && !ref.watch(tvModeProvider);
  return (
    make3d:
        desktop &&
        ref.watch(aiFeaturesEnabledProvider) &&
        ref.watch(offeredConversionKindsProvider).contains(ConversionKind.stereoVideo),
    splat: desktop && ref.watch(aiSplatScenesOnProvider),
  );
}

/// The AI buttons of the row after Play of a film page; [entryOf] gives the file of the film once a button is pressed
/// (null when the share does not know it: nothing opens)
class FilmAiButtons extends ConsumerWidget {
  const FilmAiButtons({super.key, required this.entryOf});

  final Future<NetworkEntry?> Function() entryOf;

  Future<void> _open(
    BuildContext context,
    Future<bool> Function(BuildContext context, List<NetworkEntry> entries) opener,
  ) async {
    final entry = await entryOf();
    if (entry == null || !context.mounted) {
      return;
    }
    await opener(context, [entry]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offers = filmAiOffers(ref);
    if (!offers.make3d && !offers.splat) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        if (offers.make3d)
          TextButton.icon(
            key: const Key('film_ai_make_3d'),
            icon: const Icon(Icons.view_in_ar_outlined),
            label: Text(context.t.ai_immersive_make_3d),
            onPressed: () => unawaited(_open(context, ref.read(shareConversionOpenerProvider))),
          ),
        if (offers.splat)
          TextButton.icon(
            key: const Key('film_ai_make_splat'),
            icon: const Icon(Icons.scatter_plot_outlined),
            label: Text(context.t.ai_immersive_splat_make),
            onPressed: () => unawaited(_open(context, ref.read(shareSplatOpenerProvider))),
          ),
      ],
    );
  }
}

/// The AI buttons of the Plex film page, once the share listed the file of the film
Widget? filmPageAiAction(BuildContext context, WidgetRef ref, FilmPageContext film) {
  final entry = film.entry;
  final offers = filmAiOffers(ref);
  if (entry == null || (!offers.make3d && !offers.splat)) {
    return null;
  }
  return FilmAiButtons(entryOf: () async => entry);
}
