// Why the Plex server converts a film for this device, in the names a user knows (release 47)

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/film_player/film_conversion_reason.dart';

void main() {
  test('the codecs Plex names get the names on the box', () {
    expect(filmFormatName('dca'), 'DTS');
    expect(filmFormatName('DTS'), 'DTS');
    expect(filmFormatName('msmpeg4v3'), 'DivX 3');
    expect(filmFormatName('truehd'), 'Dolby TrueHD');
    expect(filmFormatName('avi'), 'AVI', reason: 'a name the app does not know is shown in capitals');
  });

  test('what the device lacks: the codecs once each, a refused profile with its codec', () {
    expect(filmConversionFormats(['audio dca']), ['DTS']);
    expect(filmConversionFormats(['container avi', 'video msmpeg4v3', 'audio mp3']), ['DivX 3', 'MP3']);
    expect(filmConversionFormats(['audio dca', 'audio dts']), ['DTS']);
    expect(filmConversionFormats(['video h264 (high 10)']), ['H.264 High 10']);
  });

  test('the container only when every codec is there, nothing when nothing is listed', () {
    expect(filmConversionFormats(['container asf']), ['ASF']);
    expect(filmConversionFormats(const []), isEmpty);
    expect(filmConversionFormats(['nonsense']), isEmpty);
  });
}
