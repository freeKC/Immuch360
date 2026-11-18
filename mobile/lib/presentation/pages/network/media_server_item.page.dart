import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/media_server_item.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/duration_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/images/guarded_image.dart';
import 'package:immich_mobile/presentation/widgets/network/network_status.widget.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// The open connection of [sourceId] as a server of films and series (a Jellyfin or Emby server)
final mediaServerSourceProvider = FutureProvider.autoDispose.family<MediaServerItemSource, String>((
  ref,
  sourceId,
) async {
  final fileSystem = await ref.watch(networkConnectionsProvider).fileSystem(sourceId);
  if (fileSystem is! MediaServerItemSource) {
    throw const NetworkFileSystemException('This share has no film pages');
  }
  return fileSystem as MediaServerItemSource;
});

typedef MediaServerItemKey = ({String sourceId, String itemId});

/// The item of a page, read again each time the page opens (its place may have moved in another app)
final mediaServerItemProvider = FutureProvider.autoDispose.family<MediaServerItem, MediaServerItemKey>((
  ref,
  key,
) async {
  final source = await ref.watch(mediaServerSourceProvider(key.sourceId).future);
  return source.itemDetails(key.itemId);
});

/// The streams of a file in one line: "HEVC 2160p, TrueHD 7.1, 3 audio tracks, half side by side 3D"
String mediaServerStreamsLine(BuildContext context, MediaServerItem item) {
  String codecName(String codec) => switch (codec) {
    'h264' || 'avc' => 'H.264',
    'hevc' || 'h265' => 'HEVC',
    'av1' => 'AV1',
    'vp9' => 'VP9',
    'mpeg4' => 'MPEG-4',
    'vc1' => 'VC-1',
    'aac' => 'AAC',
    'ac3' => 'AC-3',
    'eac3' => 'E-AC-3',
    'dts' || 'dca' => 'DTS',
    'truehd' => 'TrueHD',
    'flac' => 'FLAC',
    'opus' => 'Opus',
    'mp3' => 'MP3',
    final other => other.toUpperCase(),
  };
  String? resolution(int? height) => height == null
      ? null
      : height >= 2000
      ? '2160p'
      : height >= 1000
      ? '1080p'
      : height >= 700
      ? '720p'
      : '${height}p';
  String channels(int count) => switch (count) {
    1 => '1.0',
    2 => '2.0',
    6 => '5.1',
    8 => '7.1',
    _ => '$count ch',
  };
  final parts = <String>[
    if (item.videoCodec case final codec?) [codecName(codec), ?resolution(item.videoHeight)].join(' '),
    if (item.audio.firstOrNull case final audio?)
      [codecName(audio.codec), if (audio.channels case final count?) channels(count)].join(' '),
    if (item.audio.length > 1) context.t.media_server_audio_tracks(count: item.audio.length),
    ?switch (item.stereo) {
      'HalfSideBySide' => context.t.media_server_3d_half_sbs,
      'FullSideBySide' => context.t.media_server_3d_sbs,
      'HalfTopAndBottom' => context.t.media_server_3d_half_tb,
      'FullTopAndBottom' => context.t.media_server_3d_tb,
      'MVC' => context.t.media_server_3d_mvc,
      _ => null,
    },
    if (item.versions > 1) context.t.media_server_versions(count: item.versions),
  ];
  return parts.join(', ');
}

/// The page of a film or a series of a Jellyfin or Emby server (release 49), between its tile and the player: its
/// poster, title, year, length and overview, the streams of its file in one line, and Resume at the place where it
/// was left (here, else in the server's own apps) or Play from start. A series shows its seasons as chips, the
/// episodes of the one picked with their progress and a tick once played, and Next episode as the server tells it.
///
/// [path] is the file the tile showed, which Play opens so that its watch progress stays that of the tile; without
/// one, the item's own path (jellyfinItemPath). On a TV the focus starts on the first button, and Back returns to the
/// tile the page was opened from.
@RoutePage()
class MediaServerItemPage extends ConsumerStatefulWidget {
  const MediaServerItemPage({super.key, required this.sourceId, required this.itemId, this.path, this.title});

  final String sourceId;
  final String itemId;
  final String? path;

  /// The title the tile showed, for the bar while the item loads
  final String? title;

  @override
  ConsumerState<MediaServerItemPage> createState() => _MediaServerItemPageState();
}

class _MediaServerItemPageState extends ConsumerState<MediaServerItemPage> {
  MediaServerItemKey get _key => (sourceId: widget.sourceId, itemId: widget.itemId);

