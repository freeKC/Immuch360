import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/film_download.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/network/film_download.widget.dart';
import 'package:immich_mobile/providers/network/film_downloads.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

/// "Downloaded films": the films copied to this device from a Plex server, and the copies under way, with the room
/// they take (request 5 of the Plex films study). A whole copy plays from this device in the usual player, without
/// the server; each one can be deleted, or all of them. The copies under way pause, resume and cancel here, and
/// "Download only on Wi-Fi" (on by default) sits on top, but on the computers, which tell no mobile network.
@RoutePage()
class DownloadedFilmsPage extends ConsumerWidget {
  const DownloadedFilmsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(filmDownloadsProvider);
    final notifier = ref.read(filmDownloadsProvider.notifier);
    final t = context.t;
    final films = downloads.films.reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(t.films_downloaded),
        elevation: 0,
        centerTitle: false,
        actions: [
          if (films.isNotEmpty)
            IconButton(
              key: const Key('downloaded_films_delete_all'),
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: t.films_delete_all,
              onPressed: () => unawaited(_confirmDeleteAll(context, ref, films.length)),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            if (!CurrentPlatform.isDesktop)
              SwitchListTile(
                key: const Key('downloaded_films_wifi_only'),
                value: downloads.wifiOnly,
                onChanged: (value) => unawaited(notifier.setWifiOnly(value)),
                title: Text(t.film_download_wifi_only),
                subtitle: Text(t.film_download_wifi_only_subtitle),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                '${t.films_downloaded_count(count: downloads.done.length)} · '
                '${t.films_downloaded_size(size: formatBytes(downloads.bytesOnDevice))}',
                key: const Key('downloaded_films_total'),
                style: context.textTheme.titleSmall?.copyWith(color: context.primaryColor),
              ),
            ),
            if (!downloads.loaded)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (films.isEmpty)
              Padding(
                key: const Key('downloaded_films_empty'),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Text(
                  t.films_downloaded_empty,
                  style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant),
                ),
              )
            else
              for (final film in films) _FilmTile(film: film, bytesPerSecond: downloads.bytesPerSecond),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteAll(BuildContext context, WidgetRef ref, int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(context.t.films_delete_all_confirm(count: count)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t.cancel)),
          TextButton(
            key: const Key('downloaded_films_delete_all_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(filmDownloadsProvider.notifier).deleteAll();
    }
  }
}

class _FilmTile extends ConsumerWidget {
  const _FilmTile({required this.film, required this.bytesPerSecond});

  final FilmDownload film;
  final double? bytesPerSecond;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(filmDownloadsProvider.notifier);
    final t = context.t;
    final running = film.state == FilmDownloadState.running;
    final Widget leading = film.isDone
        ? const Icon(Icons.movie_outlined)
        : SizedBox.square(
            dimension: 28,
            child: CircularProgressIndicator(value: film.fraction ?? (running ? null : 0), strokeWidth: 3),
          );
    final List<Widget> actions = film.isDone
        ? [
            IconButton(
              key: Key('downloaded_film_delete_${film.id}'),
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: t.camera_clip_delete_copy,
              onPressed: () => unawaited(confirmFilmCopyDeletion(context, ref, film)),
            ),
          ]
        : [
            if (film.isActive)
              IconButton(
                key: Key('downloaded_film_pause_${film.id}'),
                icon: const Icon(Icons.pause_rounded),
                tooltip: t.pause,
                onPressed: () => notifier.pause(film.id),
              )
            else
              IconButton(
                key: Key('downloaded_film_resume_${film.id}'),
                icon: Icon(film.state == FilmDownloadState.failed ? Icons.refresh_rounded : Icons.play_arrow_rounded),
                tooltip: film.state == FilmDownloadState.failed ? t.retry : t.resume,
                onPressed: () => notifier.resume(film.id),
              ),
            IconButton(
              key: Key('downloaded_film_cancel_${film.id}'),
              icon: const Icon(Icons.close_rounded),
              tooltip: t.film_download_cancel,
              onPressed: () => unawaited(notifier.cancel(film.id)),
            ),
          ];
    return ListTile(
      key: Key('downloaded_film_${film.id}'),
      leading: leading,
      title: Text(film.shownTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        filmDownloadStatusText(context, film, bytesPerSecond: running ? bytesPerSecond : null),
        style: film.state == FilmDownloadState.failed ? TextStyle(color: context.colorScheme.error) : null,
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
      // A whole copy plays from this device in the page of the video, which finds it before it asks the server
      onTap: film.isDone
          ? () => unawaited(context.pushRoute(NetworkVideoRoute(sourceId: film.sourceId, path: film.path)))
          : null,
    );
  }
}
