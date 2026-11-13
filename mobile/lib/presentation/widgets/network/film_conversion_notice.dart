// What the app says of a film the Plex server converts for this device (release 47): a notice of a few seconds when the
// conversion starts, the reason in the converted icon of the video page, and a line in the film page. Until then an
// icon alone told it (the S24 test of 13 November 2026).

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/film_player/film_conversion_reason.dart';
import 'package:immich_mobile/domain/services/film_player/film_player_choice.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_streams.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/providers/network/film_player.provider.dart';

/// How long the notice of a conversion stays: the transient warnings of the app fade after a few seconds
const filmConversionNoticeDuration = Duration(seconds: 5);

/// "Converted by the Plex server: this device cannot play DTS", from what the device lacks ([deviceMissing] of the
/// choice); "Converted by the Plex server" when it lacks nothing listed (a conversion after a player failed)
String filmConversionText(Translations t, List<String> deviceMissing) {
  final formats = filmConversionFormats(deviceMissing);
  return formats.isEmpty ? t.film_player_converted : t.film_player_converted_because(formats: formats.join(', '));
}

/// Says for [filmConversionNoticeDuration] that the server converts the film, and why
void showFilmConversionNotice(BuildContext context, List<String> deviceMissing) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) {
    return;
  }
  messenger.showSnackBar(
    SnackBar(
      key: const Key('film_conversion_notice'),
      duration: filmConversionNoticeDuration,
      content: Text(filmConversionText(context.t, deviceMissing)),
    ),
  );
}

/// The line of the film page for a film that this device plays through the server's conversion: "On this device:
/// converted by the Plex server (this device cannot play DTS)"; nothing for any other film, or while it is not known
class FilmConversionLine extends ConsumerWidget {
  const FilmConversionLine({super.key, required this.part, this.container, this.style});

  /// The file the film plays, null when it has none
  final PlexFilmPart? part;

  /// The container of its version, when the file does not tell it
  final String? container;
  final TextStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final part = this.part;
    if (part == null) {
      return const SizedBox.shrink();
    }
    final choice = ref.watch(filmPlayerOnDeviceProvider(filmStreamsOfPlexPart(part, container: container))).valueOrNull;
    if (choice == null || choice.kind != FilmPlayerKind.serverConversion) {
      return const SizedBox.shrink();
    }
    final formats = filmConversionFormats(choice.deviceMissing);
    if (formats.isEmpty) {
      return const SizedBox.shrink();
    }
    return Text(
      context.t.plex_film_converted_here(formats: formats.join(', ')),
      key: const Key('plex_film_conversion_line'),
      style: style,
    );
  }
}
