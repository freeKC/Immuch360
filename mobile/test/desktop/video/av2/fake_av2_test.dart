// The fake AV2 companion (test/desktop/video/fakes/fake_av2.dart) compiled by `dart compile exe`, whose path the test and
// windows jobs of the desktop workflow give in IMMUCH360_FAKE_AV2: it must speak the protocol of immuch360-av2
// (mobile/native/av2/README.md of lot AD2) for the playback of lot AD3 to be tested on it. Here the app's side is played
// by hand, the fixtures of lot AD0 cut by av2_stream.dart: the index, the units of each "need G U", the y4m read over
// HTTP whole and from the middle of a picture after a seek, the refusals, the end when the standard input closes, and
// the modes that hang and that fail.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/av2_stream.dart';
import 'package:immich_mobile/domain/services/y4m_layout.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_av2.dart';

final _fake = Platform.environment['IMMUCH360_FAKE_AV2'];
const _token = 'test-token-0123456789';

Uint8List _fixture(String name) => File(p.join('test/fixtures/av2', name)).readAsBytesSync();

Future<Av2Index> _index(Uint8List bytes) => indexAv2Stream(
  (offset, length) async => Uint8List.sublistView(bytes, offset, math.min(bytes.length, offset + length)),
  bytes.length,
);

/// The fake started with serve, and the app's side: its lines, and the units it feeds at each "need G U"
class _Companion {
  _Companion._(this.process, this.file, this.index, this.layout) {
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine);
    process.stderr.transform(utf8.decoder).listen(errors.write);
    // A companion that stops (fail, no-socket) leaves the last records unread
    unawaited(process.stdin.done.catchError((Object _) {}));
  }

  static Future<_Companion> start(
    String name, {
    int bits = 8,
    Map<String, String> environment = const {},
    bool feed = true,
    int? frames,
  }) async {
    final file = _fixture(name);
    final index = await _index(file);
    final layout = Y4mLayout(
      width: index.head.width ?? 256,
      height: index.head.height ?? 144,
      bits: bits,
      fpsNumerator: index.frameRate.numerator,
      fpsDenominator: index.frameRate.denominator,
      frames: frames ?? index.frameCount,
    );
    final process = await Process.start(_fake!, [
      'serve',
      '--token',
      _token,
      '--width',
      '${layout.width}',
      '--height',
      '${layout.height}',
      '--bits',
      '$bits',
      '--fps',
      '${layout.fpsNumerator}/${layout.fpsDenominator}',
      '--frames',
      '${layout.frames}',
      '--frame-bytes',
      '${layout.frameBytes}',
    ], environment: environment);
    final companion = _Companion._(process, file, index, layout);
    companion.feeds = feed;
    if (feed) {
      process.stdin.add(fakeAv2IndexRecord(index.accessPoints));
      await process.stdin.flush();
    }
    return companion;
  }

  final Process process;
  final Uint8List file;
  final Av2Index index;
  final Y4mLayout layout;
  final lines = <String>[];
  final errors = StringBuffer();
  final needs = <(int, int)>[];
  var feeds = true;
  final _waiters = <(bool Function(String), Completer<String>)>[];

  int? port;

  void _onLine(String line) {
    lines.add(line);
    if (line.startsWith('listening ')) {
      port = int.parse(line.split(' ')[1]);
    }
    final need = RegExp(r'^need (\d+) (\d+)$').firstMatch(line);
    if (need != null && feeds) {
      final generation = int.parse(need.group(1)!);
      final unit = int.parse(need.group(2)!);
      needs.add((generation, unit));
      // The units from U on, then the record of length 0 after the last one
      for (final next in index.units.skip(unit)) {
        process.stdin.add(fakeAv2Record(generation, next.index, file.sublist(next.offset, next.offset + next.length)));
      }
      process.stdin.add(fakeAv2Record(generation, index.frameCount, const []));
    }
    for (final (test, completer) in [..._waiters]) {
      if (!completer.isCompleted && test(line)) {
        completer.complete(line);
        _waiters.removeWhere((waiter) => identical(waiter.$2, completer));
      }
    }
  }

  /// The first line, already written or to come, that [test] takes
  Future<String> line(bool Function(String) test, {Duration timeout = const Duration(seconds: 10)}) {
    for (final line in lines) {
      if (test(line)) {
        return Future.value(line);
      }
    }
    final completer = Completer<String>();
    _waiters.add((test, completer));
    return completer.future.timeout(timeout);
  }

  Future<void> listening() => line((line) => line.startsWith('listening '));

  Uri get uri => Uri.parse('http://127.0.0.1:$port/$_token/video.y4m');

  /// The bytes [start] to [end] of the y4m (to its end when null), as the player asks for them
  Future<(int, Uint8List)> get({int? start, int? end, Uri? at, String method = 'GET'}) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, at ?? uri);
      if (start != null) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${end ?? ''}');
      }
      final response = await request.close();
      final body = await response.fold<BytesBuilder>(BytesBuilder(), (builder, chunk) => builder..add(chunk));
      return (response.statusCode, body.toBytes());
    } finally {
      client.close(force: true);
    }
  }

  /// The record of picture [k] the y4m should hold: "FRAME\n" and the pattern
  Uint8List record(int k) => Uint8List.fromList([...ascii.encode(y4mFrameMarker), ...fakeAv2Picture(layout, k)]);

  Future<int> stop() async {
    await process.stdin.close();
    return process.exitCode.timeout(const Duration(seconds: 5));
  }
}

