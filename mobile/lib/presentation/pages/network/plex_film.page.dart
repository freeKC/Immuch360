import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/duration_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_versions.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_film_client.dart';
import 'package:immich_mobile/presentation/pages/network/film_page_actions.dart';
import 'package:immich_mobile/presentation/widgets/images/guarded_image.dart';
import 'package:immich_mobile/presentation/widgets/network/film_conversion_notice.dart';
import 'package:immich_mobile/presentation/widgets/network/network_status.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_upload.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/open_url.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_scroll_area.widget.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/providers/network/plex_film_version.provider.dart';
import 'package:immich_mobile/providers/network/plex_films.provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

/// The page of a film of a Plex server (request 8 of 10 November 2026), between its poster and the player: what the
/// server holds of it at once (poster, background, title, year, duration, audience, genres, synopsis, director and
/// cast, its languages and its file), Play or Resume, the actions other lots add (see filmPageActions), and the lead
/// of its Wikipedia article in the language of the app, loaded after the rest and never in the way of Play.
///
/// Opened by [ratingKey] from a tile of the folder view of a library of films, from a filtered list, and later from
/// the films page of lot A1. [path] is the file the tile showed, which Play opens so that its watch progress and its
/// upload mark stay those of the tile; without one, the film's own path (plexFilmPath) of its first file. A film with
/// several versions (release 47) shows them under the buttons: Play opens the one picked, remembered per film, else
/// the one this device plays best (plexFilmVersionIndex), by its own path when it is not the tile's file.
///
/// On a TV the focus starts on Play, the texts scroll with the remote (RemoteScrollArea), an address opens in a dialog
/// rather than a browser (openUrl), and Back returns to the poster the page was opened from. Wide screens (tablets,
/// the Quest window, computers, TVs) put the poster and the buttons on the left and the texts on the right.
@RoutePage()
class PlexFilmPage extends ConsumerStatefulWidget {
  const PlexFilmPage({super.key, required this.sourceId, required this.ratingKey, this.path});

  final String sourceId;
  final String ratingKey;

  /// The file to play, absolute in the share; null for the film's own path of its first file
  final String? path;

  @override
  ConsumerState<PlexFilmPage> createState() => _PlexFilmPageState();
}

class _PlexFilmPageState extends ConsumerState<PlexFilmPage> {
  PlexFilmKey get _key => (sourceId: widget.sourceId, ratingKey: widget.ratingKey);

  @override
  Widget build(BuildContext context) {
    final details = ref.watch(plexFilmDetailsProvider(_key));
    final film = details.valueOrNull;
    final picks = ref.watch(plexFilmVersionPicksProvider);
    final device = ref.watch(filmVersionDeviceProvider).valueOrNull;
    final fileSystem = ref.watch(plexFilmFileSystemProvider(widget.sourceId)).valueOrNull;
    final given = widget.path;
    final givenPartId = given == null ? null : fileSystem?.itemAt(given)?.partId;
    // A file opened in the folder view is a version the user chose; the films page opens a film by its first file
    final tapped = given != null && parsePlexFilmPath(given) == null ? givenPartId : null;
    int versionOf(PlexFilmDetails film) =>
        plexFilmVersionIndex(film, widget.sourceId, picks, device, tappedPartId: tapped);
    String? pathOf(PlexFilmDetails film) =>
        plexFilmPlayPath(film, given: given, givenPartId: givenPartId, version: versionOf(film));
    return Scaffold(
      appBar: AppBar(
        title: Text(film?.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
        elevation: 0,
        centerTitle: false,
        actions: [if (film != null) _FilmMenu(sourceId: widget.sourceId, film: film, path: pathOf(film))],
      ),
      body: details.when(
        skipLoadingOnReload: true,
        data: (film) => _FilmView(sourceId: widget.sourceId, film: film, path: pathOf(film), version: versionOf(film)),
        loading: () => const NetworkLoadingView(),
        error: (error, _) =>
            NetworkErrorView(error: error, onRetry: () => ref.invalidate(plexFilmDetailsProvider(_key))),
      ),
    );
  }
}

/// The file Play opens for the version at [version] of [film] (plexFilmVersions): [given], the file of the tile, when
/// it is that version's file ([givenPartId], its part, null when not known counts as the first version's), else that
/// version's first file by its own path (plexFilmPath); null for an item without a file
String? plexFilmPlayPath(PlexFilmDetails film, {String? given, int? givenPartId, int version = 0}) {
  final versions = plexFilmVersions(film);
  final media = version >= 0 && version < versions.length ? versions[version] : versions.firstOrNull;
  final part = media?.parts.firstOrNull ?? film.parts.firstOrNull;
  if (given != null) {
    final givenPart = givenPartId ?? parsePlexFilmPath(given)?.partId;
    final same = givenPart == null ? version == 0 || versions.length < 2 : givenPart == part?.id;
    if (same || versions.length < 2) {
      return given;
    }
  }
  final section = film.sectionKey;
  if (part == null || section == null) {
    return given;
  }
  return plexFilmPath(
    sectionKey: section,
    ratingKey: film.ratingKey,
    partId: part.id,
    name: part.fileName ?? '${film.title}.${part.container ?? 'mkv'}',
  );
}

/// The ⋮ of the app bar: the Wikipedia switch, and Upload to Immich where the app sends files
class _FilmMenu extends ConsumerWidget {
  const _FilmMenu({required this.sourceId, required this.film, required this.path});

