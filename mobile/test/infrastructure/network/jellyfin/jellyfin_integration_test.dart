// The Jellyfin client against real Jellyfin and Emby servers (the release 49 bench), skipped unless
// IMMUCH_NET_TESTS=1, IMMUCH_JELLYFIN_URLS (comma separated base URLs, http://host:port), IMMUCH_JELLYFIN_USER and
// IMMUCH_JELLYFIN_PASSWORD (a test user of every server) are set. IMMUCH_JELLYFIN_SHA256 (the media.sha256 file of the
// bench's media) adds the check of every byte read through the media bridge; IMMUCH_JELLYFIN_UDP (comma separated
// host:port of UDP 7359 answers) adds the discovery question. The test reads these variables only: the shell loads
// them from the bench, never from FreeKC's data.
//
// What it prints is counts, statuses, booleans and kinds: never the token, the password, an address or a title.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:immich_mobile/domain/models/flat_stereo.dart';
import 'package:immich_mobile/domain/models/jellyfin_server_info.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_client.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_file_system.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_routes.dart';

void _report(String line) => stdout.writeln('jellyfin: $line');

List<String> _list(String? value) =>
    (value ?? '').split(',').map((part) => part.trim()).where((part) => part.isNotEmpty).toList();

const _installId = '00000000000000000000000000049049';

void main() {
  final environment = Platform.environment;
  final urls = _list(environment['IMMUCH_JELLYFIN_URLS']);
  final user = environment['IMMUCH_JELLYFIN_USER'] ?? '';
  final password = environment['IMMUCH_JELLYFIN_PASSWORD'] ?? '';
  final sums = environment['IMMUCH_JELLYFIN_SHA256'] ?? '';
  final enabled = environment['IMMUCH_NET_TESTS'] == '1' && urls.isNotEmpty && user.isNotEmpty && password.isNotEmpty;
  final skip = enabled ? false : 'needs IMMUCH_NET_TESTS=1, IMMUCH_JELLYFIN_URLS, _USER and _PASSWORD';

  /// The sha256 of each file of the bench media, by base name
  final expected = <String, String>{};
  if (sums.isNotEmpty && File(sums).existsSync()) {
    for (final line in File(sums).readAsLinesSync()) {
      final space = line.indexOf('  ');
      if (space > 0) {
        expected[line.substring(space + 2).split('/').last] = line.substring(0, space);
      }
    }
  }

  for (final (index, url) in urls.indexed) {
    final label = 'server ${index + 1}';
    group(label, () {
      late JellyfinPublicInfo info;
      late JellyfinSignIn signedIn;
      late NetworkSource source;
      final base = Uri.parse(url);

      JellyfinClient clientOf(JellyfinProduct product, String? version, {String? token, String suffix = 'a'}) =>
          JellyfinClient(
            IOClient(HttpClient()),
            routes: JellyfinRoutes(base, product, version),
            deviceId: '$_installId-$suffix',
            token: token,
            appVersion: 'integration',
          );

      setUpAll(() async {
        if (!enabled) {
          return;
        }
        info = await clientOf(JellyfinProduct.jellyfin, null).publicInfo();
        final client = clientOf(info.product, info.version);
        signedIn = await client.signIn(user, password);
        _report('$label: ${info.product.name} ${info.version}, signed in');
        source = NetworkSource(
          id: 'integration${index}0000',
          type: NetworkSourceType.jellyfin,
          name: 'Integration',
          host: base.host,
          port: base.port,
          share: base.path,
          username: user,
          discoveryId: info.id,
          jellyfin: JellyfinServerInfo(
            serverId: info.id,
            userId: signedIn.userId,
            product: info.product.name,
            version: info.version,
          ),
        );
      });

      Future<JellyfinFileSystem> open() => JellyfinFileSystem.open(
        source,
        signedIn.accessToken,
        client: IOClient(HttpClient()),
        installId: _installId,
        appVersion: 'integration',
      );

      test('a wrong password is refused, another server id gets no token', () async {
        await expectLater(
          clientOf(info.product, info.version, suffix: 'w').signIn(user, '$password-wrong'),
          throwsA(isA<JellyfinException>().having((e) => e.failure, 'failure', JellyfinFailure.passwordRefused)),
        );
        final other = source.copyWith(
          jellyfin: JellyfinServerInfo(serverId: '0123456789abcdef0123456789abcdef', userId: signedIn.userId),
        );
        await expectLater(
          JellyfinFileSystem.open(other, signedIn.accessToken, client: IOClient(HttpClient()), installId: _installId),
          throwsA(isA<JellyfinException>().having((e) => e.failure, 'failure', JellyfinFailure.otherServer)),
        );
      }, skip: skip);

      test('every library listed, every byte read through the media bridge equals the source', () async {
        final fileSystem = await open();
        addTearDown(fileSystem.close);
        final bridge = LocalMediaBridge();
        addTearDown(bridge.stop);
        await bridge.start();
        bridge.register(fileSystem);
        final http = HttpClient();
        addTearDown(http.close);
        final files = <NetworkEntry>[];
        Future<void> walk(String path) async {
          for (final entry in await fileSystem.list(path)) {
            if (entry.isDirectory) {
              await walk(entry.path);
            } else {
              files.add(entry);
            }
          }
        }

        await walk('/');
        _report('$label: ${files.length} files, ranges ${fileSystem.supportsRanges}');
        expect(files, isNotEmpty);
        var checked = 0;
        for (final entry in files) {
          final request = await http.getUrl(bridge.urlFor(source.id, entry.path));
          final response = await request.close();
          expect(response.statusCode, 200);
          final digest = await sha256.bind(response).first;
          final known = expected[entry.name];
          if (known != null) {
            expect('$digest', known, reason: 'a file of the bench media');
            checked++;
          }
        }
        _report('$label: $checked files compared with the source, all equal');
        if (expected.isNotEmpty) {
          expect(checked, greaterThanOrEqualTo(8));
        }
        // A range through the bridge is answered from a range of the server
        final film = files.firstWhere((e) => e.isVideo && (e.size ?? 0) > 4096);
        final ranged = await http.getUrl(bridge.urlFor(source.id, film.path));
        ranged.headers.set('range', 'bytes=1000-1999');
        final answer = await ranged.close();
        expect(answer.statusCode, 206);
        expect((await answer.fold<List<int>>([], (a, b) => a..addAll(b))).length, 1000);
        expect(fileSystem.supportsRanges, isTrue);
      }, skip: skip);

      test('the 360 film is found 360 by the app probe, the HSBS film guessed half side by side', () async {
        final fileSystem = await open();
        addTearDown(fileSystem.close);
        final films = await fileSystem.list((await fileSystem.list('/')).firstWhere((e) => e.name == 'Films').path);
        final sphere = films.firstWhere((e) => e.name.contains('360'));
        final probe = await probeSphericalMetadata(
          (offset, length) => fileSystem.readRange(sphere.path, offset, length),
        );
        expect(probe.hasSphericalMetadata, isTrue);
        final stereo = films.firstWhere((e) => e.name.toLowerCase().contains('hsbs'));
        expect(
          guessFlatStereoFormat(fileName: stereo.name, width: stereo.width, height: stereo.height, isVideo: true),
          FlatStereoFormat.halfSbs,
        );
        _report('$label: 360 found from the bytes, half side by side from the name');
      }, skip: skip);

      test('a token sent with another DeviceId still works', () async {
        final other = clientOf(info.product, info.version, token: signedIn.accessToken, suffix: 'other-device');
        expect((await other.me(signedIn.userId)).name, user);
      }, skip: skip);
    }, skip: skip);
  }
}
