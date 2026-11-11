import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/film_player/device_decoder_types.dart';
import 'package:immich_mobile/domain/services/film_player/film_player_choice.dart';
import 'package:immich_mobile/providers/network/film_player.provider.dart';

const _quest = {'video/avc', 'video/hevc', 'audio/eac3', 'audio/ac3', 'audio/mp4a-latm', 'audio/mpeg'};
const _dts = FilmStreams(container: 'mkv', videoCodec: 'h264', audioCodec: 'dca');

FilmPlayers _players({Set<String>? types = _quest, bool mpv = true}) =>
    FilmPlayers(decoderTypes: DeviceDecoderTypes(read: () async => types), mpvReady: () async => mpv);

void main() {
  test('the device decoders and libmpv of the build choose the player', () async {
    final players = _players();
    expect(
      (await players.choose(_dts, preference: FilmPlayerPreference.automatic, conversion: true)).kind,
      FilmPlayerKind.mpv,
    );
    expect(
      (await _players(mpv: false).choose(_dts, preference: FilmPlayerPreference.automatic, conversion: true)).kind,
      FilmPlayerKind.serverConversion,
    );
  });

  test('a device that does not tell its decoders keeps its player, unless mpv is asked', () async {
    final players = _players(types: null);
    final choice = await players.choose(_dts, preference: FilmPlayerPreference.automatic, conversion: true);
    expect(choice.kind, FilmPlayerKind.device);
    expect(choice.reason, FilmPlayerReason.streamsUnknown);
    expect(
      (await players.choose(_dts, preference: FilmPlayerPreference.mpv, conversion: true)).kind,
      FilmPlayerKind.mpv,
    );
  });

  test('the conversion sends E-AC-3 and AC-3 to a device that decodes them, AAC alone otherwise', () async {
    expect(await _players().conversionAudioCodecs(), ['eac3', 'ac3']);
    expect(await _players(types: {'audio/mp4a-latm'}).conversionAudioCodecs(), isEmpty);
    expect(await _players(types: null).conversionAudioCodecs(), isEmpty);
  });
}