  final String sourceId;
  final PlexFilmDetails film;
  final String? path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tvMode = ref.watch(tvModeProvider);
    final wikipedia = ref.watch(appConfigProvider.select((config) => config.viewer.filmWikipedia));
    final canUpload = !tvMode && path != null && ref.watch(hasServerProvider);
    final isUploading = ref.watch(networkUploadProvider.select((upload) => upload.isRunning));
    // A TV keeps the switch in Settings, Advanced: a menu does not hold the focus of the remote
    if (tvMode) {
      return const SizedBox.shrink();
    }
    return PopupMenuButton<void>(
      key: const Key('plex_film_menu'),
      tooltip: context.t.more,
      itemBuilder: (context) => [
        CheckedPopupMenuItem<void>(
          key: const Key('plex_film_wikipedia_switch'),
          checked: wikipedia,
          onTap: () => unawaited(setFilmWikipedia(ref, !wikipedia)),
          child: Text(context.t.plex_film_wikipedia_setting_title),
        ),
        PopupMenuItem<void>(
          key: const Key('plex_film_show_folders'),
          onTap: () => unawaited(showPlexFilmFolders(context, ref, sourceId: sourceId, film: film, path: path)),
          child: ListTile(
            leading: const Icon(Icons.folder_open_rounded),
            title: Text(context.t.plex_film_show_folders),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        if (canUpload)
          PopupMenuItem<void>(
            enabled: !isUploading,
            onTap: () async {
              final entry = await ref.read(plexFilmEntryProvider((sourceId: sourceId, path: path!)).future);
              if (context.mounted) {
                await uploadNetworkEntries(context, ref, sourceId, [entry]);
              }
            },
            child: ListTile(
              leading: const Icon(Icons.backup_outlined),
              title: Text(context.t.network_upload_action),
              contentPadding: EdgeInsets.zero,
            ),
          ),
      ],
    );
  }
}

class _FilmView extends ConsumerWidget {
  const _FilmView({required this.sourceId, required this.film, required this.path, required this.version});

  final String sourceId;
  final PlexFilmDetails film;
  final String? path;

