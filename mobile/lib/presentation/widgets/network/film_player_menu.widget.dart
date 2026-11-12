// "Player: Automatic" in the menu of the video page, on a build with libmpv (the Meta Quest build of release 46): a
// dialog of the three choices, Automatic, Device and mpv (film_player_choice.dart). The pick holds for the film on
// this page; Settings, Advanced keeps the choice of every film.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/services/film_player/film_player_choice.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// The name of [preference] in the menus
String filmPlayerName(Translations t, FilmPlayerPreference preference) => switch (preference) {
  FilmPlayerPreference.automatic => t.film_player_automatic,
  FilmPlayerPreference.device => t.film_player_device,
  FilmPlayerPreference.mpv => t.film_player_mpv,
};

/// The line under [preference] in the dialog and in Settings
String filmPlayerDescription(Translations t, FilmPlayerPreference preference) => switch (preference) {
  FilmPlayerPreference.automatic => t.film_player_automatic_subtitle,
  FilmPlayerPreference.device => t.film_player_device_subtitle,
  FilmPlayerPreference.mpv => t.film_player_mpv_subtitle,
};

/// The item of the menu: the player asked, and for Automatic the one that plays ("Player: Automatic (mpv)")
PopupMenuItem<void> filmPlayerMenuItem(
  BuildContext context, {
  required FilmPlayerPreference asked,
  required FilmPlayerKind playing,
  required void Function(FilmPlayerPreference) onPicked,
}) {
  final t = context.t;
  final name = filmPlayerName(t, asked);
  final shown = asked == FilmPlayerPreference.automatic
      ? '$name (${playing == FilmPlayerKind.mpv
            ? t.film_player_mpv
            : playing == FilmPlayerKind.serverConversion
            ? t.film_player_converted
            : t.film_player_device})'
      : name;
  return PopupMenuItem<void>(
    key: const Key('network_video_player'),
    // The page's own context: the dialog opens once the menu is gone
    onTap: () => unawaited(_pick(context, asked, onPicked)),
    child: ListTile(
      leading: const Icon(Icons.smart_display_outlined),
      title: Text(t.film_player_menu(player: shown)),
      contentPadding: EdgeInsets.zero,
    ),
  );
}

Future<void> _pick(
  BuildContext context,
  FilmPlayerPreference asked,
  void Function(FilmPlayerPreference) onPicked,
) async {
  // After the menu's route is gone
  await Future<void>.delayed(Duration.zero);
  if (!context.mounted) {
    return;
  }
  final picked = await showDialog<FilmPlayerPreference>(
    context: context,
    builder: (context) => FilmPlayerDialog(asked: asked),
  );
  if (picked != null) {
    onPicked(picked);
  }
}

/// The three players, the asked one checked
class FilmPlayerDialog extends StatelessWidget {
  const FilmPlayerDialog({super.key, required this.asked});

  final FilmPlayerPreference asked;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SimpleDialog(
      title: Text(t.film_player_title),
      children: [
        for (final preference in FilmPlayerPreference.values)
          ListTile(
            key: Key('film_player_${preference.name}'),
            autofocus: preference == asked,
            leading: Icon(preference == asked ? Icons.radio_button_checked : Icons.radio_button_unchecked),
            title: Text(filmPlayerName(t, preference)),
            subtitle: Text(filmPlayerDescription(t, preference)),
            onTap: () => Navigator.of(context).pop(preference),
          ),
      ],
    );
  }
}