  @override
  Widget build(BuildContext context) {
    final item = ref.watch(mediaServerItemProvider(_key));
    return Scaffold(
      appBar: AppBar(title: Text(item.valueOrNull?.title ?? widget.title ?? '')),
      body: switch (item) {
        AsyncData(:final value) => _ItemBody(sourceId: widget.sourceId, item: value, path: widget.path),
        AsyncError(:final error) => NetworkErrorView(
          error: error,
          onRetry: () => ref.invalidate(mediaServerItemProvider(_key)),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _ItemBody extends ConsumerWidget {
  const _ItemBody({required this.sourceId, required this.item, this.path});

  final String sourceId;
  final MediaServerItem item;
  final String? path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final poster = _Poster(sourceId: sourceId, itemId: item.id, width: wide ? 220 : 140);
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(item.title, style: context.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
          [
            if (item.year != null && !item.title.contains('${item.year}')) '${item.year}',
            if (item.durationMs case final ms? when item.kind == MediaServerItemKind.film)
              Duration(milliseconds: ms).format(),
          ].join('  '),
          style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        if (item.kind == MediaServerItemKind.film) ...[
          if (mediaServerStreamsLine(context, item) case final line when line.isNotEmpty)
            Text(line, key: const Key('media_server_streams'), style: context.textTheme.bodySmall),
          const SizedBox(height: 12),
          _FilmButtons(sourceId: sourceId, item: item, path: path),
        ],
        if (item.overview case final overview?) ...[const SizedBox(height: 12), _Overview(text: overview)],
      ],
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              poster,
              const SizedBox(width: 24),
              Expanded(child: details),
            ],
          )
        else ...[
          Center(child: poster),
          const SizedBox(height: 16),
          details,
        ],
        if (item.kind == MediaServerItemKind.series) ...[
          const SizedBox(height: 16),
          _Series(sourceId: sourceId, series: item),
        ],
      ],
    );
  }
}

/// The overview: four lines, all of it on a tap
class _Overview extends StatefulWidget {
  const _Overview({required this.text});

  final String text;

  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => setState(() => _open = !_open),
    child: Text(
      widget.text,
      key: const Key('media_server_overview'),
      maxLines: _open ? null : 4,
      overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
    ),
  );
}

class _Poster extends ConsumerWidget {
  const _Poster({required this.sourceId, required this.itemId, required this.width});

  final String sourceId;
  final String itemId;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(mediaServerSourceProvider(sourceId)).valueOrNull;
    final placeholder = ColoredBox(
      color: context.colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.movie_outlined, size: 40),
    );
    return SizedBox(
      width: width,
      height: width * 3 / 2,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: source == null
            ? placeholder
            : FutureBuilder(
                future: source.itemPicture(itemId, (width * 3 / 2 * MediaQuery.devicePixelRatioOf(context)).round()),
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  return bytes == null
                      ? placeholder
                      : Image(
                          image: GuardedMemoryImage(
                            bytes,
                            source: 'mediaServerPoster',
                            maxWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
                            maxHeight: (width * 3 / 2 * MediaQuery.devicePixelRatioOf(context)).round(),
                          ),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => placeholder,
                        );
                },
              ),
      ),
    );
  }
}

/// Opens [itemId] in the video page: the path of the tile, else the item's own; Resume at the place where it was
/// left here, else where the server says, seeding the app's own record as the Plex film page does
Future<void> _play(
  BuildContext context,
  WidgetRef ref, {
  required String sourceId,
  required MediaServerItem item,
  String? path,
  required bool fromStart,
}) async {
  final String target;
  try {
    target = path ?? await (await ref.read(mediaServerSourceProvider(sourceId).future)).pathOfItem(item.id);
  } catch (_) {
    return;
  }
  if (!context.mounted) {
    return;
  }
  final connections = ref.read(networkConnectionsProvider);
  NetworkEntry? entry;
  try {
    entry = await (await connections.fileSystem(sourceId)).stat(target);
  } catch (_) {
    entry = null;
  }
  if (!context.mounted) {
    return;
  }
  if (entry != null) {
    final store = ref.read(watchProgressProvider.notifier);
    final key = WatchKey.ofEntry(entry);
    final row = ref.read(watchProgressProvider).find(key);
    final there = item.positionMs;
    final duration = item.durationMs;
    if (fromStart) {
      store.restart(key);
    } else if ((row == null || row.position <= Duration.zero) && there != null && there > 0 && duration != null) {
      store.record(
        key,
        position: Duration(milliseconds: there),
        duration: Duration(milliseconds: duration),
      );
    }
  }
  unawaited(context.pushRoute(NetworkVideoRoute(sourceId: sourceId, path: target)));
}

/// The place to resume [item] at: the app's own record of the tile's file first, else the server's
Duration? _resumeAt(WidgetRef ref, String sourceId, MediaServerItem item, String? path) {
  final rule = ref.watch(watchRuleProvider);
  if (!rule.enabled || item.played) {
    return null;
  }
  final key = path == null ? null : WatchKey.ofEntry(NetworkEntry(sourceId: sourceId, path: path, isDirectory: false));
  final row = key == null ? null : ref.watch(watchProgressProvider.select((rows) => rows.find(key)));
  final here = row != null && !row.watched && row.position > Duration.zero ? row.position : null;
  final there = item.positionMs;
  final duration = item.durationMs;
  final fromServer =
      there != null && there > 0 && rule.isFilm(duration == null ? null : Duration(milliseconds: duration))
      ? Duration(milliseconds: there)
      : null;
  return here ?? (row == null ? fromServer : null);
}

