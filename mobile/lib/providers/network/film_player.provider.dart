// The choice of a film's player with what this device and this build have (film_player_choice.dart): the decoders of
// the device (asked once per run) and libmpv (the Meta Quest build of release 46).

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/android_mpv.dart';
import 'package:immich_mobile/domain/services/film_player/device_decoder_types.dart';
import 'package:immich_mobile/domain/services/film_player/film_decoders.dart';
import 'package:immich_mobile/domain/services/film_player/film_player_choice.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';

class FilmPlayers {
  FilmPlayers({required this._decoderTypes, required this._mpvReady});

  final DeviceDecoderTypes _decoderTypes;
  final Future<bool> Function() _mpvReady;

  /// Whether this build plays with libmpv
  Future<bool> mpvAvailable() => _mpvReady();

  /// What the device's player decodes; null when the device does not tell (not Android)
  Future<FilmDecoders?> deviceDecoders() async {
    final types = await _decoderTypes.types();
    return types == null ? null : deviceFilmDecoders(types);
  }

  /// The player of a film whose streams are [streams]: the device's player wherever the device does not tell its
  /// decoders, as before release 46
  Future<FilmPlayerChoice> choose(
    FilmStreams? streams, {
    required FilmPlayerPreference preference,
    required bool conversion,
  }) async {
    final mpv = await mpvAvailable() ? mpvFilmDecoders : null;
    final device = await deviceDecoders();
    if (device == null) {
      return preference == FilmPlayerPreference.mpv && mpv != null
          ? const FilmPlayerChoice(FilmPlayerKind.mpv, FilmPlayerReason.asked)
          : const FilmPlayerChoice(FilmPlayerKind.device, FilmPlayerReason.streamsUnknown);
    }
    return chooseFilmPlayer(streams: streams, device: device, mpv: mpv, preference: preference, conversion: conversion);
  }

  /// The audio codecs a conversion may send this device besides AAC: E-AC-3 and AC-3 where it decodes them
  Future<List<String>> conversionAudioCodecs() async {
    final device = await deviceDecoders();
    return [
      for (final codec in const ['eac3', 'ac3'])
        if (device?.audio.contains(codec) ?? false) codec,
    ];
  }
}

final filmPlayersProvider = Provider<FilmPlayers>(
  (ref) => FilmPlayers(decoderTypes: DeviceDecoderTypes(), mpvReady: AndroidMpv.ready),
);

/// The player this device would choose for a Plex film whose file holds [streams] (Automatic or the setting, the
/// server allowed to convert by the setting): for the line of the film page that says the server converts it here.
/// Null on the computers, whose players play every film themselves.
final filmPlayerOnDeviceProvider = FutureProvider.autoDispose.family<FilmPlayerChoice?, FilmStreams>((ref, streams) {
  if (CurrentPlatform.isDesktop) {
    return null;
  }
  final viewer = ref.watch(appConfigProvider.select((config) => config.viewer));
  return ref
      .watch(filmPlayersProvider)
      .choose(streams, preference: viewer.filmPlayer, conversion: viewer.plexConversion);
});