  /// The place of the version Play opens among plexFilmVersions
  final int version;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tvMode = ref.watch(tvModeProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        final posterWidth = wide ? 220.0 : 120.0;
        final header = _Header(
          sourceId: sourceId,
          film: film,
          path: path,
          version: version,
          posterWidth: posterWidth,
          wide: wide,
        );
        final texts = _Texts(sourceId: sourceId, film: film, version: version, tvMode: tvMode);
        final content = wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: posterWidth + 24, child: header),
                  const SizedBox(width: 24),
                  Expanded(child: texts),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [header, const SizedBox(height: 16), texts],
              );
        return Stack(
          children: [
            if (film.art != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: wide ? constraints.maxHeight : constraints.maxWidth * 9 / 16,
                child: _Backdrop(sourceId: sourceId, path: film.art!, width: constraints.maxWidth),
              ),
            // The end of the list above the navigation bar of the phone; the backdrop keeps the whole page
            SafeArea(
              child: ListView(
                key: const Key('plex_film_page'),
                padding: EdgeInsets.fromLTRB(16, wide ? 24 : constraints.maxWidth * 9 / 32, 16, 32),
                children: [content],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The background of the film under a scrim that keeps the texts readable
class _Backdrop extends ConsumerWidget {
  const _Backdrop({required this.sourceId, required this.path, required this.width});

  final String sourceId;
  final String path;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pixels = (width * MediaQuery.devicePixelRatioOf(context)).round().clamp(320, 1920);
    final bytes = ref
        .watch(plexPictureProvider((sourceId: sourceId, path: path, width: pixels, height: pixels * 9 ~/ 16)))
        .valueOrNull;
    final surface = context.colorScheme.surface;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (bytes != null)
            Image(
              image: GuardedMemoryImage(bytes, source: 'plexFilmBackdrop', maxWidth: pixels, maxHeight: pixels),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              // A picture no decoder of the device reads leaves the scrim alone
              errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [surface.withValues(alpha: 0.35), surface.withValues(alpha: 0.85), surface],
                stops: const [0, 0.6, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The poster, the title, the line of facts, the ratings and the buttons
class _Header extends ConsumerWidget {
  const _Header({
    required this.sourceId,
    required this.film,
    required this.path,
    required this.version,
    required this.posterWidth,
    required this.wide,
  });

  final String sourceId;
  final PlexFilmDetails film;
  final String? path;
  final int version;
  final double posterWidth;
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final poster = _Poster(sourceId: sourceId, path: film.thumb, width: posterWidth, title: film.title);
    final titles = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(film.title, key: const Key('plex_film_title'), style: context.textTheme.headlineSmall),
        if (film.originalTitle != null && film.originalTitle != film.title)
          Text(film.originalTitle!, style: context.textTheme.titleSmall?.copyWith(fontStyle: FontStyle.italic)),
        const SizedBox(height: 6),
        Text(plexFilmFactsLine(t, film), key: const Key('plex_film_facts'), style: context.textTheme.bodyMedium),
        if (film.ratings.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            [for (final rating in film.ratings) plexFilmRatingText(t, rating)].join(' · '),
            style: context.textTheme.bodySmall,
          ),
        ],
      ],
    );
    final buttons = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Buttons(sourceId: sourceId, film: film, path: path, version: version),
        if (plexFilmVersions(film).length > 1) ...[
          const SizedBox(height: 12),
          PlexFilmVersions(sourceId: sourceId, film: film, selected: version),
        ],
      ],
    );
    if (wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [poster, const SizedBox(height: 16), titles, const SizedBox(height: 16), buttons],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            poster,
            const SizedBox(width: 16),
            Expanded(child: titles),
          ],
        ),
        const SizedBox(height: 16),
        buttons,
      ],
    );
  }
}

class _Poster extends ConsumerWidget {
  const _Poster({required this.sourceId, required this.path, required this.width, required this.title});

  final String sourceId;
  final String? path;
  final double width;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final w = (width * ratio).round();
    final picture = path == null
        ? null
        : ref.watch(plexPictureProvider((sourceId: sourceId, path: path!, width: w, height: w * 3 ~/ 2))).valueOrNull;
    return Semantics(
      image: true,
      label: title,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: width,
          height: width * 3 / 2,
          child: picture != null
              ? Image(
                  image: GuardedMemoryImage(picture, source: 'plexFilmPoster', maxWidth: w, maxHeight: w * 3 ~/ 2),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stackTrace) => const _PosterPlaceholder(),
                )
              : const _PosterPlaceholder(),
        ),
      ),
    );
  }
}

