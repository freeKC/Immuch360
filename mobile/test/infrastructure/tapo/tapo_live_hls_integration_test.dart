// The live playlist of the iPhone and iPad live view against a real RTSP server, skipped unless IMMUCH_NET_TESTS=1 and
// IMMUCH_LIVE_RTSP_HOST are set: a mediamtx fed by ffmpeg as a camera would be (H.264 without B frames, G.711), or a
// real Tapo camera on the same network. The variables come from the shell, never from a file read here:
//
//   IMMUCH_LIVE_RTSP_HOST, IMMUCH_LIVE_RTSP_PORT (554), IMMUCH_LIVE_RTSP_PATH (/stream2)
//   IMMUCH_LIVE_RTSP_USER, IMMUCH_LIVE_RTSP_PASSWORD   the camera account
//   IMMUCH_FFMPEG, IMMUCH_FFPROBE                      the paths of ffmpeg and ffprobe (the decode checks)
//   IMMUCH_LIVE_SECONDS (20)                           how long the player reads the playlist
//   IMMUCH_LIVE_TONE (none)                            the frequency of a test tone the sound must carry (440)
//   IMMUCH_LIVE_CUT_COMMAND (none)                     a shell command that cuts the stream (a server restart)
//
// The test reads the playlist as AVPlayer would, through the real media bridge, keeps every segment, then has ffmpeg
// decode the whole with -xerror and ffprobe tell the tracks and their start times. Nothing is printed but counts,
// times and codec names: never the account, never the address of the playlist.
//
//   IMMUCH_NET_TESTS=1 IMMUCH_LIVE_RTSP_HOST=127.0.0.1 IMMUCH_LIVE_RTSP_PORT=8554 ... \
//     mise exec -- flutter test test/infrastructure/tapo/tapo_live_hls_integration_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_live_hls.dart';

