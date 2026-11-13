// Download of a Plex film that has several versions (release 47): the button asks which version to copy, the one Play
// opens first, each with its line ("1080p HEVC, 3.0 GiB"); once a version is being copied or is on the device, the
// button of that copy shows (FilmDownloadButton), with its progress and its menu.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_versions.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/presentation/pages/network/plex_film.page.dart' show plexFilmPlayPath;
import 'package:immich_mobile/presentation/widgets/network/film_download.widget.dart';
import 'package:immich_mobile/providers/network/film_downloads.provider.dart';
import 'package:immich_mobile/providers/network/plex_films.provider.dart';

/// The paths of the versions of [film] (plexFilmVersions), [current] for the version Play opens at [version]
List<String?> plexFilmVersionPaths(PlexFilmDetails film, {required String? current, required int version}) => [
  for (var index = 0; index < plexFilmVersions(film).length; index++)
    index == version ? current : plexFilmPlayPath(film, version: index),
];

class FilmVersionDownloadButton extends ConsumerWidget {
  const FilmVersionDownloadButton({
    super.key,
    required this.film,
    required this.entry,
    required this.paths,
    required this.version,
  });

  final PlexFilmDetails film;

  /// The file Play opens, as the share lists it
  final NetworkEntry entry;

  /// The path of each version (plexFilmVersionPaths)
  final List<String?> paths;

  /// The place of the version Play opens
  final int version;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(filmDownloadsProvider);
    // The copy of the version Play opens first, else of any other one
    final order = [
      version,
      for (var index = 0; index < paths.length; index++)
        if (index != version) index,
    ];
    for (final index in order) {
      final path = paths[index];
      if (path == null || downloads.of(entry.sourceId, path) == null) {
        continue;
      }
      final copied = index == version
          ? entry
          : ref.watch(plexFilmEntryProvider((sourceId: entry.sourceId, path: path))).valueOrNull;
      if (copied != null) {
        return FilmDownloadButton(entry: copied, title: film.title);
      }
    }
    return TextButton.icon(
      key: const Key('film_version_download_button'),
      onPressed: () => unawaited(_choose(context, ref)),
      icon: const Icon(Icons.download_rounded),
      label: Text(context.t.download),
    );
  }

  Future<void> _choose(BuildContext context, WidgetRef ref) async {
    final versions = plexFilmVersions(film);
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        key: const Key('film_version_download_dialog'),
        title: Text(context.t.plex_film_download_which_version),
        children: [
          for (final (index, media) in versions.indexed)
            if (index < paths.length && paths[index] != null)
              SimpleDialogOption(
                key: Key('film_version_download_$index'),
                onPressed: () => Navigator.of(context).pop(index),
                child: Row(
                  children: [
                    Icon(index == version ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded),
                    const SizedBox(width: 12),
                    Expanded(child: Text(plexFilmVersionLabel(media))),
                  ],
                ),
              ),
        ],
      ),
    );
    if (picked == null || !context.mounted) {
      return;
    }
    final NetworkEntry chosen;
    if (picked == version) {
      chosen = entry;
    } else {
      try {
        chosen = await ref.read(plexFilmEntryProvider((sourceId: entry.sourceId, path: paths[picked]!)).future);
      } catch (_) {
        // The server does not answer: its own error shows at the next read
        return;
      }
    }
    if (context.mounted) {
      await startFilmDownload(context, ref, chosen, title: film.title);
    }
  }
}
