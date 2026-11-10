// The pieces of "Download" of a Plex film on the screens (request 5 of the Plex films study): the sheet that starts a
// copy (the size, the free room, Wi-Fi only, iPhone kept open), the entries of a menu, a button with its progress for
// the film page of lot A2, the mark of a tile, and the tile of the Network shares page that opens the list.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/film_download.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/film_download/film_download_rules.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/network_capability_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/film_downloads.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

/// Whether this screen copies films: never on a TV (see filmDownloadOffered)
final filmDownloadOfferedProvider = Provider.autoDispose<bool>(
  (ref) => filmDownloadOffered(
    tvMode: ref.watch(tvModeProvider),
    isAndroid: CurrentPlatform.isAndroid,
    isIOS: CurrentPlatform.isIOS,
    isDesktop: CurrentPlatform.isDesktop,
  ),
);

/// Whether [entry] of the share [sourceId] can be downloaded here: a video of a Plex server, on a screen that copies
/// films. [watch] in a build method, read elsewhere (a menu being opened).
bool canDownloadFilm(WidgetRef ref, String sourceId, NetworkEntry entry, {bool watch = true}) {
  if (!entry.isVideo || entry.isDirectory) {
    return false;
  }
  final offered = watch ? ref.watch(filmDownloadOfferedProvider) : ref.read(filmDownloadOfferedProvider);
  if (!offered) {
    return false;
  }
  final source = watch ? ref.watch(networkSourceProvider(sourceId)) : ref.read(networkSourceProvider(sourceId));
  return filmDownloadSourceType(source?.type);
}

/// The line of a copy under way or stopped: its progress, why it waits or why it stopped
String filmDownloadStatusText(BuildContext context, FilmDownload film, {double? bytesPerSecond}) {
  final t = context.t;
  final size = film.size;
  final progress = size == null
      ? formatBytes(film.received)
      : t.film_download_progress(done: formatBytes(film.received), total: formatBytes(size));
  return switch (film.state) {
    FilmDownloadState.done => size == null ? t.film_downloaded : '${t.film_downloaded} · ${formatBytes(size)}',
    FilmDownloadState.running => [
      if (size != null && size > 0) '${(film.received * 100 / size).floor()} %',
      progress,
      if (size != null && bytesPerSecond != null && bytesPerSecond > 0)
        t.film_download_time_left(minutes: '${((size - film.received) / bytesPerSecond / 60).ceil().clamp(1, 99999)}'),
    ].join(' · '),
    FilmDownloadState.queued => '${t.film_download_queued} · $progress',
    FilmDownloadState.waitingForWifi => '${t.film_download_waiting_wifi} · $progress',
    FilmDownloadState.paused => '${t.film_download_paused} · $progress',
    FilmDownloadState.failed => filmDownloadFailureText(context, film.failure),
  };
}

/// Why a copy stopped, in one sentence
String filmDownloadFailureText(BuildContext context, FilmDownloadFailure? failure) => switch (failure) {
  FilmDownloadFailure.forbidden => context.t.film_download_forbidden,
  FilmDownloadFailure.noSpace => context.t.film_download_disk_full,
  FilmDownloadFailure.unreachable => context.t.film_download_unreachable,
  FilmDownloadFailure.gone => context.t.film_download_gone,
  FilmDownloadFailure.failed || null => context.t.download_failed,
};

/// What the sheet chose: start, and whether over mobile data this time
typedef FilmDownloadChoice = ({bool mobileDataThisTime});

/// Asks for the copy of [entry] in a sheet, then starts it; [title] is the one to show (the films page gives the Plex
/// title). Tells with a snack bar once it is asked.
Future<void> startFilmDownload(BuildContext context, WidgetRef ref, NetworkEntry entry, {String? title}) async {
  final notifier = ref.read(filmDownloadsProvider.notifier);
  final known = ref.read(filmDownloadsProvider).of(entry.sourceId, entry.path);
  if (known != null && (known.isActive || known.isDone)) {
    return;
  }
  final free = await notifier.freeBytes();
  final folder = CurrentPlatform.isDesktop ? await notifier.folderPath() : null;
  var onMobileData = false;
  if (!CurrentPlatform.isDesktop) {
    try {
      final capabilities = await ref.read(connectivityApiProvider).getCapabilities();
      onMobileData = capabilities.hasCellular && !capabilities.hasWifi;
    } catch (_) {
      // Unknown: no choice of mobile data
    }
  }
  if (!context.mounted) {
    return;
  }
  final wifiOnly = ref.read(filmDownloadsProvider).wifiOnly;
  final choice = await showModalBottomSheet<FilmDownloadChoice>(
    context: context,
    isScrollControlled: true,
    builder: (context) => FilmDownloadSheet(
      title: title ?? entry.name,
      size: entry.size,
      have: known?.received ?? 0,
      free: free,
      folder: folder,
      askMobileData: onMobileData && wifiOnly,
      keepOpen: filmDownloadNeedsAppOpen(isIOS: CurrentPlatform.isIOS),
    ),
  );
  if (choice == null) {
    return;
  }
  await notifier.download(entry, title: title, mobileDataThisTime: choice.mobileDataThisTime);
  if (context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.t.film_download_started)));
  }
}