void main() {
  final env = Platform.environment;
  final host = env['IMMUCH_LIVE_RTSP_HOST'];
  final enabled = env['IMMUCH_NET_TESTS'] == '1' && host != null && host.isNotEmpty;
  final skip = enabled ? null : 'IMMUCH_NET_TESTS=1 and IMMUCH_LIVE_RTSP_HOST are not set';
  final port = int.tryParse(env['IMMUCH_LIVE_RTSP_PORT'] ?? '') ?? 554;
  final path = env['IMMUCH_LIVE_RTSP_PATH'] ?? '/stream2';
  final user = env['IMMUCH_LIVE_RTSP_USER'] ?? '';
  final password = env['IMMUCH_LIVE_RTSP_PASSWORD'] ?? '';
  final ffmpeg = env['IMMUCH_FFMPEG'];
  final ffprobe = env['IMMUCH_FFPROBE'];
  final seconds = int.tryParse(env['IMMUCH_LIVE_SECONDS'] ?? '') ?? 20;
  final tone = double.tryParse(env['IMMUCH_LIVE_TONE'] ?? '');
  final cutCommand = env['IMMUCH_LIVE_CUT_COMMAND'];

  late LocalMediaBridge bridge;
  late Directory folder;

  setUp(() async {
    bridge = LocalMediaBridge();
    folder = await Directory.systemTemp.createTemp('immuch360-live-hls');
  });

  tearDown(() async {
    await bridge.stop();
    await folder.delete(recursive: true);
  });

  TapoLiveHls session() =>
      TapoLiveHls(bridge: bridge, host: host!, port: port, path: path, user: user, password: password);

  Future<Uint8List> get(HttpClient client, Uri url) async {
    final response = await (await client.getUrl(url)).close();
    final body = BytesBuilder(copy: false);
    await response.forEach(body.add);
    expect(response.statusCode, HttpStatus.ok, reason: url.pathSegments.last);
    return body.takeBytes();
  }

  test(
    'a player reads the live playlist, and ffmpeg decodes it whole',
    () async {
      final clock = Stopwatch()..start();
      final live = session();
      addTearDown(live.stop);
      final url = await live.start();
      final firstSegment = clock.elapsedMilliseconds;
      final client = HttpClient();
      addTearDown(client.close);

      // As AVPlayer does: the playlist at each target duration, each new segment once, its init segment
      final names = <String>[];
      final durations = <String>[];
      final maps = <String>{};
      var mediaSequenceSeen = -1;
      final until = DateTime.now().add(Duration(seconds: seconds));
      while (DateTime.now().isBefore(until)) {
        final playlist = utf8.decode(await get(client, url));
        final lines = const LineSplitter().convert(playlist);
        expect(lines.first, '#EXTM3U');
        final sequence = int.parse(lines.firstWhere((line) => line.startsWith('#EXT-X-MEDIA-SEQUENCE:')).substring(22));
        expect(sequence, greaterThanOrEqualTo(mediaSequenceSeen), reason: 'the window only slides forward');
        mediaSequenceSeen = sequence;
        String? extinf;
        for (final line in lines) {
          final map = RegExp(r'^#EXT-X-MAP:URI="(.+)"$').firstMatch(line);
          if (map != null && maps.add(map.group(1)!)) {
            await File('${folder.path}/${map.group(1)}').writeAsBytes(await get(client, url.resolve(map.group(1)!)));
          }
          if (line.startsWith('#EXTINF:')) {
            extinf = line;
          } else if (line.endsWith('.m4s') && !names.contains(line)) {
            await File('${folder.path}/$line').writeAsBytes(await get(client, url.resolve(line)));
            names.add(line);
            durations.add(extinf!);
          }
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      await live.stop();
      expect(names, isNotEmpty);
      // The segments of a continuous read follow each other
      final numbers = [for (final name in names) int.parse(RegExp(r'\d+').firstMatch(name)!.group(0)!)];
      for (var i = 1; i < numbers.length; i++) {
        expect(numbers[i], numbers[i - 1] + 1, reason: 'no segment missed');
      }
      final total = durations.fold<double>(0, (sum, line) => sum + double.parse(line.substring(8, line.length - 1)));
      // ignore: avoid_print
      print(
        'first segment after $firstSegment ms; ${names.length} segments, ${total.toStringAsFixed(1)} s; '
        'sound ${live.hasAudio}',
      );

      // The playlist as a recording, for ffmpeg
      final all = StringBuffer('#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:0\n');
      all.write('#EXT-X-MAP:URI="${maps.first}"\n');
      for (var i = 0; i < names.length; i++) {
        all.write('${durations[i]}\n${names[i]}\n');
      }
      all.write('#EXT-X-ENDLIST\n');
      final playlistFile = File('${folder.path}/all.m3u8')..writeAsStringSync(all.toString());

      if (ffprobe != null && ffprobe.isNotEmpty) {
        final probe = await Process.run(ffprobe, [
          '-v',
          'error',
          '-show_entries',
          'stream=codec_type,codec_name,width,height,sample_rate,start_time',
          '-of',
          'json',
          playlistFile.path,
        ]);
        expect(probe.exitCode, 0, reason: '${probe.stderr}');
        final streams = [for (final stream in (jsonDecode('${probe.stdout}') as Map)['streams'] as List) stream as Map];
        final video = streams.firstWhere((stream) => stream['codec_type'] == 'video');
        expect(video['codec_name'], 'h264');
        // ignore: avoid_print
        print('video ${video['width']}x${video['height']}');
        if (live.hasAudio) {
          final audio = streams.firstWhere((stream) => stream['codec_type'] == 'audio');
          expect(audio['codec_name'], 'alac');
          final offset = double.parse('${audio['start_time']}') - double.parse('${video['start_time']}');
          // ignore: avoid_print
          print('sound ${audio['sample_rate']} Hz, starts ${(offset * 1000).round()} ms after the picture');
          expect(offset.abs(), lessThan(0.1), reason: 'the sound placed against the picture');
        }
      }

      if (ffmpeg != null && ffmpeg.isNotEmpty) {
        final decode = await Process.run(ffmpeg, [
          '-v',
          'error',
          '-xerror',
          '-i',
          playlistFile.path,
          '-f',
          'null',
          '-',
        ]);
        expect(decode.exitCode, 0, reason: '${decode.stderr}');
        expect('${decode.stderr}'.trim(), isEmpty);
        if (live.hasAudio && tone != null) {
          final pcm = await Process.run(ffmpeg, [
            '-v',
            'error',
            '-i',
            playlistFile.path,
            '-map',
            '0:a',
            '-f',
            's16le',
            '-ac',
            '1',
            '-',
          ], stdoutEncoding: null);
          expect(pcm.exitCode, 0, reason: '${pcm.stderr}');
          final bytes = pcm.stdout as List<int>;
          final samples = Int16List.view(Uint8List.fromList(bytes).buffer);
          final found = _dominantFrequency(samples, 8000);
          // ignore: avoid_print
          print('sound decoded: ${(samples.length / 8000).toStringAsFixed(1)} s, ${found.toStringAsFixed(1)} Hz');
          expect((found - tone).abs(), lessThan(5));
        }
      }
    },
    skip: skip,
    timeout: Timeout(Duration(seconds: seconds + 90)),
  );

  test(
    'the end of the stream when the server cuts it',
    () async {
      final live = session();
      addTearDown(live.stop);
      await live.start();
      final cut = await Process.run('sh', ['-c', cutCommand!]);
      expect(cut.exitCode, 0, reason: 'the cut command');
      final reason = await live.ended.timeout(const Duration(seconds: 30));
      expect(reason, tapoLiveStreamLost);
    },
    skip: skip ?? (cutCommand == null ? 'IMMUCH_LIVE_CUT_COMMAND is not set' : null),
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

/// The frequency with the most energy in one second of [samples] at [rate] (the middle one), by a scan of 1 Hz steps
double _dominantFrequency(Int16List samples, int rate) {
  final start = max(0, samples.length ~/ 2 - rate ~/ 2);
  final count = min(rate, samples.length - start);
  var best = 0.0;
  var bestPower = -1.0;
  for (var frequency = 100.0; frequency <= 2000; frequency += 1) {
    var real = 0.0;
    var imaginary = 0.0;
    for (var i = 0; i < count; i++) {
      final angle = 2 * pi * frequency * i / rate;
      real += samples[start + i] * cos(angle);
      imaginary += samples[start + i] * sin(angle);
    }
    final power = real * real + imaginary * imaginary;
    if (power > bestPower) {
      bestPower = power;
      best = frequency;
    }
  }
  return best;
}
