// The play message of every kind (release 52): round trips, the refusals of fields out of bounds, and the Plex play
// still written exactly as build 51 writes it, so that a build 51 screen plays a film from a build 52 phone.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';

const _asset = '3f2504e0-4f89-11d3-9a0c-0305e82c3301';
const _user = 'a1b2c3d4-0000-4000-8000-00000000abcd';

void main() {
  group('Plex', () {
    test('a play is written as build 51 wrote it, key for key', () {
      const item = PlayItem(
        server: 'abcdef0123456789',
        item: '4242',
        serverName: 'Home Plex',
        title: 'A film',
        offsetMs: 5000,
        audio: PlayTrackChoice(language: 'fr'),
        subtitle: PlayTrackChoice(off: true),
      );
      // What build 51 sent (PlayItem.toJson of 3f6eae6118), in its order
      expect(
        jsonEncode(item.toJson()),
        '{"kind":"plex","server":"abcdef0123456789","item":"4242","serverName":"Home Plex","title":"A film",'
        '"offsetMs":5000,"audio":{"lang":"fr"},"subtitle":{"off":true}}',
      );
    });

    test('round trip, and the target it names', () {
      final back = PlayItem.fromJson(const PlayItem(server: 'ABCDEF0123456789', item: '7').toJson())!;
      expect(back.kind, PlayKind.plex);
      expect(back.server, 'abcdef0123456789');
      expect(back.item, '7');
      expect(back.target, isA<PlexPlayTarget>());
      expect(back.media, PlayMedia.video);
    });
  });

  group('Immich', () {
    test('round trip of a photo of a 360 panorama', () {
      const item = PlayItem.of(
        ImmichPlayTarget(
          asset: _asset,
          user: _user,
          endpointHashes: ['0123456789abcdef0123456789abcdef'],
          media: PlayMedia.photo,
          projection: PlayProjection.equirect,
        ),
        title: 'IMG_0001.jpg',
      );
      final back = PlayItem.fromJson(jsonDecode(jsonEncode(item.toJson())) as Map<String, Object?>)!;
      final target = back.target as ImmichPlayTarget;
      expect(back.kind, PlayKind.immich);
      expect(target.asset, _asset);
      expect(target.user, _user);
      expect(target.endpointHashes, ['0123456789abcdef0123456789abcdef']);
      expect(target.media, PlayMedia.photo);
      expect(target.projection, PlayProjection.equirect);
      expect(back.title, 'IMG_0001.jpg');
      expect(back.server, 'immich');
      expect(back.item, _asset);
    });

    test('no token, no session, no password in what goes', () {
      final json = const PlayItem.of(ImmichPlayTarget(asset: _asset, user: _user)).toJson();
      expect(json.keys.toSet(), {'kind', 'asset', 'user', 'media', 'offsetMs'});
    });

    test('refused: an id that is no UUID, a missing user, five addresses, an address of another scheme', () {
      Map<String, Object?> play(Map<String, Object?> changes) => {
        'kind': 'immich',
        'asset': _asset,
        'user': _user,
        'media': 'video',
        ...changes,
      };
      expect(PlayItem.fromJson(play({})), isNotNull);
      expect(PlayItem.fromJson(play({'asset': '../../etc/passwd'})), isNull);
      expect(PlayItem.fromJson(play({'asset': '42'})), isNull);
      expect(PlayItem.fromJson(play({'user': null})), isNull);
      expect(PlayItem.fromJson(play({'media': 'film'})), isNull);
      final hash = immichEndpointHash('https://a.example')!;
      expect(PlayItem.fromJson(play({'endpointHashes': List.filled(4, hash)})), isNotNull);
      expect(PlayItem.fromJson(play({'endpointHashes': List.filled(5, hash)})), isNull);
      // An address in clear is no hash: refused
      expect(
        PlayItem.fromJson(
          play({
            'endpointHashes': ['https://a.example'],
          }),
        ),
        isNull,
      );
      expect(
        PlayItem.fromJson(
          play({
            'endpointHashes': [hash.toUpperCase()],
          }),
        ),
        isNull,
      );
      expect(PlayItem.fromJson(play({'endpointHashes': hash})), isNull);
    });

    test('an address goes as the hash of its normalised form only', () {
      final hash = immichEndpointHash('HTTPS://Photos.Example.org:443/api/')!;
      expect(hash, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(immichEndpointHash('https://photos.example.org'), hash);
      expect(immichEndpointHash('https://other.example.org'), isNot(hash));
      expect(immichEndpointHash('ftp://example.org'), isNull);
      final json = jsonEncode(
        PlayItem.of(ImmichPlayTarget(asset: _asset, user: _user, endpointHashes: [hash])).toJson(),
      );
      expect(json, isNot(contains('photos.example')));
    });

    test('addresses compare whatever the way they were typed', () {
      expect(normaliseImmichEndpoint('HTTPS://Photos.Example.org:443/api/'), 'https://photos.example.org');
      expect(normaliseImmichEndpoint('http://192.168.1.10:2283/api'), 'http://192.168.1.10:2283');
      expect(normaliseImmichEndpoint('https://example.org/immich/api'), 'https://example.org/immich');
      expect(normaliseImmichEndpoint('ftp://example.org'), isNull);
      expect(normaliseImmichEndpoint('not a url'), isNull);
    });
  });

  group('shares and media servers', () {
    test('round trip of a share file and of a Jellyfin item', () {
      final share = PlayItem.fromJson(
        const PlayItem.of(
          SharePlayTarget(type: PlayShareType.smb, source: 'nas.local/Videos', path: '/Holidays/2025/beach.mp4'),
        ).toJson(),
      )!;
      final target = share.target as SharePlayTarget;
      expect(target.type, PlayShareType.smb);
      expect(target.source, 'nas.local/Videos');
      expect(target.path, '/Holidays/2025/beach.mp4');
      expect(share.server, 'smb:nas.local/Videos');

      final jellyfin = PlayItem.fromJson(
        const PlayItem.of(
          MediaServerPlayTarget(type: PlayMediaServerType.jellyfin, server: 'F00D', item: 'abc123'),
        ).toJson(),
      )!;
      final film = jellyfin.target as MediaServerPlayTarget;
      expect(film.type, PlayMediaServerType.jellyfin);
      expect(film.server, 'f00d');
      expect(film.item, 'abc123');
    });

    test('a path that climbs out of the share, or carries a control character, is refused', () {
      Map<String, Object?> play(String path) => {
        'kind': 'share',
        'protocol': 'webdav',
        'source': 'cloud.example:8443/dav',
        'path': path,
        'media': 'photo',
      };
      expect(PlayItem.fromJson(play('/a/b.jpg')), isNotNull);
      expect(PlayItem.fromJson(play('/a/../../b.jpg')), isNull);
      expect(PlayItem.fromJson(play('a/b.jpg')), isNull);
      expect(PlayItem.fromJson(play('/a\\b.jpg')), isNull);
      expect(PlayItem.fromJson(play('/a/\u0000b.jpg')), isNull);
      expect(PlayItem.fromJson(play('/${'x' * 1100}')), isNull);
      expect(PlayItem.fromJson({...play('/a.jpg'), 'source': 'user@nas/share'}), isNull);
      expect(PlayItem.fromJson({...play('/a.jpg'), 'protocol': 'ftp'}), isNull);
    });

    test('no target writes "type", the key of the command it travels in', () {
      for (final target in const <PlayTarget>[
        PlexPlayTarget(server: 'abcdef0123456789', item: '1'),
        ImmichPlayTarget(asset: _asset, user: _user),
        SharePlayTarget(type: PlayShareType.dlna, source: 'uuid:1', path: '/a.mp4'),
        MediaServerPlayTarget(type: PlayMediaServerType.emby, server: 'f00d', item: '12'),
      ]) {
        expect(PlayItem.of(target).toJson().containsKey('type'), isFalse, reason: target.kind.wire);
      }
    });

    test('a kind this build does not know is no item', () {
      expect(PlayItem.fromJson({'kind': 'relay', 'url': 'http://10.0.0.1/x'}), isNull);
      expect(PlayItem.fromJson({'kind': 'plex', 'server': 'short', 'item': '1'}), isNull);
    });
  });

  group('state', () {
    test('the item of any kind goes back whole beside the 16 characters of build 51', () {
      const state = ScreenPlayState(
        seq: 3,
        phase: ScreenPlayPhase.showing,
        server: 'immich',
        itemKey: _asset,
        media: PlayMedia.photo,
      );
      final back = ScreenPlayState.fromJson(jsonDecode(jsonEncode(state.toJson())));
      expect(back.itemKey, _asset);
      expect(back.key, _asset);
      expect(back.media, PlayMedia.photo);
      expect(back.phase, ScreenPlayPhase.showing);
      expect(back.isActive, isTrue);
      expect(back.sameAs(state), isTrue);
    });

    test('a 360° view of the screen goes as view: sphere, and never to another phone', () {
      const state = ScreenPlayState(seq: 4, phase: ScreenPlayPhase.playing, media: PlayMedia.video, sphere: true);
      expect(state.toJson()['view'], 'sphere');
      expect(ScreenPlayState.fromJson(state.toJson()).sphere, isTrue);
      expect(ScreenPlayState.fromJson({'seq': 1, 'phase': 'playing'}).sphere, isFalse);
      expect(state.withoutItem().toJson().containsKey('view'), isFalse);
      expect(state.sameAs(state.next(sphere: false)), isFalse);
    });

    test('a state of build 51 gives its item as the key', () {
      final back = ScreenPlayState.fromJson({'seq': 1, 'phase': 'playing', 'server': 'abc', 'item': '42'});
      expect(back.key, '42');
      expect(back.media, isNull);
    });

    test('the new reasons go and come back', () {
      for (final reason in ScreenPlayReason.values) {
        expect(ScreenPlayReason.fromWire(reason.wire), reason);
      }
    });
  });
}
