// The Tapo live view of Immuch360 Desktop on a real RTSP stream (plan 2.4, design 5.5): the camera page's live tile
// plays it through libmpv, RTP inside the RTSP connection over TCP, with the camera account answered by Digest, and
// shows its first frame with the Live badge; the sound and the HD stream; a stream the server cuts comes back by
// itself; a refused account fails once and says so; no log record and no file of the temporary folder holds the
// account or the address. It opens a window, so it runs on the owner's PC in a slot he gave.
//
// No camera is needed: a local RTSP server serves synthetic streams shaped like a camera's (H.264 and G.711 A-law
// 8 kHz, the main stream at /stream1 and the sub stream at /stream2), for example mediamtx in WSL with Digest
// authentication, reached from Windows on 127.0.0.1. From WSL, through the wrapper of the desktop work (the variables
// pass by name, their values are never printed):
//   win_flutter.sh --env-file <file with the variables> --log live \
//     test integration_test/desktop_camera_live_test.dart -d windows
//
// Variables:
//   IMMUCH360_LIVE_HOST, IMMUCH360_LIVE_USER, IMMUCH360_LIVE_PASSWORD   the server and its account (skipped without)
//   IMMUCH360_LIVE_PORT     the RTSP port (default 554)
//   IMMUCH360_LIVE_CUT      a file whose creation makes the server cut the sub stream for a few seconds (a script
//                           of the server watches it, through \\wsl.localhost for a server in WSL); the test creates
//                           it once live, and waits for the loss and for the stream to come back by itself
//   IMMUCH360_LIVE_SHOT     a folder for a PNG of the tile once live (synthetic streams only, never a camera's)
//
// What it prints, on lines starting with "LIVE ": the times to the first frame, the decoder, the codecs and the sizes
// of both streams, the frames dropped, what the Flutter texture shows (distinct colours, change between two
// captures), the loss and the return; never the address, the host or the account.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/video/camera_live_view.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_live_view.widget.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

final _tile = GlobalKey();
const _badge = Key('camera_live_badge');
const _state = Key('camera_live_state');

void _report(String what, Map<String, Object?> values) {
  // ignore: avoid_print
  print('LIVE ${jsonEncode({'case': what, ...values})}');
}

