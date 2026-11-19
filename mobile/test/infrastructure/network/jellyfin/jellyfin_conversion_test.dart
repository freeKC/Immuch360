// The server's conversion of a Jellyfin or Emby film: PlaybackInfo with the device profile, the server's own
// TranscodingUrl without its key, the playlist and its segments served under their numbers with the token in the
// header only, the play session shared with the reports, and the stop that writes no place.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/hls_conversion.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_file_system.dart';

import 'fake_jellyfin_server.dart';
import 'jellyfin_file_system_test.dart' show openJellyfin;

void main() {
  for (final folder in ['jellyfin', 'jellyfin-10.10', 'emby']) {
    test('$folder: the DTS film converted to HLS through the bridge names, its key never sent', () async {
      final server = await FakeJellyfinServer.start(folder: folder);
      addTearDown(server.close);
      final fileSystem = await openJellyfin(server);
      addTearDown(fileSystem.close);
      const path = '/Films/Tone (2021).mkv';
      await fileSystem.list('/Films');
      final conversion = await fileSystem.conversionOfFilm(
        path,
        audioCodecs: const ['eac3', 'ac3'],
        maxVideoBitrateKbps: 8000,
      );
      expect(conversion, isA<HlsConversion>());
      final profile = (server.playbackInfoBodies.single['DeviceProfile']! as Map).cast<String, Object?>();
      expect(profile['DirectPlayProfiles'], isEmpty);
      final transcoding = ((profile['TranscodingProfiles']! as List).single as Map).cast<String, Object?>();
      expect(transcoding['Protocol'], 'hls');
      expect(transcoding['AudioCodec'], 'eac3,ac3,aac');
      expect(transcoding['VideoCodec'], 'h264');
      expect(server.playbackInfoBodies.single['MaxStreamingBitrate'], 8000000);

      final playlist = utf8.decode((await conversion!.fetch(conversion.playlist))!.bytes!);
      expect(playlist, contains('0.ts'));
      expect(playlist, contains('1.ts'));
      expect(playlist, isNot(contains('hls1')), reason: 'the bridge names the segments by number');
      final master = server.requests.firstWhere((r) => r.path.toLowerCase().endsWith('/master.m3u8'));
      expect(master.query.keys.map((k) => k.toLowerCase()), isNot(anyOf(contains('apikey'), contains('api_key'))));
      expect(master.headers.containsKey('authorization') || master.headers.containsKey('x-emby-token'), isTrue);
      final segment = await conversion.fetch('0.ts');
      expect(segment!.contentType, 'video/mp2t');
      expect(segment.bytes, hasLength(188 * 4));
      expect(await conversion.fetch('9.ts'), isNull);

      // The reports of the converted film carry its play session, Transcode
      await fileSystem.playbackStarted(path, Duration.zero, converted: true);
      final session = server.reports.single.body['PlaySessionId'];
      expect(session, isNotEmpty);
      expect(server.reports.single.body['PlayMethod'], 'Transcode');
      await conversion.stop();
      expect(server.encodingsStopped.single, endsWith(' $session'));
      expect(server.reports.where((r) => r.kind == 'stopped'), isEmpty, reason: 'the stop writes no place');
      expect(await conversion.fetch(conversion.playlist), isNull);
    });
  }

  test('a photo is not converted; the device profile names DTS as Jellyfin does', () async {
    final server = await FakeJellyfinServer.start();
    addTearDown(server.close);
    final fileSystem = await openJellyfin(server);
    addTearDown(fileSystem.close);
    await fileSystem.list('/Photos/2024');
    expect(
      await fileSystem.conversionOfFilm('/Photos/2024/pano-001.jpg', audioCodecs: const [], maxVideoBitrateKbps: 1),
      isNull,
    );
    final profile = jellyfinConversionProfile(audioCodecs: const ['dca', 'aac'], maxVideoBitrateKbps: 4000);
    expect(((profile['TranscodingProfiles']! as List).single as Map)['AudioCodec'], 'dts,aac');
  });
}
