import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/video_track_naming.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_tracks.dart';

class _FakeServer implements PlexTrackServer {
  final Map<int, Uint8List?> files = {};
  final List<({int partId, int? audio, int? subtitle})> picks = [];
  bool failFiles = false;

  @override
  Future<Uint8List?> subtitleFile(PlexStream stream) async {
    if (failFiles) {
      throw const SocketException('down');
    }
    return files[stream.id];
  }

  @override
  Future<void> selectStreams(int partId, {int? audioStreamId, int? subtitleStreamId}) async =>
      picks.add((partId: partId, audio: audioStreamId, subtitle: subtitleStreamId));
}

PlexFilmPart _part() =>
    parsePlexFilmDetails(jsonDecode(File('test/fixtures/plex/metadata_film.json').readAsStringSync()))!.parts.single;

VideoTrackRef _audio(int ordinal, [String? language]) =>
    VideoTrackRef(kind: VideoTrackKind.audio, ordinal: ordinal, language: language);

void main() {
  late LocalMediaBridge bridge;
  late _FakeServer server;

  setUp(() async {
    bridge = LocalMediaBridge();
    await bridge.start();
    server = _FakeServer();
  });
  tearDown(() => bridge.stop());

  test('serves the text subtitle files beside the film on the bridge, never the image ones', () async {
    server.files[40105] = Uint8List.fromList(utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nBonjour\n'));
    final tracks = await PlexFilmTracks.load(server, _part(), bridge);
    final subtitle = tracks.subtitles.single;
    expect(subtitle.id, '${videoSidecarIdPrefix}40105');
    expect(subtitle.mimeType, 'application/x-subrip');
    expect(subtitle.language, 'fr');
    expect(subtitle.label, 'Français Forced (SRT External)');
    final url = Uri.parse(subtitle.uri);
    expect(url.host, '127.0.0.1');
    expect(url.toString(), isNot(contains('token')), reason: 'no Plex token in the address a player gets');
    final answer = await http.get(url);
    expect(answer.statusCode, 200);
    expect(answer.body, contains('Bonjour'));
    tracks.dispose();
    expect((await http.get(url)).statusCode, 404, reason: 'gone from the bridge with the page');
  });

  test('a subtitle file that does not come is left out, the film plays without it', () async {
    server.failFiles = true;
    final tracks = await PlexFilmTracks.load(server, _part(), bridge);
    expect(tracks.subtitles, isEmpty);
    tracks.dispose();
  });

  test('names the tracks inside the file by their place, when the languages agree', () async {
    final tracks = await PlexFilmTracks.load(server, _part(), bridge);
    expect(tracks.labelOf(_audio(0, 'fr')), 'Français (AC3 5.1)');
    expect(tracks.labelOf(_audio(1, 'eng')), 'English (AC3 5.1)', reason: 'a three letter code agrees too');
    expect(tracks.labelOf(_audio(1)), 'English (AC3 5.1)', reason: 'no language says nothing against it');
    expect(tracks.labelOf(_audio(0, 'de')), isNull, reason: 'never the name of another track');
    expect(tracks.labelOf(_audio(2, 'fr')), isNull, reason: 'a track Plex does not list');
    expect(
      tracks.labelOf(const VideoTrackRef(kind: VideoTrackKind.subtitle, ordinal: 0, language: 'en')),
      'English (SRT)',
    );
    expect(
      tracks.labelOf(const VideoTrackRef(kind: VideoTrackKind.subtitle, sidecarId: '${videoSidecarIdPrefix}40105')),
      'Français Forced (SRT External)',
    );
    tracks.dispose();
  });

  test('writes a pick back to the part, subtitles off as 0', () async {
    final tracks = await PlexFilmTracks.load(server, _part(), bridge);
    tracks.picked(VideoTrackKind.audio, _audio(1, 'en'));
    tracks.picked(VideoTrackKind.subtitle, const VideoTrackRef(kind: VideoTrackKind.subtitle, ordinal: 0));
    tracks.picked(VideoTrackKind.subtitle, null);
    // An audio track Plex does not know is not written
    tracks.picked(VideoTrackKind.audio, _audio(5));
    await Future<void>.delayed(Duration.zero);
    expect(server.picks, [
      (partId: 4010, audio: 40103, subtitle: null),
      (partId: 4010, audio: null, subtitle: 40104),
      (partId: 4010, audio: null, subtitle: 0),
    ]);
    tracks.dispose();
  });

  test('tells the tracks Plex has for the account', () async {
    server.files[40105] = Uint8List.fromList(utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nBonjour\n'));
    final tracks = await PlexFilmTracks.load(server, _part(), bridge);
    expect(tracks.selectedAudio?.id, 40102);
    expect(tracks.selectedSubtitle, const VideoTrackRef(kind: VideoTrackKind.subtitle, sidecarId: 'immuch-sub-40105'));
    tracks.dispose();
  });

  test('plexLanguagesAgree', () {
    const french = PlexStream(id: 1, type: PlexStreamType.audio, languageTag: 'fr', languageCode: 'fra');
    expect(plexLanguagesAgree('fr', french), isTrue);
    expect(plexLanguagesAgree('fre', french), isTrue);
    expect(plexLanguagesAgree('fra', french), isTrue);
    expect(plexLanguagesAgree('fr-CA', french), isTrue);
    expect(plexLanguagesAgree('und', french), isTrue);
    expect(plexLanguagesAgree('en', french), isFalse);
    expect(plexLanguagesAgree('eng', french), isFalse);
    expect(plexLanguagesAgree('en', const PlexStream(id: 2, type: PlexStreamType.audio)), isTrue);
  });
}
