// Settings, Advanced: the player of the films of a Plex server and the server's conversion (release 46,
// film_player_choice.dart). The player (Automatic, Device, mpv) on a build with libmpv only (the Meta Quest build of
// 46); the conversion, experimental and on by default, on Android, where the app chooses the player.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/android_mpv.dart';
import 'package:immich_mobile/domain/models/film_player_preference.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/network/film_player_menu.widget.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_ui/immich_ui.dart';

class FilmPlayerSettings extends HookConsumerWidget {
  const FilmPlayerSettings({super.key, this.android});

  /// Whether this is Android, where the app chooses the player of a film; by default the platform's answer (the
  /// tests say)
  final bool? android;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAndroid = android ?? (Platform.isAndroid && !CurrentPlatform.isDesktop);
    final mpv = isAndroid && (ref.watch(androidMpvAvailableProvider).valueOrNull ?? false);
    final player = ref.watch(appConfigProvider.select((config) => config.viewer.filmPlayer));
    final conversion = useState(ref.watch(appConfigProvider).viewer.plexConversion);
    useValueChanged<bool, void>(conversion.value, (_, _) {
      unawaited(ref.read(settingsProvider).write(.viewerPlexConversion, conversion.value));
    });
    if (!isAndroid) {
      return const SizedBox.shrink();
    }
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (mpv) ...[
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 20, top: 12),
            child: Text(t.film_player_setting_title, style: context.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              t.film_player_setting_subtitle,
              style: context.textTheme.bodyMedium!.copyWith(color: context.textTheme.bodyMedium!.color!.withAlpha(215)),
            ),
          ),
          SettingsRadioListTile<FilmPlayerPreference>(
            key: const Key('advanced_settings_film_player'),
            groups: [
              for (final preference in FilmPlayerPreference.values)
                SettingsRadioGroup(title: filmPlayerName(t, preference), value: preference),
            ],
            groupBy: player,
            onRadioChanged: (value) {
              if (value != null && value != player) {
                unawaited(ref.read(settingsProvider).write(.viewerFilmPlayer, value));
              }
            },
          ),
        ],
        SettingsSwitchListTile(
          key: const Key('advanced_settings_plex_conversion'),
          valueNotifier: conversion,
          title: t.film_player_conversion_setting_title,
          subtitle: t.film_player_conversion_setting_subtitle,
        ),
      ],
    );
  }
}