/// The sheet before a copy: the size of the original file, the free room (a copy that does not fit cannot start), where
/// it goes, "Download over mobile data this time" on mobile data with Wi-Fi only on, and on iPhone and iPad the advice to
/// keep the app open
class FilmDownloadSheet extends StatefulWidget {
  const FilmDownloadSheet({
    super.key,
    required this.title,
    required this.size,
    required this.have,
    required this.free,
    required this.folder,
    required this.askMobileData,
    required this.keepOpen,
  });

  final String title;
  final int? size;
  final int have;
  final int? free;

  /// The download folder of a computer, null elsewhere
  final String? folder;
  final bool askMobileData;
  final bool keepOpen;

  @override
  State<FilmDownloadSheet> createState() => _FilmDownloadSheetState();
}

class _FilmDownloadSheetState extends State<FilmDownloadSheet> {
  bool _mobileData = false;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final size = widget.size;
    final free = widget.free;
    final room = filmDownloadRoom(size: size, have: widget.have, free: free);
    final folder = widget.folder;
    final secondary = context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant);
    // On mobile data with Wi-Fi only, a copy asked without "this time" waits for the Wi-Fi
    final mayStart = room != FilmDownloadRoom.notEnough;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: context.textTheme.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            if (size != null) Text(t.film_download_original(size: formatBytes(size))),
            if (free != null) Text(t.film_download_free(size: formatBytes(free)), style: secondary),
            if (room == FilmDownloadRoom.notEnough && size != null && free != null)
              Padding(
                key: const Key('film_download_no_space'),
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  t.film_download_no_space(
                    needed: formatBytes(size - widget.have + filmDownloadSpareBytes),
                    free: formatBytes(free),
                  ),
                  style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              folder == null ? t.film_download_where_app : t.film_download_where_computer(folder: folder),
              style: secondary,
            ),
            if (widget.keepOpen)
              Padding(
                key: const Key('film_download_keep_open'),
                padding: const EdgeInsets.only(top: 8),
                child: Text(t.film_download_keep_open, style: secondary),
              ),
            if (widget.askMobileData)
              CheckboxListTile(
                key: const Key('film_download_mobile_once'),
                contentPadding: EdgeInsets.zero,
                value: _mobileData,
                onChanged: (value) => setState(() => _mobileData = value ?? false),
                title: Text(t.film_download_mobile_once),
                subtitle: Text(t.film_download_wifi_only_subtitle),
              ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.cancel)),
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const Key('film_download_start'),
                  onPressed: mayStart ? () => Navigator.of(context).pop((mobileDataThisTime: _mobileData)) : null,
                  icon: const Icon(Icons.download_rounded),
                  label: Text(t.download),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The entries of the menu of a video page for the copy of [entry] on this device: Download, or Pause, Resume and
/// Cancel while it is copied, or Delete the copy once whole. Empty where films are not copied. Built as the menu opens,
/// from what the list holds then.
List<PopupMenuEntry<void>> filmDownloadMenuItems(
  BuildContext context,
  WidgetRef ref,
  NetworkEntry entry, {
  String? title,
}) {
  if (!canDownloadFilm(ref, entry.sourceId, entry, watch: false)) {
    return const [];
  }
  final film = ref.read(filmDownloadsProvider).of(entry.sourceId, entry.path);
  final notifier = ref.read(filmDownloadsProvider.notifier);
  PopupMenuItem<void> item(Key key, IconData icon, String text, VoidCallback onTap) => PopupMenuItem<void>(
    key: key,
    onTap: onTap,
    child: ListTile(leading: Icon(icon), title: Text(text), contentPadding: EdgeInsets.zero),
  );
  if (film == null) {
    return [
      item(
        const Key('film_download_menu_download'),
        Icons.download_rounded,
        context.t.film_download_action,
        () => unawaited(startFilmDownload(context, ref, entry, title: title)),
      ),
    ];
  }
  if (film.isDone) {
    return [
      item(
        const Key('film_download_menu_delete'),
        Icons.delete_outline_rounded,
        context.t.camera_clip_delete_copy,
        () => unawaited(confirmFilmCopyDeletion(context, ref, film)),
      ),
    ];
  }
  return [
    if (film.isActive)
      item(const Key('film_download_menu_pause'), Icons.pause_rounded, context.t.pause, () => notifier.pause(film.id))
    else
      item(
        const Key('film_download_menu_resume'),
        Icons.download_rounded,
        context.t.resume,
        () => notifier.resume(film.id),
      ),
    item(
      const Key('film_download_menu_cancel'),
      Icons.close_rounded,
      context.t.film_download_cancel,
      () => unawaited(notifier.cancel(film.id)),
    ),
  ];
}

