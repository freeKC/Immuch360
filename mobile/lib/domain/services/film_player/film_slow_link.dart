// What the video page offers when the link is slower than the film (release 47, the S24 test of 13 November 2026: a
// 2160p file of 43 Mbit/s over a link of 9 to 12 Mbit/s waited 30 s before its first frame and then paused now and
// then): a lighter version of the film when it has one, and the server's conversion down to what the link brings.

/// Another version of a film, offered in place of the one that plays: its label ("1080p HEVC, 3.0 GiB"), the path of
/// its file in the share, its bit rate when the server tells it, and what to do once it is chosen (remember the pick)
typedef FilmVersionOffer = ({String label, String path, int? bitsPerSecond, void Function()? onChosen});

/// The share of the link the conversion may use: the rest is the margin for its ups and downs
const filmSlowLinkShare = 0.7;

/// Bounds of the bit rate asked of a conversion for a slow link, in kbit/s: below 1.5 Mbit/s a film is mush, above 20
/// the server's default holds
const filmConversionMinKbps = 1500;
const filmConversionMaxKbps = 20000;

/// The video bit rate to ask of the server's conversion for a link that brings [linkBitsPerSecond], in kbit/s
int filmConversionKbpsFor(int linkBitsPerSecond) =>
    (linkBitsPerSecond * filmSlowLinkShare / 1000).round().clamp(filmConversionMinKbps, filmConversionMaxKbps);

/// The version to offer for a link that brings [linkBitsPerSecond] while the file at [currentPath] needs
/// [neededBitsPerSecond]: of the other versions lighter than it, the richest one the link carries with its margin
/// ([filmSlowLinkShare]), else the lightest; null when none is known to be lighter
FilmVersionOffer? lighterFilmVersion(
  List<FilmVersionOffer> offers, {
  required String currentPath,
  required int linkBitsPerSecond,
  required int neededBitsPerSecond,
}) {
  final lighter = [
    for (final offer in offers)
      if (offer.path != currentPath && (offer.bitsPerSecond ?? neededBitsPerSecond) < neededBitsPerSecond) offer,
  ]..sort((a, b) => a.bitsPerSecond!.compareTo(b.bitsPerSecond!));
  if (lighter.isEmpty) {
    return null;
  }
  final carried = lighter.where((offer) => offer.bitsPerSecond! <= linkBitsPerSecond * filmSlowLinkShare);
  return carried.isEmpty ? lighter.first : carried.last;
}
