// Against a real camera, skipped unless IMMUCH_NET_TESTS=1 and IMMUCH_TAPO_HOST are set. The variables come from the
// shell (the owner's secrets file is sourced there, never read here): IMMUCH_TAPO_HOST the address of the camera,
// IMMUCH_TAPO_USER and IMMUCH_TAPO_PASSWORD the camera account (live checks), IMMUCH_TAPO_CLOUD_PASSWORD the password of
// the TP-Link account (recording checks, skipped without it), IMMUCH_FFPROBE the path of ffprobe (optional).
//
// Read only, one login for the whole file, never a wrong password (each one counts towards a lockout; a typo costs one
// login, two attempts at most, as the refusal is remembered for the other checks), one media session at a time with a
// second between them. Nothing is printed but counts and booleans.
//
//   set -a; . <the secrets file, outside the repository>; set +a
//   IMMUCH_NET_TESTS=1 mise exec -- flutter test test/infrastructure/tapo/tapo_camera_integration_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_probe.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_discovery.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_file_system.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_https.dart';
import 'package:timezone/data/latest.dart';

/// A synthetic id for the cache folder of the test
const _sourceId = '0000000000000001';

void main() {
  final environment = Platform.environment;
  final host = environment['IMMUCH_TAPO_HOST'] ?? '';
  final gated = environment['IMMUCH_NET_TESTS'] == '1' && host.isNotEmpty;
  final cloudPassword = environment['IMMUCH_TAPO_CLOUD_PASSWORD'] ?? '';
  final cameraUser = environment['IMMUCH_TAPO_USER'] ?? '';
  final cameraPassword = environment['IMMUCH_TAPO_PASSWORD'] ?? '';
  final skipAll = gated ? false : 'needs IMMUCH_NET_TESTS=1 and IMMUCH_TAPO_HOST';
  final skipRecordings = gated && cloudPassword.isNotEmpty ? false : 'needs IMMUCH_TAPO_CLOUD_PASSWORD';
  final skipLive = gated && cameraUser.isNotEmpty && cameraPassword.isNotEmpty
      ? false
      : 'needs IMMUCH_TAPO_USER and IMMUCH_TAPO_PASSWORD';

  late Directory cache;
  TapoFileSystem? fileSystem;
  List<String> days = const [];
  List<TapoClip> clips = const [];

  setUpAll(() async {
    initializeTimeZones();
    cache = await Directory.systemTemp.createTemp('immuch360-tapo-camera');
    if (skipRecordings == false) {
      // The certificate pinned first, as the Save of the camera form does (nothing is sent to read it): only the test
      // of the form logs in to a camera without a pin
      final certificate = await readTapoCertificate(host);
      // One login for the whole file, shared by every check
      fileSystem = await TapoFileSystem.openWith(
        NetworkSource(
          id: _sourceId,
          type: NetworkSourceType.tapo,
          name: 'Camera',
          host: host,
          useTls: true,
          camera: TapoCameraInfo(certificateSha256: certificate),
        ),
        cloudPassword,
        cacheRoot: () async => cache,
      );
    }
  });

  tearDownAll(() async {
    await fileSystem?.close();
    if (cache.existsSync()) {
      await cache.delete(recursive: true);
    }
  });

  test('the TP-Link discovery finds the camera by unicast, with its model and MAC', () async {
    final done = Completer<void>();
    final found = <DiscoveredServer>[];
    final subscription = const TapoDiscoveryProbe()(
      DiscoveryRequest(hosts: [host], done: done.future),
    ).listen(found.add);
    await Future<void>.delayed(const Duration(seconds: 5));
    done.complete();
    await subscription.cancel();
    final camera = found.where((server) => server.host == host).firstOrNull;
    expect(camera, isNotNull, reason: 'no TDP answer from the camera');
    expect(camera!.displayName.length > 'Tapo '.length, isTrue);
    expect(RegExp(r'^[0-9a-f]{2}(-[0-9a-f]{2}){5}$').hasMatch(camera.discoveryId ?? ''), isTrue);
  }, skip: skipAll);

  test('logs in and reads the details, the card, the zone and the components', () async {
    final details = await fileSystem!.details();
    final card = await fileSystem!.cardStatus();
    expect(details.model, isNotEmpty);
    expect(details.mac, matches(RegExp(r'^[0-9a-f]{2}(-[0-9a-f]{2}){5}$')));
    expect(fileSystem!.info.protocol, isNotNull);
    expect(fileSystem!.info.passcode, isNotNull);
    expect(fileSystem!.info.certificateSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(card.state, isNot(TapoCardState.absent));
  }, skip: skipRecordings);

  test('lists the days and the clips of the newest one', () async {
    days = await fileSystem!.days();
    expect(days, isNotEmpty);
    clips = await fileSystem!.clips(days.first);
    expect(clips, isNotEmpty);
    expect(clips.every((clip) => clip.end.isAfter(clip.start)), isTrue);
  }, skip: skipRecordings);

  test('gets the picture of an event clip', () async {
    final event = clips.where((clip) => clip.kind != TapoClipKind.continuous).firstOrNull;
    if (event == null) {
      markTestSkipped('no event clip on the newest day');
      return;
    }
    final picture = await fileSystem!.thumbnail(event);
    expect(picture, isNotNull);
    expect(picture!.take(2), [0xff, 0xd8]);
    await Future<void>.delayed(const Duration(seconds: 1));
  }, skip: skipRecordings);

  test(
    'fetches the shortest clip of the day into a QuickTime file the app reads',
    () async {
      final shortest = ([...clips]..sort((a, b) => a.duration.compareTo(b.duration))).first;
      await fileSystem!.fetch(shortest);
      expect(fileSystem!.isFetched(shortest), isTrue);
      final probe = await probeSphericalMetadata(
        (offset, length) => fileSystem!.readRange(shortest.path, offset, length),
      );
      expect(probe.codec, anyOf('avc1', 'hvc1'));
      final ffprobe = environment['IMMUCH_FFPROBE'];
      if (ffprobe != null && ffprobe.isNotEmpty) {
        final file = Directory('${cache.path}/tapo/$_sourceId/clips').listSync().whereType<File>().first;
        final result = await Process.run(ffprobe, [
          '-v',
          'error',
          '-show_entries',
          'stream=codec_name',
          '-of',
          'json',
          file.path,
        ]);
        expect(result.exitCode, 0);
        final streams = (jsonDecode('${result.stdout}') as Map)['streams'] as List;
        expect(streams, isNotEmpty);
      }
    },
    skip: skipRecordings,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  for (final path in [tapoRtspHdPath, tapoRtspSdPath]) {
    test('the camera account opens the RTSP stream $path', () async {
      final probe = await probeTapoRtsp(
        host,
        port: TapoCameraInfo.defaultRtspPort,
        path: path,
        user: cameraUser,
        password: cameraPassword,
      );
      expect(probe.video, isNotNull);
    }, skip: skipLive);
  }
}