Future<void> _pumpTile(
  WidgetTester tester, {
  required String host,
  required int port,
  required String user,
  required String password,
  bool hd = false,
}) async {
  await tester.pumpWidget(
    EasyLocalization(
      supportedLocales: locales.values.toList(),
      path: translationsPath,
      startLocale: locales.values.first,
      fallbackLocale: locales.values.first,
      saveLocale: false,
      useFallbackTranslations: true,
      assetLoader: const CodegenLoader(),
      child: Builder(
        builder: (context) => MaterialApp(
          debugShowCheckedModeBanner: false,
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: RepaintBoundary(
                key: _tile,
                child: SizedBox(
                  width: 960,
                  height: 540,
                  child: CameraLiveTile(
                    host: host,
                    port: port,
                    user: user,
                    password: password,
                    fullScreen: false,
                    preferHd: hd,
                    onFullScreen: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Pumps until [finder] finds something, and gives the time it took
Future<Duration> _waitFor(WidgetTester tester, Finder finder, Duration timeout) async {
  final watch = Stopwatch()..start();
  while (finder.evaluate().isEmpty) {
    if (watch.elapsed > timeout) {
      throw TimeoutException('waited ${timeout.inSeconds} s for $finder');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
  return watch.elapsed;
}

Future<void> _hold(WidgetTester tester, Duration duration) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < duration) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
}

Player _player(WidgetTester tester) => tester.widget<Video>(find.byType(Video)).controller.player;

Future<String?> _property(Player player, String name) async {
  try {
    return await (player.platform! as NativePlayer).getProperty(name);
  } catch (_) {
    return null;
  }
}

/// What the tile shows, read back from Flutter's layers: the texture of the video included
Future<({int colours, Uint8List rgba, int width, int height, Uint8List png})> _capture() async {
  final boundary = _tile.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  final colours = <int>{};
  // The middle of the picture, away from the badge and the buttons
  for (var y = image.height ~/ 4; y < image.height * 3 ~/ 4; y += 4) {
    for (var x = image.width ~/ 4; x < image.width * 3 ~/ 4; x += 4) {
      final i = (y * image.width + x) * 4;
      colours.add((rgba[i] >> 3) << 10 | (rgba[i + 1] >> 3) << 5 | rgba[i + 2] >> 3);
    }
  }
  final result = (colours: colours.length, rgba: rgba, width: image.width, height: image.height, png: png);
  image.dispose();
  return result;
}

/// The share of sampled pixels that changed between two captures
double _changed(Uint8List a, Uint8List b) {
  var changed = 0;
  var total = 0;
  for (var i = 0; i < a.length && i < b.length; i += 4 * 16) {
    total++;
    if ((a[i] - b[i]).abs() + (a[i + 1] - b[i + 1]).abs() + (a[i + 2] - b[i + 2]).abs() > 24) {
      changed++;
    }
  }
  return total == 0 ? 0 : changed / total;
}

/// Files of the temporary folder written in the last [since] that hold [needles]: media_kit's own open writes what
/// it plays to such a file for five seconds
List<String> _tempFilesHolding(List<String> needles, Duration since) {
  final found = <String>[];
  final after = DateTime.now().subtract(since);
  for (final entity in Directory.systemTemp.listSync(followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    try {
      final stat = entity.statSync();
      if (stat.modified.isBefore(after) || stat.size > 64 * 1024) {
        continue;
      }
      final text = latin1.decode(entity.readAsBytesSync());
      if (needles.any(text.contains)) {
        found.add(p.basename(entity.path));
      }
    } catch (_) {
      // A file of another program, locked or gone
    }
  }
  return found;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Frames as in the app: the engine draws the video texture as it comes, not only when the test pumps
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final environment = Platform.environment;
  final host = environment['IMMUCH360_LIVE_HOST'] ?? '';
  final port = int.tryParse(environment['IMMUCH360_LIVE_PORT'] ?? '') ?? 554;
  final user = environment['IMMUCH360_LIVE_USER'] ?? '';
  final password = environment['IMMUCH360_LIVE_PASSWORD'] ?? '';
  final cut = environment['IMMUCH360_LIVE_CUT'] ?? '';
  final shots = environment['IMMUCH360_LIVE_SHOT'];
  final skip = !CurrentPlatform.isDesktop
      ? 'the live view of the computers: run with -d windows'
      : host.isEmpty || user.isEmpty || password.isEmpty
      ? 'needs IMMUCH360_LIVE_HOST, IMMUCH360_LIVE_USER and IMMUCH360_LIVE_PASSWORD'
      : false;
  final records = <LogRecord>[];
  final secrets = [
    password,
    Uri.encodeComponent(password),
    cameraRtspUrlWithAccount('rtsp://$host:$port/stream2', user, password) ?? '',
    'rtsp://',
  ].where((secret) => secret.isNotEmpty).toList();

  setUpAll(() async {
    if (skip != false) {
      return;
    }
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(records.add);
    setUpDesktopVideo();
    expect(desktopVideoAvailable, isTrue, reason: 'libmpv did not load');
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('the sub stream plays with its first frame, the sound and the main stream', (tester) async {
    // media_kit's own open would leave the address in a file of the temporary folder for five seconds: looked for
    // four times a second from the open to the first frame
    final temp = <String>{};
    final scan = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => temp.addAll(_tempFilesHolding(secrets, const Duration(seconds: 30))),
    );
    await _pumpTile(tester, host: host, port: port, user: user, password: password);
    final Duration toLive;
    try {
      toLive = await _waitFor(tester, find.byKey(_badge), const Duration(seconds: 30));
    } finally {
      scan.cancel();
    }
    expect(temp, isEmpty, reason: 'a file of the temporary folder holds the address');
    // A few seconds of playing, then what plays
    await _hold(tester, const Duration(seconds: 4));
    final player = _player(tester);
    final first = await _capture();
    await _hold(tester, const Duration(seconds: 1));
    final second = await _capture();
    final decoded = await player.screenshot(format: 'image/png');
    final subWidth = player.state.width ?? 0;
    final sub = {
      'toLiveMs': toLive.inMilliseconds,
      'width': player.state.width,
      'height': player.state.height,
      'hwdec': await _property(player, 'hwdec-current'),
      'videoCodec': await _property(player, 'video-codec'),
      'audioCodec': await _property(player, 'audio-codec-name'),
      'transport': await _property(player, 'rtsp-transport'),
      'drops': await _property(player, 'frame-drop-count'),
      'decoderDrops': await _property(player, 'decoder-frame-drop-count'),
      'fps': await _property(player, 'estimated-vf-fps'),
      'cacheSeconds': await _property(player, 'demuxer-cache-duration'),
      'volume': await _property(player, 'volume'),
      'textureColours': first.colours,
      'textureChanged': _changed(first.rgba, second.rgba),
      'decodedPngBytes': decoded?.length,
      'tempFilesWithAddress': temp.length,
    };
    _report('sub stream', sub);
    if (shots != null && shots.isNotEmpty) {
      await File(p.join(shots, 'live-sd.png')).writeAsBytes(first.png);
    }
    expect(player.state.width, greaterThan(0));
    expect(decoded, isNotNull);
    expect(first.colours, greaterThan(16), reason: 'the texture shows a picture');
    expect(sub['volume'], startsWith('0'), reason: 'muted at first');

    await tester.tap(find.byKey(const Key('camera_live_sound')));
    await _hold(tester, const Duration(milliseconds: 500));
    final volume = await _property(_player(tester), 'volume');
    expect(volume, startsWith('100'));

    await tester.tap(find.byKey(const Key('camera_live_quality')));
    await _waitFor(tester, find.byKey(_state), const Duration(seconds: 5));
    final toMain = await _waitFor(tester, find.byKey(_badge), const Duration(seconds: 30));
    await _hold(tester, const Duration(seconds: 3));
    final main = _player(tester);
    final third = await _capture();
    _report('main stream', {
      'toLiveMs': toMain.inMilliseconds,
      'width': main.state.width,
      'height': main.state.height,
      'hwdec': await _property(main, 'hwdec-current'),
      'drops': await _property(main, 'frame-drop-count'),
      'cacheSeconds': await _property(main, 'demuxer-cache-duration'),
      'volume': await _property(main, 'volume'),
      'textureColours': third.colours,
      'samePlayer': identical(main, player),
    });
    if (shots != null && shots.isNotEmpty) {
      await File(p.join(shots, 'live-hd.png')).writeAsBytes(third.png);
    }
    expect(main.state.width, greaterThan(subWidth));

    await tester.pumpWidget(const SizedBox());
    await _hold(tester, const Duration(seconds: 1));
    expect(desktopPlayerPool.activeCount(PlayerKind.live), 0, reason: 'the player is given back');
  }, skip: skip != false);

  testWidgets('a stream the server cuts comes back by itself', (tester) async {
    await _pumpTile(tester, host: host, port: port, user: user, password: password);
    await _waitFor(tester, find.byKey(_badge), const Duration(seconds: 30));
    await _hold(tester, const Duration(seconds: 2));
    await File(cut).writeAsString('cut');
    final lostAfter = await _waitFor(tester, find.byKey(_state), const Duration(seconds: 30));
    final lostText = tester.widget<Text>(find.byKey(_state)).data;
    final back = await _waitFor(tester, find.byKey(_badge), const Duration(seconds: 60));
    await _hold(tester, const Duration(seconds: 2));
    final shot = await _capture();
    _report('loss', {
      'lostAfterMs': lostAfter.inMilliseconds,
      'lostText': lostText,
      'backAfterMs': back.inMilliseconds,
      'textureColours': shot.colours,
    });
    expect(lostText, 'Connecting to the camera');
    await tester.pumpWidget(const SizedBox());
    await _hold(tester, const Duration(seconds: 1));
  }, skip: skip != false || cut.isEmpty);

  testWidgets('a refused account fails once and says so', (tester) async {
    await _pumpTile(tester, host: host, port: port, user: user, password: '${password}x');
    final failedAfter = await _waitFor(
      tester,
      find.textContaining('The live view did not start'),
      const Duration(seconds: 30),
    );
    final text = tester.widget<Text>(find.textContaining('The live view did not start')).data!;
    await _hold(tester, const Duration(seconds: 8));
    _report('refused', {
      'failedAfterMs': failedAfter.inMilliseconds,
      'text': text,
      'stillFailed': find.textContaining('The live view did not start').evaluate().isNotEmpty,
      'livePlayers': desktopPlayerPool.activeCount(PlayerKind.live),
    });
    expect(text, contains('401'));
    expect(find.textContaining('The live view did not start'), findsOneWidget);
    expect(desktopPlayerPool.activeCount(PlayerKind.live), 0);
    await tester.pumpWidget(const SizedBox());
    await _hold(tester, const Duration(seconds: 1));
  }, skip: skip != false);

  testWidgets('no log record holds the account or the address', (tester) async {
    final text = records
        .map((record) => '${record.loggerName} ${record.level} ${record.message} ${record.error ?? ''}')
        .join('\n');
    final found = [
      for (final secret in [...secrets, user])
        if (text.contains(secret)) secrets.indexOf(secret),
    ];
    _report('log', {
      'records': records.length,
      'player': records.where((record) => record.loggerName == 'DesktopPlayer').length,
      'live': records.where((record) => record.loggerName == 'DesktopCameraLive').length,
      'secretsFound': found.length,
    });
    expect(found, isEmpty);
    // The lines of the player and the live view, for the report, once known to hold neither
    for (final record in records.where((r) => r.loggerName == 'DesktopPlayer' || r.loggerName == 'DesktopCameraLive')) {
      // ignore: avoid_print
      print('LOG ${record.level} ${record.loggerName}: ${record.message}');
    }
  }, skip: skip != false);
}
