// Which player plays a film of a Plex server (release 46, FreeKC on 11 November 2026, 19:20: "ok pour libmpv sur le
// Quest, d'ailleurs pourquoi pas partout", the hardware decoding kept, the switch automatic when needed).
//
// The choice is made before playback, from what the server already told of the film's file (its container and the
// codecs of its streams, PlexFilmPart): the device's own player (Media3 and the device's decoders) when it decodes
// every stream that plays, else libmpv where the build has it (the Quest build of 46: hardware video decoding through
// MediaCodec, FFmpeg in software for what the hardware refuses, stream by stream), else the server's conversion (the
// Plex transcoder, HLS) when the user lets the server convert, else the device's player anyway, which then says why.
// A player that fails at run time hands the film to the next one of that order (nextFilmPlayer).
//
// Codec names are Plex's (the codec attribute of a stream: "h264", "hevc", "mpeg4", "msmpeg4v3", "dca", "truehd"),
// lower case; containers too ("mkv", "mp4", "avi", "mpegts", "asf").

import 'package:immich_mobile/domain/models/film_player_preference.dart';

export 'package:immich_mobile/domain/models/film_player_preference.dart';

/// Who plays the film
enum FilmPlayerKind {
  /// The device's own player and decoders (Media3 on Android)
  device,

  /// libmpv (media_kit): hardware video decoding, FFmpeg for the rest
  mpv,

  /// The Plex server converts the film (HLS) into what the device decodes
  serverConversion,
}

/// Why [FilmPlayerChoice.kind] was chosen, for the log and the tests
enum FilmPlayerReason {
  /// The user picked the player
  asked,

  /// The streams are not known (no answer of the server, or not a Plex film): the device's player
  streamsUnknown,

  /// The device decodes every stream that plays
  deviceDecodesAll,

  /// The device lacks a decoder, libmpv has them all
  deviceLacks,

  /// Neither the device nor libmpv decodes every stream: the server converts
  noLocalDecoder,

  /// Nothing better: libmpv plays what it decodes (a TrueHD track stays silent), or the device's player says why
  bestEffort,

  /// The user asked for libmpv, which this build does not have
  mpvMissing,
}

/// The streams of a film's file that matter for the choice: the video, the audio track that plays (the one the account
/// picked, else the default one, else the first), and the subtitles shown (the picked ones, null for none)
class FilmStreams {
  const FilmStreams({
    this.container,
    this.videoCodec,
    this.videoProfile,
    this.audioCodec,
    this.audioProfile,
    this.subtitleCodec,
  });

  final String? container;
  final String? videoCodec;

  /// Plex's profile of the video ("high", "high 10", "main 10", "advanced simple"), lower case
  final String? videoProfile;
  final String? audioCodec;

  /// Plex's profile of the audio ("ma" for DTS-HD Master Audio, "lc" for AAC), lower case
  final String? audioProfile;
  final String? subtitleCodec;

  @override
  bool operator ==(Object other) =>
      other is FilmStreams &&
      other.container == container &&
      other.videoCodec == videoCodec &&
      other.videoProfile == videoProfile &&
      other.audioCodec == audioCodec &&
      other.audioProfile == audioProfile &&
      other.subtitleCodec == subtitleCodec;

  @override
  int get hashCode => Object.hash(container, videoCodec, videoProfile, audioCodec, audioProfile, subtitleCodec);

  @override
  String toString() =>
      'container $container, video $videoCodec${videoProfile == null ? '' : ' ($videoProfile)'}, audio $audioCodec'
      '${audioProfile == null ? '' : ' ($audioProfile)'}, subtitles $subtitleCodec';
}

/// What a player decodes, in Plex's names. A codec that is not listed is not decoded; a null set means any.
class FilmDecoders {
  const FilmDecoders({this.containers, required this.video, required this.audio, this.refusedVideoProfiles = const {}});

  final Set<String>? containers;
  final Set<String> video;
  final Set<String> audio;

  /// Profiles of a video codec the player refuses although it decodes the codec: "h264" to {"high 10"}
  final Map<String, Set<String>> refusedVideoProfiles;

