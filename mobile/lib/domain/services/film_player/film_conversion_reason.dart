// Why the Plex server converts a film for this device, in words a user knows (release 47, the S24 test of 13 November
// 2026: a DTS film and a DivX 3 film played converted with only an icon to tell it). The choice (film_player_choice.dart)
// lists what the device's player lacks as "audio dca", "video msmpeg4v3", "video h264 (high 10)" or "container avi";
// these are their names on a box or in a file manager.

/// The names of the formats of Plex (its codec and container names, lower case) that differ from their upper case
const _formatNames = {
  // Audio
  'dca': 'DTS',
  'dts': 'DTS',
  'truehd': 'Dolby TrueHD',
  'mlp': 'MLP',
  'eac3': 'Dolby Digital Plus',
  'ac3': 'Dolby Digital',
  'wmav2': 'WMA',
  'wmapro': 'WMA Pro',
  'wmav1': 'WMA',
  'mp2': 'MPEG audio layer 2',
  'pcm': 'PCM',
  'flac': 'FLAC',
  'opus': 'Opus',
  'vorbis': 'Vorbis',
  // Video
  'msmpeg4v3': 'DivX 3',
  'msmpeg4v2': 'MS MPEG-4 v2',
  'msmpeg4': 'MS MPEG-4',
  'mpeg4': 'MPEG-4 Part 2 (DivX, Xvid)',
  'wmv3': 'WMV 9',
  'wmv2': 'WMV 8',
  'wmv1': 'WMV 7',
  'vc1': 'VC-1',
  'mpeg2video': 'MPEG-2',
  'mpeg1video': 'MPEG-1',
  'h264': 'H.264',
  'hevc': 'HEVC',
  'vp9': 'VP9',
  'vp8': 'VP8',
  'av1': 'AV1',
  'h263': 'H.263',
  'rv40': 'RealVideo 4',
  'rv30': 'RealVideo 3',
};

/// The name a user knows for the Plex format [format] ("dca" is "DTS"), its upper case when the app has none
String filmFormatName(String format) {
  final key = format.trim().toLowerCase();
  return _formatNames[key] ?? key.toUpperCase();
}

/// What the device's player cannot play, from [deviceMissing] of a FilmPlayerChoice, in the names of [filmFormatName]:
/// the codecs (with a refused profile: "H.264 High 10"), each once, in their order; the container only when no codec is
/// missing (an AVI whose codecs the device has). Empty when nothing is listed (a conversion after a player failed).
List<String> filmConversionFormats(List<String> deviceMissing) {
  final codecs = <String>[];
  final containers = <String>[];
  for (final missing in deviceMissing) {
    final space = missing.indexOf(' ');
    if (space <= 0) {
      continue;
    }
    final kind = missing.substring(0, space);
    final rest = missing.substring(space + 1).trim();
    final profile = RegExp(r'^(\S+)\s+\((.+)\)$').firstMatch(rest);
    final name = profile == null
        ? filmFormatName(rest)
        : '${filmFormatName(profile.group(1)!)} ${_titleCase(profile.group(2)!)}';
    final into = kind == 'container' ? containers : codecs;
    if (!into.contains(name)) {
      into.add(name);
    }
  }
  return codecs.isNotEmpty ? codecs : containers;
}

String _titleCase(String text) =>
    text.split(' ').map((word) => word.isEmpty ? word : word[0].toUpperCase() + word.substring(1)).join(' ');
