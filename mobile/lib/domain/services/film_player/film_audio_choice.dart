// The audio track of a film when the player in use cannot decode the one it would play (release 47, from the desktop
// Plex validation of 13 November 2026: a film whose default track is Dolby TrueHD played silent on Windows, with no
// word, while its French AC3 5.1 track played once picked by hand).
//
// Before playback the app knows the tracks of the file (from the Plex server, or from mpv once the file is open) and
// what the player decodes (film_decoders.dart): it keeps the track the player would play when it decodes it, else
// picks the first track it decodes, in the same language first, and says so. When none is decodable it says that the
// film has no sound on this device. At run time, when mpv reports that a decoder failed to open, the same pick is made
// once with that codec counted as not decodable.
//
// Codec names are FFmpeg's, as Plex and mpv give them ("truehd", "ac3", "eac3", "dca" or "dts"), lower case.

/// One audio track of a film, in the order of the file
class FilmAudioTrack {
  const FilmAudioTrack({this.codec, this.language, this.isDefault = false});

  /// Its codec, lower case; null when not known, which counts as decodable
  final String? codec;

  /// Its language as the file or the server gives it: a two or three letter code or a BCP 47 tag
  final String? language;
  final bool isDefault;
}

/// What became of the track the player would play
enum FilmAudioOutcome {
  /// It is decoded: nothing changes
  kept,

  /// It is not decoded: another track plays ([FilmAudioPick.index])
  switched,

  /// No track of the film is decoded: the film plays without sound
  none,
}

/// The track to play and why
class FilmAudioPick {
  const FilmAudioPick(this.outcome, {this.index, this.from});

  final FilmAudioOutcome outcome;

  /// The place of the track to play among the audio tracks of the file, null when there is none
  final int? index;

  /// The place of the track the player would have played, when it is not decoded
  final int? from;

  @override
  bool operator ==(Object other) =>
      other is FilmAudioPick && other.outcome == outcome && other.index == index && other.from == from;

  @override
  int get hashCode => Object.hash(outcome, index, from);

  @override
  String toString() => 'FilmAudioPick(${outcome.name}, index $index, from $from)';
}

/// The track of [tracks] to play when the player would play the one at [wanted] (null for the default one, else the
/// first) and decodes a codec when [decodes] says so: [wanted] when it is decoded, else the first decoded track in its
/// language, else the first decoded track, else none
FilmAudioPick pickFilmAudio(List<FilmAudioTrack> tracks, {int? wanted, required bool Function(String codec) decodes}) {
  if (tracks.isEmpty) {
    return const FilmAudioPick(FilmAudioOutcome.kept);
  }
  bool decoded(FilmAudioTrack track) {
    final codec = track.codec?.trim().toLowerCase();
    return codec == null || codec.isEmpty || decodes(canonicalAudioCodec(codec));
  }

  final start = wanted != null && wanted >= 0 && wanted < tracks.length
      ? wanted
      : tracks.indexWhere((track) => track.isDefault).clamp(0, tracks.length - 1);
  if (decoded(tracks[start])) {
    return FilmAudioPick(FilmAudioOutcome.kept, index: start);
  }
  final language = audioLanguageKey(tracks[start].language);
  int? first;
  for (final (index, track) in tracks.indexed) {
    if (!decoded(track)) {
      continue;
    }
    if (language != null && audioLanguageKey(track.language) == language) {
      return FilmAudioPick(FilmAudioOutcome.switched, index: index, from: start);
    }
    first ??= index;
  }
  return first == null
      ? FilmAudioPick(FilmAudioOutcome.none, from: start)
      : FilmAudioPick(FilmAudioOutcome.switched, index: first, from: start);
}

/// One name per codec: DTS is "dca" for Plex and FFmpeg's decoder, "dts" for mpv's track list
String canonicalAudioCodec(String codec) => switch (codec) {
  'dts' => 'dca',
  _ => codec,
};

/// The name of an audio codec in a sentence ("TrueHD", "DTS", "E-AC-3")
String audioCodecDisplayName(String codec) => switch (canonicalAudioCodec(codec.trim().toLowerCase())) {
  'truehd' => 'TrueHD',
  'mlp' => 'MLP',
  'dca' => 'DTS',
  'eac3' => 'E-AC-3',
  'ac3' => 'AC3',
  'aac' => 'AAC',
  'flac' => 'FLAC',
  'opus' => 'Opus',
  'vorbis' => 'Vorbis',
  'mp3' => 'MP3',
  'mp2' => 'MP2',
  'alac' => 'ALAC',
  'wmav1' || 'wmav2' || 'wmapro' || 'wmalossless' => 'WMA',
  final other => other.toUpperCase(),
};

/// The two letter code of [language] ("fr" for "fre", "fra", "fr-FR" or "Fr"), the code itself when the table does
/// not know it; null for none, undefined and multiple
String? audioLanguageKey(String? language) {
  final code = language?.trim().toLowerCase().split(RegExp('[-_]')).first;
  if (code == null || code.isEmpty || code == 'und' || code == 'mul' || code == 'zxx') {
    return null;
  }
  return code.length == 3 ? twoLetterLanguageOf[code] ?? code : code;
}

/// The two letter codes of the three letter ones whose two forms (bibliographic and terminology) differ, and of the
/// common ones a player may report as such
const twoLetterLanguageOf = {
  'eng': 'en',
  'fre': 'fr',
  'fra': 'fr',
  'ger': 'de',
  'deu': 'de',
  'spa': 'es',
  'ita': 'it',
  'por': 'pt',
  'jpn': 'ja',
  'kor': 'ko',
  'chi': 'zh',
  'zho': 'zh',
  'dut': 'nl',
  'nld': 'nl',
  'rus': 'ru',
  'pol': 'pl',
  'swe': 'sv',
  'nor': 'no',
  'nob': 'nb',
  'dan': 'da',
  'fin': 'fi',
  'cze': 'cs',
  'ces': 'cs',
  'gre': 'el',
  'ell': 'el',
  'per': 'fa',
  'fas': 'fa',
  'rum': 'ro',
  'ron': 'ro',
  'slo': 'sk',
  'slk': 'sk',
  'alb': 'sq',
  'sqi': 'sq',
  'arm': 'hy',
  'hye': 'hy',
  'baq': 'eu',
  'eus': 'eu',
  'geo': 'ka',
  'kat': 'ka',
  'ice': 'is',
  'isl': 'is',
  'mac': 'mk',
  'mkd': 'mk',
  'may': 'ms',
  'msa': 'ms',
  'wel': 'cy',
  'cym': 'cy',
  'tur': 'tr',
  'ara': 'ar',
  'heb': 'he',
  'hin': 'hi',
  'hun': 'hu',
  'ukr': 'uk',
  'tha': 'th',
  'vie': 'vi',
  'cat': 'ca',
};
