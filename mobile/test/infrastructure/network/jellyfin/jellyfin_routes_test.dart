// The route table per product and version (bench of release 49: Jellyfin 12.4 and 10.10 answer /Items?userId= and
// /UserViews, Emby 4.10 answers /Users/{id}/Items and /Users/{id}/Views and fails /Users/Me and /UserViews).

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_routes.dart';

void main() {
  final base = Uri.parse('http://192.0.2.10:8096');

  test('versions', () {
    expect(jellyfinVersionAtLeast('12.4.0', 10, 9), isTrue);
    expect(jellyfinVersionAtLeast('10.10.7', 10, 9), isTrue);
    expect(jellyfinVersionAtLeast('10.9.0', 10, 9), isTrue);
    expect(jellyfinVersionAtLeast('10.8.13', 10, 9), isFalse);
    expect(jellyfinVersionAtLeast(null, 10, 9), isFalse);
    expect(jellyfinVersionAtLeast('garbage', 10, 9), isFalse);
  });

  test('Jellyfin 10.9 and later: /Items?userId= and /UserViews', () {
    for (final version in ['12.4.0', '10.10.7', '11.0.1']) {
      final routes = JellyfinRoutes(base, JellyfinProduct.jellyfin, version);
      expect(routes.userScoped, isFalse);
      expect(routes.tableName, 'items-v2');
      expect(routes.views('u1').toString(), 'http://192.0.2.10:8096/UserViews?userId=u1');
      final items = routes.items('u1', parentId: 'p', startIndex: 200, limit: 200, recursive: true);
      expect(items.path, '/Items');
      expect(items.queryParameters['userId'], 'u1');
      expect(items.queryParameters['parentId'], 'p');
      expect(items.queryParameters['startIndex'], '200');
      expect(items.queryParameters['recursive'], 'true');
      expect(routes.me('u1').path, '/Users/Me');
      expect(routes.item('u1', 'i1').path, '/Items/i1');
    }
  });

  test('Emby and Jellyfin before 10.9: under /Users/{id}', () {
    for (final (product, version) in [(JellyfinProduct.emby, '4.10.2.0'), (JellyfinProduct.jellyfin, '10.8.13')]) {
      final routes = JellyfinRoutes(base, product, version);
      expect(routes.userScoped, isTrue);
      expect(routes.tableName, 'items-v1');
      expect(routes.views('u1').path, '/Users/u1/Views');
      expect(routes.items('u1', parentId: 'p').path, '/Users/u1/Items');
      expect(routes.items('u1').queryParameters.containsKey('userId'), isFalse);
      expect(routes.item('u1', '16').path, '/Users/u1/Items/16');
    }
    expect(JellyfinRoutes(base, JellyfinProduct.emby, '4.10.2.0').me('u1').path, '/Users/u1');
  });

  test('a base path is kept in every route', () {
    final routes = JellyfinRoutes(Uri.parse('https://media.example/jellyfin/'), JellyfinProduct.jellyfin, '12.4.0');
    expect(routes.publicInfo().toString(), 'https://media.example/jellyfin/System/Info/Public');
    expect(
      routes.videoStream('i1', 's1').toString(),
      'https://media.example/jellyfin/Videos/i1/stream?static=true&mediaSourceId=s1',
    );
    expect(routes.file('i1').path, '/jellyfin/Items/i1/File');
    expect(routes.quickConnectPage().toString(), 'https://media.example/jellyfin/web/#/quickconnect');
  });

  test('the conversion URL loses its key, whatever its case, and keeps the rest in order', () {
    final routes = JellyfinRoutes(Uri.parse('http://192.0.2.10:8096/jf'), JellyfinProduct.jellyfin, '12.4.0');
    final j12 = routes.conversion('/videos/f0-1/master.m3u8?DeviceId=d&MediaSourceId=m&ApiKey=secret&Tag=t');
    expect(j12.toString(), 'http://192.0.2.10:8096/jf/videos/f0-1/master.m3u8?DeviceId=d&MediaSourceId=m&Tag=t');
    final j10 = routes.conversion('/videos/f0-1/master.m3u8?api_key=secret&VideoCodec=h264');
    expect(j10.query, 'VideoCodec=h264');
    expect(withoutJellyfinKey(Uri.parse('http://x/a?api_key=1')).toString(), 'http://x/a');
  });

  test('ids are escaped in the paths', () {
    final routes = JellyfinRoutes(base, JellyfinProduct.emby, '4.10.2.0');
    expect(routes.file('a/b').path, '/Items/a%2Fb/File');
  });
}