class _FilmButtons extends ConsumerWidget {
  const _FilmButtons({required this.sourceId, required this.item, this.path});

  final String sourceId;
  final MediaServerItem item;
  final String? path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resumeAt = _resumeAt(ref, sourceId, item, path);
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          key: const Key('media_server_play'),
          // The first stop of the remote on a TV
          autofocus: true,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(
            resumeAt == null
                ? context.t.media_server_play
                : context.t.media_server_resume_at(position: resumeAt.format()),
          ),
          onPressed: () => unawaited(_play(context, ref, sourceId: sourceId, item: item, path: path, fromStart: false)),
        ),
        if (resumeAt != null)
          TextButton.icon(
            key: const Key('media_server_play_from_start'),
            icon: const Icon(Icons.replay_rounded),
            label: Text(context.t.media_server_play_from_start),
            onPressed: () =>
                unawaited(_play(context, ref, sourceId: sourceId, item: item, path: path, fromStart: true)),
          ),
      ],
    );
  }
}

/// The seasons of a series as chips, the episodes of the one picked, and Next episode
class _Series extends ConsumerStatefulWidget {
  const _Series({required this.sourceId, required this.series});

  final String sourceId;
  final MediaServerItem series;

  @override
  ConsumerState<_Series> createState() => _SeriesState();
}

class _SeriesState extends ConsumerState<_Series> {
  List<MediaServerItem>? _seasons;
  MediaServerItem? _season;
  List<MediaServerItem>? _episodes;
  MediaServerItem? _next;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final source = await ref.read(mediaServerSourceProvider(widget.sourceId).future);
      final seasons = await source.seasonsOf(widget.series.id);
      MediaServerItem? next;
      try {
        next = await source.nextEpisodeOf(widget.series.id);
      } catch (_) {
        // Next episode is a help: the seasons are the page
        next = null;
      }
      if (!mounted) {
        return;
      }
      final first =
          seasons.where((s) => next != null && s.seasonNumber == next.seasonNumber).firstOrNull ?? seasons.firstOrNull;
      setState(() {
        _seasons = seasons;
        _next = next;
      });
      if (first != null) {
        await _pick(first);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error);
      }
    }
  }

  Future<void> _pick(MediaServerItem season) async {
    setState(() {
      _season = season;
      _episodes = null;
    });
    try {
      final source = await ref.read(mediaServerSourceProvider(widget.sourceId).future);
      final episodes = await source.episodesOf(widget.series.id, season.id);
      if (mounted && identical(_season, season)) {
        setState(() => _episodes = episodes);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error);
      }
    }
  }

  String _episodeTitle(MediaServerItem episode) {
    final number = episode.episodeNumber;
    return number == null ? episode.title : '$number. ${episode.title}';
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return NetworkErrorView(
        error: error,
        onRetry: () => setState(() {
          _error = null;
          unawaited(_load());
        }),
      );
    }
    final seasons = _seasons;
    if (seasons == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final next = _next;
    final episodes = _episodes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (next != null)
          FilledButton.icon(
            key: const Key('media_server_next_episode'),
            autofocus: true,
            icon: const Icon(Icons.skip_next_rounded),
            label: Text(
              '${context.t.media_server_next_episode}: ${_episodeTitle(next)}',
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: () => unawaited(_play(context, ref, sourceId: widget.sourceId, item: next, fromStart: false)),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (index, season) in seasons.indexed)
              ChoiceChip(
                key: Key('media_server_season_${season.id}'),
                autofocus: next == null && index == 0,
                label: Text(
                  season.seasonNumber == null
                      ? season.title
                      : context.t.media_server_season(number: season.seasonNumber!),
                ),
                selected: identical(season, _season),
                onSelected: (_) => unawaited(_pick(season)),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (episodes == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (episodes.isEmpty)
          Text(context.t.media_server_no_episodes)
        else
          for (final episode in episodes)
            _EpisodeRow(sourceId: widget.sourceId, episode: episode, title: _episodeTitle(episode)),
      ],
    );
  }
}

class _EpisodeRow extends ConsumerWidget {
  const _EpisodeRow({required this.sourceId, required this.episode, required this.title});

  final String sourceId;
  final MediaServerItem episode;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final duration = episode.durationMs;
    final position = episode.positionMs;
    final progress = duration != null && duration > 0 && position != null && position > 0 && !episode.played
        ? (position / duration).clamp(0.0, 1.0)
        : null;
    return ListTile(
      key: Key('media_server_episode_${episode.id}'),
      contentPadding: EdgeInsets.zero,
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (duration != null) Text(Duration(milliseconds: duration).format()),
          if (progress != null) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(key: Key('media_server_progress_${episode.id}'), value: progress),
          ],
        ],
      ),
      trailing: episode.played
          ? Tooltip(
              message: context.t.media_server_played,
              child: Icon(
                Icons.check_circle_rounded,
                key: Key('media_server_played_${episode.id}'),
                color: context.primaryColor,
              ),
            )
          : null,
      onTap: () => unawaited(_play(context, ref, sourceId: sourceId, item: episode, fromStart: false)),
    );
  }
}
