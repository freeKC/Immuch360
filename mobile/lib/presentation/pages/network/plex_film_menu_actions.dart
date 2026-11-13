// What the long press menu of a poster of the films page (lot A1) offers after Play, from the lots that came after it:
// Download to this device (lot B, Android TV too since release 47) and "Play on..." (lot C, phones and tablets), the
// same actions as the row after Play of the film page (film_page_actions.dart). Read by plexFilmMenuActionsProvider.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/network/film_download.widget.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on.sheet.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on_button.widget.dart';
import 'package:immich_mobile/providers/network/film_downloads.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/network/plex_film_list.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';

/// The lines of the menu after Play, in order
const List<PlexFilmMenuAction> plexFilmMenuActions = [
  PlexFilmMenuAction(
    icon: Icons.download_rounded,
    label: _downloadLabel,
    onSelected: _download,
    isShown: _downloadShown,
  ),
  PlexFilmMenuAction(icon: Icons.cast_rounded, label: _playOnLabel, onSelected: _playOn, isShown: _playOnShown),
];

String _downloadLabel(BuildContext context) => context.t.film_download_action;

/// A video of a Plex server on a screen that copies films, without a copy on its way or whole already
bool _downloadShown(WidgetRef ref, PlexFilmMenuTarget target) {
  if (!canDownloadFilm(ref, target.sourceId, target.entry, watch: false)) {
    return false;
  }
  final known = ref.read(filmDownloadsProvider).of(target.sourceId, target.entry.path);
  return known == null || !(known.isActive || known.isDone);
}

Future<void> _download(BuildContext context, WidgetRef ref, PlexFilmMenuTarget target) =>
    startFilmDownload(context, ref, target.entry, title: target.film.title);

String _playOnLabel(BuildContext context) => context.t.play_on_title;

bool _playOnShown(WidgetRef ref, PlexFilmMenuTarget target) => canPlayOnScreens(ref, watch: false);

/// The sheet of the linked screens for the film, from where Plex has it
Future<void> _playOn(BuildContext context, WidgetRef ref, PlexFilmMenuTarget target) async {
  final request = PlayOnRequest.ofItem(
    source: ref.read(networkSourceProvider(target.sourceId)),
    ratingKey: target.film.ratingKey,
    title: target.film.title,
    offsetMs: target.film.viewOffsetMs ?? 0,
    path: target.entry.path,
  );
  if (request != null) {
    await showPlayOnSheet(context, request);
  }
}