void main() {
  group(
    'the fake AV2 companion',
    _tests,
    skip: _fake == null ? 'no compiled fake AV2 companion (IMMUCH360_FAKE_AV2)' : false,
  );
}

void _tests() {
  final started = <_Companion>[];

  Future<_Companion> start(
    String name, {
    int bits = 8,
    Map<String, String> environment = const {},
    bool feed = true,
    int? frames,
  }) async {
    final companion = await _Companion.start(name, bits: bits, environment: environment, feed: feed, frames: frames);
    started.add(companion);
    return companion;
  }

  tearDown(() async {
    for (final companion in started) {
      companion.process.kill(ProcessSignal.sigkill);
    }
    started.clear();
  });

  test('says its protocol and its processor level, as the real one', () async {
    final run = await Process.run(_fake!, ['--version'], environment: {'IMMUCH360_FAKE_AV2_SIMD': 'avx512'});

    expect(run.exitCode, 0);
    expect(LineSplitter.split(run.stdout as String), [
      'immuch360-av2 protocol 1, source fake',
      'dav2d fake (fake)',
      'simd avx512, uses avx512',
    ]);
    final help = await Process.run(_fake!, ['--help']);
    expect(help.exitCode, 0);
    expect(help.stdout, contains('immuch360-av2 serve --token TOKEN'));
    expect((await Process.run(_fake!, ['bogus'])).exitCode, 2);
  });

  test('probes a file or the standard input: AV2 in IVF or OBUs, AV1 refused with exit 3', () async {
    final ivf = await Process.run(
      _fake!,
      ['probe', 'test/fixtures/av2/av2-256x144-10bit.ivf'],
      environment: {'IMMUCH360_FAKE_AV2_BITS': '10'},
    );
    expect(ivf.exitCode, 0, reason: '${ivf.stderr}');
    final probe = jsonDecode(ivf.stdout as String) as Map<String, Object?>;
    expect(probe['container'], 'ivf');
    expect(probe['fourcc'], 'AV02');
    expect(probe['ivf'], {'width': 256, 'height': 144, 'rate': 30, 'scale': 1, 'frames': 12});
    expect(probe['format'], '4:2:0 10-bit');
    expect(probe['playable'], isTrue);
    expect(probe['refusal'], isNull);
    expect(probe['y4m'], {'colorspace': '420p10', 'frame_bytes': 110592});

    final process = await Process.start(_fake!, ['probe', '-']);
    process.stdin.add(_fixture('av2-256x144-8bit.obu'));
    await process.stdin.close();
    final out = await process.stdout.transform(utf8.decoder).join();
    expect(await process.exitCode, 0);
    final obu = jsonDecode(out) as Map<String, Object?>;
    expect((obu['container'], obu['fourcc'], obu['ivf']), ('obu', 'OBU', null));
    expect(obu['y4m'], {'colorspace': '420', 'frame_bytes': 55296});

    final av1 = await Process.run(_fake!, ['probe', 'test/fixtures/av2/av1-256x144-8bit.ivf']);
    expect(av1.exitCode, 3);
    expect(jsonDecode(av1.stdout as String), {'error': 'an IVF of AV1, not AV2'});
    final twelve = await Process.run(
      _fake!,
      ['probe', 'test/fixtures/av2/av2-256x144-8bit.ivf'],
      environment: {'IMMUCH360_FAKE_AV2_BITS': '12'},
    );
    expect((jsonDecode(twelve.stdout as String) as Map)['refusal'], '4:2:0 12-bit');
  });

  test('refuses bad arguments with exit 2, as the real one', () async {
    for (final arguments in [
      [
        'serve',
        '--token',
        'short',
        '--width',
        '256',
        '--height',
        '144',
        '--bits',
        '8',
        '--fps',
        '30/1',
        '--frames',
        '1',
      ],
      [
        'serve',
        '--token',
        _token,
        '--width',
        '256',
        '--height',
        '144',
        '--bits',
        '12',
        '--fps',
        '30/1',
        '--frames',
        '1',
      ],
      ['serve', '--token', _token, '--width', '256', '--height', '144', '--bits', '8', '--fps', '30', '--frames', '1'],
      ['serve', '--token', _token, '--width', '256', '--height', '144', '--bits', '8', '--fps', '30/1'],
      // A picture of 256x144 in 8 bits takes 55 296 bytes
      [
        'serve',
        '--token',
        _token,
        '--width',
        '256',
        '--height',
        '144',
        '--bits',
        '8',
        '--fps',
        '30/1',
        '--frames',
        '1',
        '--frame-bytes',
        '1000',
      ],
    ]) {
      final run = await Process.run(_fake!, arguments);
      expect(run.exitCode, 2, reason: '$arguments');
      expect(run.stderr, contains('immuch360-av2: '), reason: '$arguments');
    }
  });

  test('serves the whole y4m of a fixture: our header, then each picture of the pattern in its order', () async {
    final companion = await start('av2-256x144-8bit.ivf');
    await companion.listening();
    final layout = companion.layout;

    expect(
      companion.lines.first,
      'listening ${companion.port} address=127.0.0.1 length=${layout.length} header=${layout.headerLength} '
      'frame=55296 frames=12',
    );
    final (status, body) = await companion.get();

    expect(status, 200);
    expect(body, hasLength(layout.length));
    expect(
      ascii.decode(body.sublist(0, layout.headerLength)),
      'YUV4MPEG2 W256 H144 F30:1 Ip A1:1 C420 XCOLORRANGE=LIMITED\n',
    );
    for (var k = 0; k < 12; k++) {
      final record = body.sublist(layout.offsetOf(k), layout.offsetOf(k) + layout.recordBytes);
      expect(record, companion.record(k), reason: 'picture $k');
      expect(fakeAv2FrameOf(record.sublist(6), 8), k);
    }
    expect(companion.needs, [(1, 0)]);
    await companion.line((line) => line.startsWith('request bytes=0-${layout.length - 1} frame=0'));
    await companion.line(
      (line) => RegExp(r'^stat decoded=12 served=12 fps=[\d.]+ simd=avx2 gen=1 frame=12').hasMatch(line),
    );
    expect(await companion.stop(), 0);
    await companion.line((line) => line == 'exit input-closed');
  });

  test('a seek starts again at the access point before the picture, from the middle of it', () async {
    final companion = await start('av2-256x144-10bit.obu', bits: 10);
    await companion.listening();
    final layout = companion.layout;

    // Pictures 0 to 3 first, as a player that starts
    final (status, head) = await companion.get(start: 0, end: layout.offsetOf(4) - 1);
    expect(status, 206);
    expect(head.sublist(layout.offsetOf(3)), companion.record(3));
    // Then from the middle of picture 8: the decoder goes back to unit 6, drops 6 and 7, serves from the offset asked
    final from = layout.offsetOf(8) + 1000;
    final (seekStatus, tail) = await companion.get(start: from);
    expect(seekStatus, 206);
    expect(tail, hasLength(layout.length - from));
    expect(tail.sublist(0, layout.recordBytes - 1000), companion.record(8).sublist(1000));
    expect(fakeAv2FrameOf(tail.sublist(layout.recordBytes - 1000 + 6), 10), 9);
    await companion.line((line) => line == 'request bytes=$from-${layout.length - 1} frame=8');
    expect(companion.needs, [(1, 0), (2, 6)]);
    // Back to picture 2: before the decoder's position, so unit 0 again
    final (_, back) = await companion.get(start: layout.offsetOf(2), end: layout.offsetOf(3) - 1);
    expect(back, companion.record(2));
    expect(companion.needs.last, (3, 0));
    // A HEAD tells the length without decoding
    final (headStatus, nothing) = await companion.get(method: 'HEAD');
    expect(headStatus, 200);
    expect(nothing, isEmpty);
    expect(await companion.stop(), 0);
  });

  test('a new request ends the one being served; the records of an older generation are dropped', () async {
    // 5 pictures a second: the first request is still at its first pictures when the second one comes
    final companion = await start('av2-256x144-8bit.ivf', environment: {'IMMUCH360_FAKE_AV2_FPS': '5'});
    await companion.listening();
    final layout = companion.layout;
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final first = await (await client.getUrl(companion.uri)).close();
    final cut = first.fold<int>(0, (sum, chunk) => sum + chunk.length).catchError((Object _) => -1);
    await companion.line((line) => line.startsWith('request bytes=0-'));
    final (status, body) = await companion.get(start: layout.offsetOf(10));

    expect(status, 206);
    expect(body.sublist(0, layout.recordBytes), companion.record(10));
    expect(await cut, lessThan(layout.length));
    expect(companion.needs, [(1, 0), (2, 6)]);
    expect(await companion.stop(), 0);
  });

  test('refuses another token, another path, another method and a range past the end', () async {
    final companion = await start('av2-256x144-8bit.ivf');
    await companion.listening();
    final layout = companion.layout;

    expect(
      (await companion.get(at: Uri.parse('http://127.0.0.1:${companion.port}/other-token-0123456789/video.y4m'))).$1,
      403,
    );
    await companion.line((line) => line == 'refused token');
    expect((await companion.get(at: Uri.parse('http://127.0.0.1:${companion.port}/$_token/other.y4m'))).$1, 404);
    await companion.line((line) => line == 'refused path');
    expect((await companion.get(method: 'POST')).$1, 405);
    await companion.line((line) => line == 'refused method');
    expect((await companion.get(start: layout.length)).$1, 416);
    await companion.line((line) => line == 'refused range');
    expect(await companion.stop(), 0);
  });

  test('ends within a second when the standard input closes, even while it serves', () async {
    final companion = await start('av2-256x144-8bit.ivf', feed: false);
    await companion.listening();
    unawaited(companion.get().catchError((Object _) => (0, Uint8List(0))));
    final watch = Stopwatch()..start();

    expect(await companion.stop(), 0);
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    await companion.line((line) => line == 'exit input-closed');
  });

  test('silent: the listening line, then nothing, as a companion that hangs', () async {
    final companion = await start('av2-256x144-8bit.ivf', environment: {'IMMUCH360_FAKE_AV2_MODE': 'silent'});
    await companion.listening();
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    expect(companion.lines, hasLength(1));
    expect(await companion.stop(), 0);
  });

  test('play: a stat line every half second with the speed asked', () async {
    final companion = await start('av2-256x144-8bit.ivf', environment: {'IMMUCH360_FAKE_AV2_FPS': '30'});
    await companion.listening();
    await companion.get();
    final stat = await companion.line((line) => line.startsWith('stat decoded=12 '));
    final fps = double.parse(RegExp(r'fps=([\d.]+)').firstMatch(stat)!.group(1)!);

    expect(fps, inInclusiveRange(10, 31));
    expect(await companion.stop(), 0);
  });

  test('fail: the error of the decoder at the unit asked, exit 3; no socket: exit 4', () async {
    final companion = await start(
      'av2-256x144-8bit-damaged.ivf',
      environment: {'IMMUCH360_FAKE_AV2_MODE': 'fail', 'IMMUCH360_FAKE_AV2_FAIL_AT': '1'},
    );
    await companion.listening();
    unawaited(companion.get().catchError((Object _) => (0, Uint8List(0))));

    expect(await companion.process.exitCode.timeout(const Duration(seconds: 10)), 3);
    await companion.line((line) => line == 'error decode dav2d error -22 at picture 1');
    final noSocket = await start(
      'av2-256x144-8bit.ivf',
      environment: {'IMMUCH360_FAKE_AV2_MODE': 'no-socket'},
      feed: false,
    );
    expect(await noSocket.process.exitCode.timeout(const Duration(seconds: 10)), 4);
    await noSocket.line((line) => line == 'error network no socket on 127.0.0.1');
  });

  test('stops with exit 5 on a record that is not the protocol', () async {
    final companion = await start('av2-256x144-8bit.ivf', feed: false);
    await companion.listening();
    companion.process.stdin.add(Uint8List(16));
    await companion.process.stdin.flush();

    expect(await companion.process.exitCode.timeout(const Duration(seconds: 10)), 5);
    await companion.line((line) => line == 'error protocol a record without its AV2R mark');
  });
}