  /// What of [streams] this player does not decode, as "video msmpeg4v3", "audio dca", "container asf"; empty when it
  /// decodes everything. The subtitles never count: a player that cannot draw them still plays the film.
  List<String> missing(FilmStreams streams) {
    final container = streams.container;
    final video = streams.videoCodec;
    final audio = streams.audioCodec;
    final refused = video == null ? null : refusedVideoProfiles[video];
    final profile = streams.videoProfile;
    return [
      if (container != null && containers != null && !containers!.contains(container)) 'container $container',
      if (video != null && !this.video.contains(video)) 'video $video',
      if (video != null && this.video.contains(video) && profile != null && (refused?.contains(profile) ?? false))
        'video $video ($profile)',
      if (audio != null && !this.audio.contains(audio)) 'audio $audio',
    ];
  }
}

/// The choice and what led to it
class FilmPlayerChoice {
  const FilmPlayerChoice(this.kind, this.reason, {this.deviceMissing = const [], this.mpvMissing = const []});

  final FilmPlayerKind kind;
  final FilmPlayerReason reason;

  /// What the device's player does not decode (see FilmDecoders.missing)
  final List<String> deviceMissing;

  /// What libmpv does not decode; empty when the build has no libmpv
  final List<String> mpvMissing;

  /// The line of the log: no title, no file name, only the codecs
  String get logLine {
    final lacks = [
      if (deviceMissing.isNotEmpty) 'the device lacks ${deviceMissing.join(', ')}',
      if (mpvMissing.isNotEmpty) 'libmpv lacks ${mpvMissing.join(', ')}',
    ];
    return 'Film player: ${kind.name} (${reason.name}${lacks.isEmpty ? '' : '; ${lacks.join('; ')}'})';
  }
}

/// The player of a film whose streams are [streams] (null when the server did not tell them), on a device that
/// decodes what [device] says, with libmpv when [mpv] is given, the server allowed to convert when [conversion].
FilmPlayerChoice chooseFilmPlayer({
  required FilmStreams? streams,
  required FilmDecoders device,
  required FilmDecoders? mpv,
  required FilmPlayerPreference preference,
  required bool conversion,
}) {
  switch (preference) {
    case FilmPlayerPreference.device:
      return const FilmPlayerChoice(FilmPlayerKind.device, FilmPlayerReason.asked);
    case FilmPlayerPreference.mpv:
      return mpv == null
          ? const FilmPlayerChoice(FilmPlayerKind.device, FilmPlayerReason.mpvMissing)
          : const FilmPlayerChoice(FilmPlayerKind.mpv, FilmPlayerReason.asked);
    case FilmPlayerPreference.automatic:
  }
  if (streams == null) {
    return const FilmPlayerChoice(FilmPlayerKind.device, FilmPlayerReason.streamsUnknown);
  }
  final deviceMissing = device.missing(streams);
  if (deviceMissing.isEmpty) {
    return const FilmPlayerChoice(FilmPlayerKind.device, FilmPlayerReason.deviceDecodesAll);
  }
  final mpvMissing = mpv?.missing(streams) ?? const <String>[];
  if (mpv != null && mpvMissing.isEmpty) {
    return FilmPlayerChoice(FilmPlayerKind.mpv, FilmPlayerReason.deviceLacks, deviceMissing: deviceMissing);
  }
  if (conversion) {
    return FilmPlayerChoice(
      FilmPlayerKind.serverConversion,
      FilmPlayerReason.noLocalDecoder,
      deviceMissing: deviceMissing,
      mpvMissing: mpvMissing,
    );
  }
  return FilmPlayerChoice(
    mpv != null ? FilmPlayerKind.mpv : FilmPlayerKind.device,
    FilmPlayerReason.bestEffort,
    deviceMissing: deviceMissing,
    mpvMissing: mpvMissing,
  );
}

/// The player that takes the film over once [current] failed to play it, null when there is none left: the device's
/// player hands it to libmpv (when the build has it and it was not tried yet), libmpv to the server's conversion (when
/// allowed and not tried yet). The conversion is the last one. [tried] holds every player that already failed on this
/// film, [current] included or not.
FilmPlayerKind? nextFilmPlayer(
  FilmPlayerKind current, {
  required Set<FilmPlayerKind> tried,
  required bool mpvAvailable,
  required bool conversion,
}) {
  final failed = {...tried, current};
  if (mpvAvailable && !failed.contains(FilmPlayerKind.mpv) && current == FilmPlayerKind.device) {
    return FilmPlayerKind.mpv;
  }
  if (conversion && !failed.contains(FilmPlayerKind.serverConversion)) {
    return FilmPlayerKind.serverConversion;
  }
  return null;
}