/// The poster's place while it loads, when the server has none, or when no decoder of the device reads it
class _PosterPlaceholder extends StatelessWidget {
  const _PosterPlaceholder();

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: context.colorScheme.surfaceContainerHighest, child: const Icon(Icons.movie_outlined, size: 40));
}

/// Play, or Resume at the place where the film was left (on this device, else in a Plex app) with Play from the
/// start, then the actions of the other lots
class _Buttons extends ConsumerWidget {
  const _Buttons({required this.sourceId, required this.film, required this.path, required this.version});

  final String sourceId;
  final PlexFilmDetails film;
  final String? path;
  final int version;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final path = this.path;
    final entry = path == null ? null : ref.watch(plexFilmEntryProvider((sourceId: sourceId, path: path))).valueOrNull;
    final watchKey = entry == null ? null : WatchKey.ofEntry(entry);
    final row = watchKey == null ? null : ref.watch(watchProgressProvider.select((rows) => rows.find(watchKey)));
    final rule = ref.watch(watchRuleProvider);
    // The app's own place first, else where a Plex app stopped, for a film long enough to resume
    final here = row != null && !row.watched && row.position > Duration.zero ? row.position : null;
    final offset = film.viewOffsetMs;
    final duration = film.durationMs;
    final there = offset != null && offset > 0 && duration != null && rule.isFilm(Duration(milliseconds: duration))
        ? Duration(milliseconds: offset)
        : null;
    final resumeAt = rule.enabled ? here ?? (row == null ? there : null) : null;
    final context_ = FilmPageContext(sourceId: sourceId, film: film, path: path, entry: entry, version: version);
    final extra = [
      for (final action in filmPageActions)
        if (action(context, ref, context_) case final Widget widget) widget,
    ];

    void play({required bool fromStart}) {
      if (path == null) {
        return;
      }
      final store = ref.read(watchProgressProvider.notifier);
      if (watchKey != null) {
        if (fromStart) {
          store.restart(watchKey);
        } else if (here == null && resumeAt != null && duration != null) {
          // Where a Plex app stopped: the player resumes from the app's own record
          store.record(
            watchKey,
            position: resumeAt,
            duration: Duration(milliseconds: duration),
          );
        }
      }
      unawaited(context.pushRoute(NetworkVideoRoute(sourceId: sourceId, path: path)));
    }

    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          key: const Key('plex_film_play'),
          // The first stop of the remote on a TV, and of the keyboard on a computer
          autofocus: true,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(resumeAt == null ? t.play : t.plex_film_resume_at(position: resumeAt.format())),
          onPressed: path == null ? null : () => play(fromStart: false),
        ),
        if (resumeAt != null)
          TextButton.icon(
            key: const Key('plex_film_play_from_start'),
            icon: const Icon(Icons.replay_rounded),
            label: Text(t.video_play_from_start),
            onPressed: () => play(fromStart: true),
          ),
        ...extra,
        // A TV has no menu in the bar: the folders are a button of the row
        if (ref.watch(tvModeProvider))
          TextButton.icon(
            key: const Key('plex_film_show_folders'),
            icon: const Icon(Icons.folder_open_rounded),
            label: Text(t.plex_film_show_folders),
            onPressed: () => unawaited(showPlexFilmFolders(context, ref, sourceId: sourceId, film: film, path: path)),
          ),
      ],
    );
  }
}

/// "Show the folders": the folder view of the share around the film, the folder its file was listed in, or the folder
/// of its library for a film opened by its own path (a filtered list, the films page); Back returns to the film page
Future<void> showPlexFilmFolders(
  BuildContext context,
  WidgetRef ref, {
  required String sourceId,
  required PlexFilmDetails film,
  required String? path,
}) async {
  final String? folder;
  try {
    final fileSystem = await ref.read(plexFilmFileSystemProvider(sourceId).future);
    folder = await fileSystem?.folderOfFilm(path, film.sectionKey);
  } catch (_) {
    // The server does not answer: the page stays, its own error shows at the next read
    return;
  }
  if (folder == null || !context.mounted) {
    return;
  }
  await context.pushRoute(NetworkBrowserRoute(sourceId: sourceId, path: folder));
}

