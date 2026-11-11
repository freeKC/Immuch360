// "Play on..." in the row after Play of the film page (lot C of the Plex films study, request 9): the film by its
// rating key, from where Plex has it, on a linked screen.

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/pages/network/film_page_actions.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on_button.widget.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';

/// "Play on..." after Play: the film by its rating key, from where it was left; hidden on a TV, the Quest and computers
Widget? playOnFilmAction(BuildContext context, WidgetRef ref, FilmPageContext film) => PlayOnButton(
  request: () => PlayOnRequest.ofItem(
    source: ref.read(networkSourceProvider(film.sourceId)),
    ratingKey: film.film.ratingKey,
    title: film.film.title,
    offsetMs: film.film.viewOffsetMs ?? 0,
    path: film.path,
  ),
);
