// Download in the row after Play of the film page (lot B of the Plex films study, request 5): the button of
// film_download.widget.dart for the file of the film (a plain button on a TV, release 47), nothing for a share that is
// not Plex or while the file is not known yet.

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/pages/network/film_page_actions.dart';
import 'package:immich_mobile/presentation/widgets/network/film_download.widget.dart';

Widget? filmPageDownloadAction(BuildContext context, WidgetRef ref, FilmPageContext film) =>
    filmDownloadPageAction(ref, film.entry, title: film.film.title);