/// The tagline, the synopsis, the people, the file and the Wikipedia block
class _Texts extends ConsumerWidget {
  const _Texts({required this.sourceId, required this.film, required this.version, required this.tvMode});

  final String sourceId;
  final PlexFilmDetails film;
  final int version;
  final bool tvMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final secondary = context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant);
    final directors = film.directors.map((person) => person.name).join(', ');
    final writers = film.writers.map((person) => person.name).join(', ');
    final technical = plexFilmTechnicalLine(t, film, version: version);
    final played = plexFilmVersionPart(film, version: version);
    final section = film.sectionKey;
    final library = section == null ? null : _sectionLanguage(ref, section);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (film.tagline != null) ...[
          Text(film.tagline!, style: context.textTheme.titleMedium?.copyWith(fontStyle: FontStyle.italic)),
          const SizedBox(height: 8),
        ],
        if (film.summary != null)
          _LongText(text: film.summary!, tvMode: tvMode, textKey: const Key('plex_film_summary')),
        if (directors.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(t.plex_film_directed_by(names: directors), style: secondary),
        ],
        if (writers.isNotEmpty) Text(t.plex_film_written_by(names: writers), style: secondary),
        if (film.roles.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(t.plex_film_cast, style: context.textTheme.titleMedium),
          const SizedBox(height: 8),
          _CastRow(people: film.roles),
        ],
        if (technical.isNotEmpty) ...[
          const SizedBox(height: 16),
          for (final line in technical) Text(line, style: secondary),
        ],
        // The file Play opens, converted by the server on this device: why
        FilmConversionLine(
          part: played,
          container: played == null ? null : film.mediaOf(played)?.container,
          style: secondary,
        ),
        _WikipediaBlock(film: film, libraryLanguage: library, tvMode: tvMode),
      ],
    );
  }

  String? _sectionLanguage(WidgetRef ref, String sectionKey) {
    final fileSystem = ref.watch(plexFilmFileSystemProvider(sourceId)).valueOrNull;
    return fileSystem?.sectionOf(sectionKey)?.language;
  }
}

/// A text of several paragraphs: four lines and More on a touch screen, a scroll area of its own on a TV, which the
/// remote reads to its end
class _LongText extends StatefulWidget {
  const _LongText({required this.text, required this.tvMode, this.textKey});

  final String text;
  final bool tvMode;
  final Key? textKey;

  @override
  State<_LongText> createState() => _LongTextState();
}

class _LongTextState extends State<_LongText> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final style = context.textTheme.bodyLarge;
    if (widget.tvMode) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: RemoteScrollArea(
          builder: (context, controller) => SingleChildScrollView(
            controller: controller,
            child: Text(widget.text, key: widget.textKey, style: style),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 4,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final long = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              key: widget.textKey,
              style: style,
              maxLines: _open ? null : 4,
              overflow: _open ? null : TextOverflow.ellipsis,
            ),
            if (long)
              TextButton(
                onPressed: () => setState(() => _open = !_open),
                child: Text(_open ? context.t.plex_film_less : context.t.plex_film_more),
              ),
          ],
        );
      },
    );
  }
}

/// The cast, sideways: initials in a circle (the pictures of the cast are on Plex's own servers, which the device
/// never contacts), the name and the character
class _CastRow extends StatelessWidget {
  const _CastRow({required this.people});