/// Asks before the copy of [film] is deleted from this device, then deletes it
Future<void> confirmFilmCopyDeletion(BuildContext context, WidgetRef ref, FilmDownload film) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      content: Text(context.t.film_download_delete_confirm(name: film.shownTitle)),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t.cancel)),
        TextButton(
          key: const Key('film_download_delete_confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(context.t.delete),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await ref.read(filmDownloadsProvider.notifier).delete(film.id);
  }
}

/// The Download button of the film page (lot A2 puts it in its row of actions): Download, then a ring with the
/// percentage while the film is copied (a tap offers Pause or Resume and Cancel), then Downloaded with a check (a tap
/// offers Delete the copy). Nothing where films are not copied (a TV, a share that is not Plex).
class FilmDownloadButton extends ConsumerWidget {
  const FilmDownloadButton({super.key, required this.entry, this.title});

  final NetworkEntry entry;

  /// The title to show in the sheet and the list, null for the file name
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!canDownloadFilm(ref, entry.sourceId, entry)) {
      return const SizedBox.shrink();
    }
    final film = ref.watch(filmDownloadsProvider.select((state) => state.of(entry.sourceId, entry.path)));
    final t = context.t;
    if (film == null) {
      return TextButton.icon(
        key: const Key('film_download_button'),
        onPressed: () => unawaited(startFilmDownload(context, ref, entry, title: title)),
        icon: const Icon(Icons.download_rounded),
        label: Text(t.download),
      );
    }
    final fraction = film.fraction;
    final Widget icon = film.isDone
        ? const Icon(Icons.download_done_rounded)
        : SizedBox.square(dimension: 20, child: CircularProgressIndicator(value: fraction, strokeWidth: 2.5));
    final label = film.isDone
        ? t.film_downloaded
        : film.state == FilmDownloadState.failed
        ? t.download_failed
        : fraction == null
        ? t.downloading
        : '${(fraction * 100).floor()} %';
    return PopupMenuButton<void>(
      key: const Key('film_download_button'),
      tooltip: film.isDone ? t.film_downloaded : filmDownloadStatusText(context, film),
      // The button's context: the sheet and the dialog open once the menu is gone
      itemBuilder: (_) => filmDownloadMenuItems(context, ref, entry, title: title),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [icon, const SizedBox(width: 8), Text(label)]),
      ),
    );
  }
}

/// The mark of a tile whose film is on this device, or being copied: a check, or a small ring with the progress
class FilmDownloadMark extends ConsumerWidget {
  const FilmDownloadMark({super.key, required this.entry});

  final NetworkEntry entry;

  static const _shadows = [Shadow(blurRadius: 4)];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final film = ref.watch(filmDownloadsProvider.select((state) => state.of(entry.sourceId, entry.path)));
    if (film == null || film.state == FilmDownloadState.failed) {
      return const SizedBox.shrink();
    }
    if (film.isDone) {
      return Tooltip(
        key: const Key('film_download_mark_done'),
        message: context.t.on_this_device,
        child: const Icon(Icons.download_done_rounded, color: Colors.white, size: 18, shadows: _shadows),
      );
    }
    return SizedBox.square(
      key: const Key('film_download_mark_running'),
      dimension: 16,
      child: CircularProgressIndicator(
        value: film.fraction,
        strokeWidth: 2,
        color: Colors.white,
        backgroundColor: Colors.black38,
      ),
    );
  }
}

/// "Downloaded films" on the Network shares page, with the count and the room they take: shown where films are copied,
/// once a Plex server is there or a film is on this device. Reading the list here also lets a copy cut by the end of
/// the app go on.
class DownloadedFilmsTile extends ConsumerWidget {
  const DownloadedFilmsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(filmDownloadOfferedProvider)) {
      return const SizedBox.shrink();
    }
    final downloads = ref.watch(filmDownloadsProvider);
    final hasPlex = ref.watch(
      networkSourcesProvider.select((sources) => sources.any((source) => filmDownloadSourceType(source.type))),
    );
    if (!hasPlex && downloads.films.isEmpty) {
      return const SizedBox.shrink();
    }
    final count = downloads.done.length;
    return ListTile(
      key: const Key('downloaded_films_tile'),
      contentPadding: const EdgeInsets.only(left: 20, right: 8),
      leading: const Icon(Icons.download_for_offline_outlined),
      title: Text(context.t.films_downloaded),
      subtitle: Text(
        '${context.t.films_downloaded_count(count: count)} · '
        '${context.t.films_downloaded_size(size: formatBytes(downloads.bytesOnDevice))}',
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => unawaited(context.pushRoute(const DownloadedFilmsRoute())),
    );
  }
}
