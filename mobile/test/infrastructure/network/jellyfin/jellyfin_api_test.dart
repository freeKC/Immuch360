// The parsers of jellyfin_api.dart on the answers recorded from Jellyfin 12.4, Jellyfin 10.10 and Emby 4.10 on the
// release 49 bench (test/fixtures/jellyfin*, test/fixtures/emby).

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';

import 'fake_jellyfin_server.dart';

void main() {
  group('public information', () {
    test('Jellyfin 12.4 and 10.10 name themselves, Emby has no ProductName', () {
      final j12 = JellyfinPublicInfo.parse(jellyfinFixture('jellyfin', 'system_info_public'))!;
      expect(j12.product, JellyfinProduct.jellyfin);
      expect(j12.version, '12.4.0');
      expect(j12.startupWizardCompleted, isTrue);
      expect(isJellyfinServerId(j12.id), isTrue);
      final j10 = JellyfinPublicInfo.parse(jellyfinFixture('jellyfin-10.10', 'system_info_public'))!;
      expect(j10.product, JellyfinProduct.jellyfin);
      expect(j10.version, '10.10.7');
      final emby = JellyfinPublicInfo.parse(jellyfinFixture('emby', 'system_info_public'))!;
      expect(emby.product, JellyfinProduct.emby);
      expect(emby.version, '4.10.2.0');
      expect(emby.startupWizardCompleted, isNull);
    });

    test('an answer without a server id or a version is no server of either product', () {
      expect(JellyfinPublicInfo.parse({'Version': '12.4.0', 'ProductName': 'Jellyfin Server'}), isNull);
      expect(JellyfinPublicInfo.parse({'Id': 'abc', 'Version': '12.4.0', 'ProductName': 'Jellyfin Server'}), isNull);
      expect(JellyfinPublicInfo.parse({'Id': '0123456789abcdef0123456789abcdef'}), isNull);
      expect(
        JellyfinPublicInfo.parse({'Id': '0123456789abcdef0123456789abcdef', 'Version': '1', 'ProductName': 'Plex'}),
        isNull,
      );
      expect(JellyfinPublicInfo.parse('<html>'), isNull);
      expect(JellyfinPublicInfo.parse(null), isNull);
    });
  });

  test('a sign in gives the token and the user', () {
    for (final folder in ['jellyfin', 'jellyfin-10.10', 'emby']) {
      final result = JellyfinSignIn.parse(jellyfinFixture(folder, 'authenticate_by_name'))!;
      expect(result.accessToken, 'redacted');
      expect(result.userName, 'viewer');
      expect(result.userId, isNotEmpty);
    }
    expect(
      JellyfinSignIn.parse({
        'User': {'Id': 'x'},
      }),
      isNull,
    );
  });

  test('public users: none on Jellyfin by default, the two users on Emby', () {
    expect(JellyfinPublicUser.parseList(jellyfinFixture('jellyfin', 'users_public')), isEmpty);
    final users = JellyfinPublicUser.parseList(jellyfinFixture('emby', 'users_public'));
    expect(users.map((u) => u.name), ['admin', 'viewer']);
  });

  test('Quick Connect: a six digit code and a secret', () {
    final started = JellyfinQuickConnect.parse(jellyfinFixture('jellyfin', 'quick_connect_initiate'))!;
    expect(started.code, matches(RegExp(r'^\d{6}$')));
    expect(started.secret, 'redacted');
    expect(started.authenticated, isFalse);
  });

  group('items', () {
    test('the films with their media sources, paths, 3D and streams', () {
      final page = JellyfinItemsPage.parse(jellyfinFixture('jellyfin', 'items_films'));
      expect(page.totalRecordCount, 5);
      final stereo = page.items.firstWhere((i) => i.name == 'Stereo (2022)');
      expect(stereo.isMovie, isTrue);
      expect(stereo.isVideo, isTrue);
      expect(stereo.productionYear, 2022);
      expect(stereo.video3DFormat, 'HalfSideBySide');
      final source = stereo.firstSource!;
      expect(source.path, '/media/films/Stereo (2022)/Stereo (2022) 3D.HSBS.mkv');
      expect(source.container, 'mkv');
      expect(source.size, 8005300);
      expect(source.video!.codec, 'hevc');
      expect(source.video!.width, 1920);
      final tone = page.items.firstWhere((i) => i.name == 'Tone (2021)');
      expect(tone.firstSource!.streams.where((s) => s.isAudio).single.codec, 'dts');
      expect(tone.runTimeMs, closeTo(20000, 200));
    });

    test('Emby: numeric ids, names without the year, no 3D from the file name', () {
      final page = JellyfinItemsPage.parse(jellyfinFixture('emby', 'items_films'));
      final stereo = page.items.firstWhere((i) => i.name == 'Stereo');
      expect(stereo.id, matches(RegExp(r'^\d+$')));
      expect(stereo.video3DFormat, isNull);
      expect(stereo.firstSource!.path, endsWith('Stereo (2022) 3D.HSBS.mkv'));
    });

    test('libraries, series, seasons and episodes', () {
      final views = JellyfinItemsPage.parse(jellyfinFixture('jellyfin', 'views')).items;
      expect(views.map((v) => v.collectionType), ['movies', 'homevideos', 'homevideos', 'tvshows']);
      final series = JellyfinItemsPage.parse(jellyfinFixture('jellyfin', 'items_series')).items.single;
      expect(series.isSeries, isTrue);
      expect(series.isFolder, isTrue);
      final seasons = JellyfinItemsPage.parse(jellyfinFixture('jellyfin', 'seasons')).items;
      expect(seasons.single.isSeason, isTrue);
      expect(seasons.single.indexNumber, 1);
      final episodes = JellyfinItemsPage.parse(jellyfinFixture('jellyfin', 'episodes')).items;
      expect(episodes.map((e) => (e.parentIndexNumber, e.indexNumber)), [(1, 1), (1, 2)]);
      expect(episodes.first.seriesId, series.id);
      expect(episodes.first.userData!.positionMs, 0);
    });

    test('photos have a path and a picture but no media source', () {
      final photos = JellyfinItemsPage.parse(jellyfinFixture('jellyfin', 'items_photos_2024')).items;
      final pano = photos.firstWhere((p) => p.name == 'pano-001');
      expect(pano.isPhoto, isTrue);
      expect(pano.mediaSources, isEmpty);
      expect(pano.path, '/media/photos/2024/pano-001.jpg');
      expect(pano.primaryImageTag, isNotNull);
    });
  });

  test('PlaybackInfo of a conversion: an HLS TranscodingUrl and a play session', () {
    for (final folder in ['jellyfin', 'jellyfin-10.10', 'emby']) {
      final info = JellyfinPlaybackInfo.parse(jellyfinFixture(folder, 'playback_info_conversion'));
      final source = info.mediaSources.single;
      expect(source.transcodingSubProtocol, 'hls', reason: folder);
      expect(source.transcodingUrl, contains('/master.m3u8?'), reason: folder);
      expect(info.playSessionId, isNotEmpty, reason: folder);
    }
  });

  test('the discovery answer keeps the scheme and the port of Address, not its host', () {
    final answer = JellyfinDiscoveryAnswer.parse({
      'Address': 'http://172.17.0.3:8096',
      'Id': '20C74532649049ADBCB7A9AC5ABA0149',
      'Name': 'Box',
      'EndpointAddress': null,
    })!;
    expect(answer.id, '20c74532649049adbcb7a9ac5aba0149');
    expect(answer.port, 8096);
    expect(answer.useTls, isFalse);
    expect(
      JellyfinDiscoveryAnswer.parse({'Address': 'https://x:8920', 'Id': '0123456789abcdef0123456789abcdef'})!.useTls,
      isTrue,
    );
    expect(JellyfinDiscoveryAnswer.parse({'Address': 'http://x:8096', 'Id': 'short'}), isNull);
    expect(JellyfinDiscoveryAnswer.parse('who is JellyfinServer?'), isNull);
  });

  test('ticks are 100 ns', () {
    expect(jellyfinTicksToMs(1800000000), 180000);
    expect(jellyfinMsToTicks(180000), 1800000000);
    expect(jellyfinTicksToMs(-1), isNull);
  });
}