  final List<PlexFilmPerson> people;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 112,
      child: ListView.separated(
        key: const Key('plex_film_cast'),
        scrollDirection: Axis.horizontal,
        itemCount: people.length.clamp(0, 30),
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final person = people[index];
          return SizedBox(
            width: 88,
            child: Column(
              children: [
                CircleAvatar(radius: 26, child: Text(plexInitials(person.name))),
                const SizedBox(height: 4),
                Text(
                  person.name,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.bodySmall,
                ),
                if (person.role != null)
                  Text(
                    person.role!,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: context.textTheme.labelSmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// "From Wikipedia": the lead of the article in the language of the app or down its chain, with its language when it
/// is another, the link and the licence line. Nothing while it loads but a thin bar, nothing at all when there is no
/// article, the switch is off or Wikipedia does not answer.
class _WikipediaBlock extends ConsumerWidget {
  const _WikipediaBlock({required this.film, required this.libraryLanguage, required this.tvMode});

  final PlexFilmDetails film;
  final String? libraryLanguage;
  final bool tvMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = film.externalIds;
    if (ids.isEmpty) {
      return const SizedBox.shrink();
    }
    final locale = context.locale.toString();
    final summary = ref.watch(
      plexFilmWikipediaProvider((imdb: ids.imdb, tmdb: ids.tmdb, appLocale: locale, libraryLanguage: libraryLanguage)),
    );
    return switch (summary) {
      AsyncData(value: final WikipediaFilmSummary found) => _summary(context, found, locale),
      AsyncLoading() => const Padding(padding: EdgeInsets.only(top: 24), child: LinearProgressIndicator(minHeight: 2)),
      _ => const SizedBox.shrink(),
    };
  }

  Widget _summary(BuildContext context, WikipediaFilmSummary found, String locale) {
    final t = context.t;
    final language = found.languageTag.split('-').first;
    final other = language != locale.split('_').first;
    return Padding(
      key: const Key('plex_film_wikipedia'),
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(t.plex_film_wikipedia_title, style: context.textTheme.titleMedium),
              if (other) ...[
                const SizedBox(width: 8),
                Chip(label: Text(language.toUpperCase()), visualDensity: VisualDensity.compact),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Directionality(
            textDirection: found.isRightToLeft ? TextDirection.rtl : TextDirection.ltr,
            child: _LongText(text: found.extract, tvMode: tvMode),
          ),
          const SizedBox(height: 8),
          Text(
            t.plex_film_wikipedia_attribution(title: found.title),
            style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
          ),
          TextButton.icon(
            key: const Key('plex_film_wikipedia_link'),
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(t.plex_film_wikipedia_read),
            onPressed: () => unawaited(openUrl(context, found.articleUrl, tvMode: tvMode)),
          ),
        ],
      ),
    );
  }
}

/// "2001 · 2 h 02 · 12 and over · Comedy, Romance": what Plex tells of the year, the duration, the audience (its band,
/// or its rating as Plex gives it) and the first three genres
String plexFilmFactsLine(Translations t, PlexFilmDetails film) {
  final parts = <String>[];
  if (film.year != null) {
    parts.add('${film.year}');
  }
  final duration = film.durationMs;
  if (duration != null && duration > 0) {
    parts.add(plexFilmDurationText(t, Duration(milliseconds: duration)));
  }
  final rating = film.contentRating;
  if (rating != null) {
    final band = audienceBandOf(rating);
    parts.add(band == null ? rating : audienceBandLabel(t, band));
  }
  if (film.genres.isNotEmpty) {
    parts.add(film.genres.take(3).join(', '));
  }
  return parts.join(' · ');
}

/// "2 h 02", or "45 min" under an hour
String plexFilmDurationText(Translations t, Duration duration) {
  final minutes = duration.inMinutes.remainder(60);
  return duration.inHours > 0
      ? t.plex_film_duration_hours(hours: duration.inHours, minutes: minutes.toString().padLeft(2, '0'))
      : t.plex_film_duration_minutes(minutes: duration.inMinutes);
}

/// "IMDb 8.7", "Rotten Tomatoes 93 %", or the critics' or the audience's rating when Plex names no source
String plexFilmRatingText(Translations t, PlexFilmRating rating) {
  final source = rating.source;
  if (source != null) {
    return '$source ${rating.text}';
  }
  return rating.audience
      ? t.plex_film_rating_audience(value: rating.text)
      : t.plex_film_rating_critics(value: rating.text);
}

/// The name of an audience band in the sheet and on the film page
String audienceBandLabel(Translations t, AudienceBand band) => switch (band) {
  AudienceBand.all => t.plex_films_audience_all,
  AudienceBand.age10 => t.plex_films_audience_10,
  AudienceBand.age12 => t.plex_films_audience_12,
  AudienceBand.age16 => t.plex_films_audience_16,
  AudienceBand.age18 => t.plex_films_audience_18,
  AudienceBand.unrated => t.plex_films_audience_unrated,
};

/// The file Play opens: the first part of the version at [version] (plexFilmVersions), else the film's first part
PlexFilmPart? plexFilmVersionPart(PlexFilmDetails film, {int version = 0}) {
  final versions = plexFilmVersions(film);
  return (version >= 0 && version < versions.length ? versions[version].parts.firstOrNull : null) ??
      film.parts.firstOrNull;
}

/// The lines about the file Play opens, the first of the version at [version] (plexFilmVersions): "1080p, H264 · MKV,
/// 8.2 GB", then its audio and subtitle languages as Plex names them
List<String> plexFilmTechnicalLine(Translations t, PlexFilmDetails film, {int version = 0}) {
  final part = plexFilmVersionPart(film, version: version);
  if (part == null) {
    return const [];
  }
  final media = film.mediaOf(part);
  final video = [
    if (media?.videoResolution case final String resolution)
      RegExp(r'^\d+$').hasMatch(resolution) ? '${resolution}p' : resolution.toUpperCase(),
    if (media?.videoCodec case final String codec) codec.toUpperCase(),
  ].join(', ');
  final file = [
    if (part.container ?? media?.container case final String container) container.toUpperCase(),
    if (part.size case final int size) formatHumanReadableBytes(size, 1),
  ].join(', ');
  String languages(PlexStreamType type) => {
    for (final stream in part.streamsOf(type))
      if (stream.language ?? stream.languageTag case final String language) language,
  }.join(', ');
  final audio = languages(PlexStreamType.audio);
  final subtitles = languages(PlexStreamType.subtitle);
  return [
    [video, file].where((text) => text.isNotEmpty).join(' · '),
    if (audio.isNotEmpty) t.plex_film_audio(languages: audio),
    if (subtitles.isNotEmpty) t.plex_film_subtitles(languages: subtitles),
  ].where((line) => line.isNotEmpty).toList();
}

/// The versions of a film that has several, under its buttons: one chip each ("1080p HEVC, 3.0 GiB", "2160p HEVC HDR,
/// 52 GiB"), the one Play opens selected; a pick is remembered for the film on this device
class PlexFilmVersions extends ConsumerWidget {
  const PlexFilmVersions({super.key, required this.sourceId, required this.film, required this.selected});

  final String sourceId;
  final PlexFilmDetails film;
  final int selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final versions = plexFilmVersions(film);
    return Column(
      key: const Key('plex_film_versions'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.t.plex_film_versions, style: context.textTheme.titleSmall),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final (index, media) in versions.indexed)
              ChoiceChip(
                key: Key('plex_film_version_$index'),
                label: Text(plexFilmVersionLabel(media)),
                selected: index == selected,
                onSelected: media.id == null
                    ? null
                    : (_) => unawaited(
                        ref.read(plexFilmVersionPicksProvider.notifier).pick(sourceId, film.ratingKey, media.id!),
                      ),
              ),
          ],
        ),
      ],
    );
  }
}

/// The initials of a name, two at most: "Keanu Reeves" gives "KR"
String plexInitials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
  if (words.isEmpty) {
    return '?';
  }
  final first = words.first.characters.first;
  final last = words.length > 1 ? words.last.characters.first : '';
  return (first + last).toUpperCase();
}
