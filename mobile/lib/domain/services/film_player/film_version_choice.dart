// Which version of a film plays when its server holds several (release 47: La Bataille de Gaulle in 1080p HEVC, 3 GB,
// and 2160p HEVC HDR, 52 GB, always opened in 2160p from the film page). The film page shows the versions; the one
// picked is remembered per film; without a pick the app takes the version this device plays best:
//
// - one it decodes (its video and at least one of its audio tracks, film_decoders.dart), when there is one;
// - not above what the screen shows: the largest version whose height fits the screen, else the smallest one;
// - on a phone, not a very large file ([phoneLargeFileBytes]) when a smaller version is there.
//
// Ties keep the server's order.

/// One version of a film, as the choice sees it
class FilmVersion {
  const FilmVersion({this.height, this.sizeBytes, this.decodable = true});

  /// The height of its picture in lines (2160 for 4K), null when the server does not tell
  final int? height;

  /// The size of its files together, null when not known
  final int? sizeBytes;

  /// Whether a player of this device decodes it
  final bool decodable;
}

/// A file a phone does not take by default when a smaller version exists: 20 GB, the size of a 1080p Blu-ray remux
const phoneLargeFileBytes = 20 * 1000 * 1000 * 1000;

/// The place of the version to play among [versions]: [remembered] when it is a place of the list, else the best one
/// for a screen [screenHeight] lines high (its shorter side in pixels, null when not known), on a phone when [phone]
int chooseFilmVersion(List<FilmVersion> versions, {int? remembered, int? screenHeight, bool phone = false}) {
  if (versions.isEmpty) {
    return 0;
  }
  if (remembered != null && remembered >= 0 && remembered < versions.length) {
    return remembered;
  }
  var candidates = [
    for (final (index, version) in versions.indexed)
      if (version.decodable) index,
  ];
  if (candidates.isEmpty) {
    candidates = [for (var index = 0; index < versions.length; index++) index];
  }
  if (phone) {
    final small = candidates.where((index) => (versions[index].sizeBytes ?? 0) < phoneLargeFileBytes).toList();
    if (small.isNotEmpty) {
      candidates = small;
    }
  }
  if (screenHeight == null || screenHeight <= 0) {
    return candidates.first;
  }
  // A little room: a 1080p film is 1080 lines, a "1080p" screen of a laptop with scaling may report 1050
  final limit = screenHeight * 11 ~/ 10;
  int? best;
  for (final index in candidates) {
    final height = versions[index].height;
    if (height == null || height > limit) {
      continue;
    }
    if (best == null || height > versions[best].height!) {
      best = index;
    }
  }
  if (best != null) {
    return best;
  }
  // Every version is above the screen: the smallest one, an unknown height counting as the largest
  var smallest = candidates.first;
  for (final index in candidates.skip(1)) {
    final height = versions[index].height;
    final current = versions[smallest].height;
    if (height != null && (current == null || height < current)) {
      smallest = index;
    }
  }
  return smallest;
}
