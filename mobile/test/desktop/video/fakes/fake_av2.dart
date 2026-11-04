// A fake immuch360-av2, the AV2 companion of Immuch360 Desktop, compiled into a real program by `dart compile exe` (the
// test and windows jobs of the desktop workflow, or by hand) and given to the tests by IMMUCH360_FAKE_AV2, so that the
// playback of lot AD3 is tested against a real child process before the companion of lot AD2 is built, and without
// decoding anything. It takes the arguments, reads the records and writes the lines of the real one
// (mobile/native/av2/README.md of lot AD2): probe, serve, --version, --help; the index record, then the temporal units
// of each generation after a line "need G U", and a record of length 0 after the last unit; the lines listening, need,
// request, stat, refused, error and exit; the exit codes 0 to 5. It serves the same virtual y4m over HTTP on 127.0.0.1
// (y4m_layout.dart), one request at a time, a new one ending the one being served, with the restart at the access point
// before the picture asked and the pictures before it dropped. Its pictures are a test pattern, not decoded: unit k
// gives picture k, whose first four luma samples hold k (fakeAv2FrameOf), over a ramp that moves with k.
//
// serve takes its token from IMMUCH360_AV2_TOKEN when --token is left out, as the real one (the app gives it there).
// IMMUCH360_FAKE_AV2_MODE says what it does:
//   play       serves what it is fed (the default)
//   silent     writes its listening line, then nothing more and never decodes: a companion that hangs
//   fail       stops at unit IMMUCH360_FAKE_AV2_FAIL_AT (1 by default) with "error decode ...", exit 3, as on a
//              damaged file
//   no-socket  "error network no socket on 127.0.0.1", exit 4
// IMMUCH360_FAKE_AV2_FPS sets its decoding speed in pictures per second (240 by default), which the stat lines tell;
// --parent PID ends it when that process ends, watched on Linux only (the job object of the app does it on Windows);
// IMMUCH360_FAKE_AV2_SIMD the level they name (avx2). Its probe reads the head of the file as the app does
// (av2_stream.dart): an IVF gives its own size, a Section 5 stream IMMUCH360_FAKE_AV2_SIZE (256x144); the depth comes
// from IMMUCH360_FAKE_AV2_BITS (8), since nothing is decoded. It writes its process id to the file
// IMMUCH360_FAKE_AV2_PID names, when it does.
//
// Pure Dart, without Flutter: compiled outside of any test.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/av2_stream.dart';
import 'package:immich_mobile/domain/services/y4m_layout.dart';

/// The protocol of serve the fake speaks, as the first line of --version says
const fakeAv2Protocol = 1;

/// The variable of the environment that gives serve its token when --token is left out, as the app gives it
const fakeAv2TokenVariable = 'IMMUCH360_AV2_TOKEN';

/// "AV2R" read as a little endian 32-bit number: the mark of each record of the standard input
const fakeAv2RecordMagic = 0x52325641;

/// The unit number of the record of the index
const fakeAv2IndexUnit = 0xffffffff;

/// The samples of picture [frame] of the test pattern in [layout]: 4:2:0, one byte a sample in 8 bits, two little
/// endian in 10 bits; the first four luma samples hold [frame], low byte first
Uint8List fakeAv2Picture(Y4mLayout layout, int frame) {
  final wide = layout.bits > 8;
  final samples = Uint8List(layout.frameBytes);
  final data = ByteData.sublistView(samples);
  final max = wide ? 1023 : 255;
  var at = 0;
  void put(int value) {
    if (wide) {
      data.setUint16(at, value, Endian.little);
      at += 2;
    } else {
      samples[at++] = value;
    }
  }

  for (var y = 0; y < layout.height; y++) {
    for (var x = 0; x < layout.width; x++) {
      final index = y * layout.width + x;
      put(index < 4 ? (frame >> (8 * index)) & 0xff : (x + y + 7 * frame) & max);
    }
  }
  final chroma = ((layout.width + 1) ~/ 2) * ((layout.height + 1) ~/ 2);
  final u = ((128 + frame) & 0xff) << (wide ? 2 : 0);
  final v = ((64 + 3 * frame) & 0xff) << (wide ? 2 : 0);
  for (var i = 0; i < chroma; i++) {
    put(u);
  }
  for (var i = 0; i < chroma; i++) {
    put(v);
  }
  return samples;
}

/// The picture number the samples of a picture of the pattern hold ([fakeAv2Picture])
int fakeAv2FrameOf(List<int> samples, int bits) {
  var frame = 0;
  for (var i = 0; i < 4; i++) {
    frame |= samples[bits > 8 ? 2 * i : i] << (8 * i);
  }
  return frame;
}

/// The 16-byte header and the payload of a record of the standard input
Uint8List fakeAv2Record(int generation, int unit, List<int> payload) {
  final record = Uint8List(16 + payload.length);
  ByteData.sublistView(record)
    ..setUint32(0, fakeAv2RecordMagic, Endian.little)
    ..setUint32(4, generation, Endian.little)
    ..setUint32(8, unit, Endian.little)
    ..setUint32(12, payload.length, Endian.little);
  record.setAll(16, payload);
  return record;
}

/// The record of the index: generation 0, unit 0xffffffff, the access points as 32-bit numbers
Uint8List fakeAv2IndexRecord(List<int> accessPoints) {
  final numbers = ByteData(4 * accessPoints.length);
  for (final (i, unit) in accessPoints.indexed) {
    numbers.setUint32(4 * i, unit, Endian.little);
  }
  return fakeAv2Record(0, fakeAv2IndexUnit, numbers.buffer.asUint8List());
}

const _help = '''immuch360-av2 (fake of the tests of Immuch360): serves a test pattern as a y4m on 127.0.0.1

Usage:
  immuch360-av2 probe FILE|- [--threads N]
  immuch360-av2 serve --token TOKEN --width W --height H --bits 8|10 --fps NUM/DEN --frames N [options]
  immuch360-av2 --version
  immuch360-av2 --help
''';

// The exit codes of the real one; 1, an internal error, never comes from the fake
const _exitOk = 0;
const _exitUsage = 2;
const _exitVideo = 3;
const _exitNetwork = 4;
const _exitProtocol = 5;

Future<void> main(List<String> arguments) async {
  final pidFile = Platform.environment['IMMUCH360_FAKE_AV2_PID'];
  if (pidFile != null && pidFile.isNotEmpty) {
    File(pidFile).writeAsStringSync('$pid');
  }
  if (arguments.length == 1 && (arguments.first == '--help' || arguments.first == '-h')) {
    stdout.write(_help);
    await stdout.flush();
    exit(_exitOk);
  }
  if (arguments.length == 1 && arguments.first == '--version') {
    final simd = Platform.environment['IMMUCH360_FAKE_AV2_SIMD'] ?? 'avx2';
    _line('immuch360-av2 protocol $fakeAv2Protocol, source fake');
    _line('dav2d fake (fake)');
    _line('simd $simd, uses $simd');
    await stdout.flush();
    exit(_exitOk);
  }
  if (arguments.length >= 2 && arguments.first == 'probe') {
    exit(await _probe(arguments));
  }
  if (arguments.isNotEmpty && arguments.first == 'serve') {
    final options = _ServeOptions.parse(arguments.sublist(1));
    if (options.problem != null) {
      stderr.writeln('immuch360-av2: ${options.problem} (see immuch360-av2 --help)');
      await stderr.flush();
      exit(_exitUsage);
    }
    await _Server(options).run();
    return;
  }
  stderr.write(_help);
  await stderr.flush();
  exit(_exitUsage);
}

void _line(String line) => stdout.writeln(line);

/// The probe: the head of the file read as the app reads it, a line of JSON in the shape of the real one
Future<int> _probe(List<String> arguments) async {
  if (arguments.length != 2 && !(arguments.length == 4 && arguments[2] == '--threads')) {
    stderr.writeln('immuch360-av2: probe takes a file, or - for the standard input, and --threads N');
    return _exitUsage;
  }
  final List<int> bytes;
  try {
    bytes = arguments[1] == '-'
        ? await stdin
              .fold<BytesBuilder>(BytesBuilder(), (builder, chunk) => builder..add(chunk))
              .then((b) => b.toBytes())
        : await File(arguments[1]).readAsBytes();
  } on FileSystemException {
    _line(jsonEncode({'error': 'the file could not be read'}));
    return _exitVideo;
  }
  final head = readAv2Head(bytes.sublist(0, math.min(bytes.length, av2HeadLength)));
  if (head == null) {
    final ivf = bytes.length >= 12 && ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'DKIF';
    final fourcc = ivf ? ascii.decode(bytes.sublist(8, 12), allowInvalid: true) : null;
    final reason = fourcc == 'AV01'
        ? 'an IVF of AV1, not AV2'
        : ivf
        ? 'an IVF of another codec'
        : 'neither an AV2 IVF nor AV2 OBUs';
    _line(jsonEncode({'error': reason}));
    return _exitVideo;
  }
  final bits = int.tryParse(Platform.environment['IMMUCH360_FAKE_AV2_BITS'] ?? '') ?? 8;
  final size = (Platform.environment['IMMUCH360_FAKE_AV2_SIZE'] ?? '256x144').split('x').map(int.parse).toList();
  final width = head.width ?? size[0];
  final height = head.height ?? size[1];
  final playable = bits == 8 || bits == 10;
  final format = '4:2:0 $bits-bit';
  final layout = playable
      ? Y4mLayout(width: width, height: height, bits: bits, fpsNumerator: 1, fpsDenominator: 1, frames: 1)
      : null;
  _line(
    jsonEncode({
      'container': head.container.name,
      'fourcc': head.container == Av2Container.ivf ? 'AV02' : 'OBU',
      'ivf': head.container == Av2Container.ivf
          ? {
              'width': head.width,
              'height': head.height,
              'rate': head.rate,
              'scale': head.scale,
              'frames': head.framesInHeader,
            }
          : null,
      'sequence': {
        'profile': 0,
        'level': 0,
        'tier': 0,
        'bits': bits,
        'layout': '420',
        'max_width': width,
        'max_height': height,
        'still_picture': false,
        'temporal_layers': 1,
        'embedded_layers': 1,
        'film_grain': false,
      },
      'picture': {'width': width, 'height': height, 'bits': bits, 'layout': '420'},
      'color': {'description': false, 'primaries': 2, 'transfer': 2, 'matrix': 2, 'range': 'limited'},
      'format': format,
      'playable': playable,
      'refusal': playable ? null : format,
      'y4m': layout == null ? null : {'colorspace': bits == 8 ? '420' : '420p10', 'frame_bytes': layout.frameBytes},
    }),
  );
  return _exitOk;
}

/// The options of serve, checked as the real program checks them
class _ServeOptions {
  _ServeOptions._(this.problem);

  factory _ServeOptions.parse(List<String> arguments) {
    final options = _ServeOptions._(null);
    var have = 0;
    int? number(String value, int max) {
      final parsed = int.tryParse(value);
      return parsed == null || parsed < 0 || parsed > max || value.startsWith('-') ? null : parsed;
    }

    for (var i = 0; i < arguments.length; i += 2) {
      final name = arguments[i];
      if (i + 1 >= arguments.length) {
        return _ServeOptions._('an option without its value');
      }
      final value = arguments[i + 1];
      switch (name) {
        case '--token':
          if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(value)) {
            return _ServeOptions._('--token takes 16 to 128 letters, digits, - or _');
          }
          options.token = value;
          have |= 1;
        case '--width' || '--height':
          final n = number(value, 65536);
          if (n == null || n == 0) {
            return _ServeOptions._('$name takes a number from 1 to 65536');
          }
          if (name == '--width') {
            options.width = n;
            have |= 2;
          } else {
            options.height = n;
            have |= 4;
          }
        case '--bits':
          final n = number(value, 10);
          if (n != 8 && n != 10) {
            return _ServeOptions._('--bits takes 8 or 10');
          }
          options.bits = n!;
          have |= 8;
        case '--depth':
          if (number(value, 8) != 8) {
            return _ServeOptions._('--depth takes 8');
          }
          options.depth8 = true;
        case '--fps':
          final parts = value.split('/');
          final numerator = parts.length == 2 ? number(parts[0], 0xffffffff) : null;
          final denominator = parts.length == 2 ? number(parts[1], 0xffffffff) : null;
          if (numerator == null || denominator == null || numerator == 0 || denominator == 0) {
            return _ServeOptions._('--fps takes NUM/DEN, two numbers above 0');
          }
          options.fpsNumerator = numerator;
          options.fpsDenominator = denominator;
          have |= 16;
        case '--frames':
          final n = number(value, 100000000);
          if (n == null || n == 0) {
            return _ServeOptions._('--frames takes a number from 1 to 100000000');
          }
          options.frames = n;
          have |= 32;
        case '--threads':
          if (number(value, 256) == null) {
            return _ServeOptions._('--threads takes a number from 0 to 256');
          }
        case '--range':
          if (value != 'limited' && value != 'full') {
            return _ServeOptions._('--range takes limited or full');
          }
          options.fullRange = value == 'full';
        case '--frame-bytes':
          final n = int.tryParse(value);
          if (n == null || n <= 0) {
            return _ServeOptions._('--frame-bytes takes a number above 0');
          }
          options.frameBytes = n;
        case '--port':
          final n = number(value, 65535);
          if (n == null) {
            return _ServeOptions._('--port takes a number from 0 to 65535');
          }
          options.port = n;
        case '--parent':
          final n = number(value, 0xffffffff);
          if (n == null || n == 0) {
            return _ServeOptions._('--parent takes a process id');
          }
          options.parent = n;
        default:
          return _ServeOptions._('an unknown option of serve');
      }
    }
    if ((have & 1) == 0) {
      // The app leaves --token out and gives the token in the environment, as the real one takes it
      final token = Platform.environment[fakeAv2TokenVariable] ?? '';
      if (token.isNotEmpty) {
        if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(token)) {
          return _ServeOptions._('$fakeAv2TokenVariable takes 16 to 128 letters, digits, - or _');
        }
        options.token = token;
        have |= 1;
      }
    }
    if ((have & 1) == 0) {
      return _ServeOptions._('serve needs a token, in the environment variable $fakeAv2TokenVariable or by --token');
    }
    if (have != 63) {
      return _ServeOptions._('serve needs --width, --height, --bits, --fps and --frames');
    }
    return options;
  }

  final String? problem;
  var token = '';
  var width = 0;
  var height = 0;
  var bits = 8;
  var depth8 = false;
  var fpsNumerator = 0;
  var fpsDenominator = 0;
  var frames = 0;
  var fullRange = false;
  int? frameBytes;
  var port = 0;
  int? parent;
}

/// A request of the player: its socket and the bytes asked, [end] included
class _Request {
  _Request(this.socket, this.start, this.end, {required this.ranged});

  final Socket socket;
  final int start;
  final int end;
  final bool ranged;
}

class _Server {
  _Server(this.options)
    : mode = Platform.environment['IMMUCH360_FAKE_AV2_MODE'] ?? 'play',
      failAt = int.tryParse(Platform.environment['IMMUCH360_FAKE_AV2_FAIL_AT'] ?? '') ?? 1,
      fps = math.max(1, int.tryParse(Platform.environment['IMMUCH360_FAKE_AV2_FPS'] ?? '') ?? 240),
      simd = Platform.environment['IMMUCH360_FAKE_AV2_SIMD'] ?? 'avx2';

  final _ServeOptions options;
  final String mode;
  final int failAt;
  final int fps;
  final String simd;

  late final Y4mLayout layout;
  late final List<int> header;
  late final String path;

  // The input: the access points, then the records of the current generation
  List<int>? accessPoints;
  final _accessPointsCame = Completer<void>();
  var generation = 0;
  final _records = <(int unit, int length)>[];
  Completer<void>? _recordCame;

  // The requests
  _Request? _pending;
  Completer<void>? _requestCame;
  Socket? _serving;

  // The decoder
  var _started = false;
  var _ended = false;
  var _expected = 0;
  var _next = 0;
  var _decoded = 0;
  var _served = 0;
  var _position = 0;
  var _busy = Duration.zero;
  // What the report saw at each of its last five ticks, from the start: two seconds of decoding
  final _busySeen = <Duration>[Duration.zero];
  final _decodedSeen = <int>[0];
  var _fps = 0.0;

  Future<void> run() async {
    if (mode == 'no-socket') {
      _line('error network no socket on 127.0.0.1');
      await stdout.flush();
      exit(_exitNetwork);
    }
    layout = Y4mLayout(
      width: options.width,
      height: options.height,
      bits: options.depth8 ? 8 : options.bits,
      fpsNumerator: options.fpsNumerator,
      fpsDenominator: options.fpsDenominator,
      frames: options.frames,
      fullRange: options.fullRange,
    );
    if (options.frameBytes != null && options.frameBytes != layout.frameBytes) {
      stderr.writeln(
        'immuch360-av2: a picture takes ${layout.frameBytes} bytes, --frame-bytes says ${options.frameBytes}',
      );
      await stderr.flush();
      exit(_exitUsage);
    }
    header = ascii.encode(layout.header);
    path = '/${options.token}/video.y4m';
    final ServerSocket listener;
    try {
      listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, options.port);
    } on SocketException {
      _line('error network no socket on 127.0.0.1');
      await stdout.flush();
      exit(_exitNetwork);
    }
    _line(
      'listening ${listener.port} address=127.0.0.1 length=${layout.length} header=${layout.headerLength} '
      'frame=${layout.frameBytes} frames=${layout.frames}',
    );
    unawaited(_readInput());
    _watchParent();
    listener.listen((socket) => unawaited(_accept(socket)));
    if (mode == 'silent') {
      // Hangs: no line, no picture, until the standard input closes
      return;
    }
    Timer.periodic(const Duration(milliseconds: 500), (_) => _report());
    while (true) {
      final request = await _nextRequest();
      _serving = request.socket;
      var whole = false;
      try {
        await _serve(request);
        whole = _pending == null;
      } on Object {
        // The player went, or a new request ended this one: its socket was destroyed while written to
      }
      _serving = null;
      if (whole) {
        await _end(request.socket);
      } else {
        request.socket.destroy();
      }
    }
  }

  /// --parent: the end when that process ends, as the real one does; watched where /proc tells it (Linux), the job
  /// object of the app doing it on Windows
  void _watchParent() {
    final parent = options.parent;
    if (parent == null || !Platform.isLinux) {
      return;
    }
    Timer.periodic(const Duration(milliseconds: 200), (_) async {
      if (!Directory('/proc/$parent').existsSync()) {
        _line('exit parent-gone');
        await stdout.flush();
        exit(_exitOk);
      }
    });
  }

  // --- the input ---------------------------------------------------------------------------------------------------

  Future<void> _readInput() async {
    var rest = Uint8List(0);
    await for (final chunk in stdin) {
      final bytes = Uint8List(rest.length + chunk.length)
        ..setAll(0, rest)
        ..setAll(rest.length, chunk);
      var at = 0;
      while (bytes.length - at >= 16) {
        final data = ByteData.sublistView(bytes, at);
        final length = data.getUint32(12, Endian.little);
        if (data.getUint32(0, Endian.little) != fakeAv2RecordMagic) {
          await _stop(_exitProtocol, 'protocol', 'a record without its AV2R mark');
        }
        if (bytes.length - at - 16 < length) {
          break;
        }
        final recordGeneration = data.getUint32(4, Endian.little);
        final unit = data.getUint32(8, Endian.little);
        final payload = Uint8List.sublistView(bytes, at + 16, at + 16 + length);
        at += 16 + length;
        if (unit == fakeAv2IndexUnit) {
          await _readIndex(payload);
          continue;
        }
        if (accessPoints == null) {
          await _stop(_exitProtocol, 'protocol', 'a unit before the index');
        }
        if (recordGeneration != generation) {
          // Asked for before a seek: dropped
          continue;
        }
        _records.add((unit, length));
        _wakeDecoder();
      }
      rest = Uint8List.fromList(Uint8List.sublistView(bytes, at));
    }
    // Closed by the app, or the app is gone: the end, whatever the player was doing
    _line('exit input-closed');
    await stdout.flush();
    exit(_exitOk);
  }

  void _wakeDecoder() {
    _recordCame?.complete();
    _recordCame = null;
  }

  Future<void> _readIndex(Uint8List payload) async {
    if (payload.isEmpty || payload.length % 4 != 0) {
      await _stop(_exitProtocol, 'protocol', 'the index holds no 32-bit unit numbers');
    }
    if (accessPoints != null) {
      await _stop(_exitProtocol, 'protocol', 'a second index');
    }
    final data = ByteData.sublistView(payload);
    final points = [for (var i = 0; i < payload.length ~/ 4; i++) data.getUint32(4 * i, Endian.little)];
    for (final (i, point) in points.indexed) {
      if ((i == 0 && point != 0) || (i > 0 && point <= points[i - 1]) || point >= layout.frames) {
        await _stop(_exitProtocol, 'protocol', 'the index does not start at 0, go up, and stay below --frames');
      }
    }
    accessPoints = points;
    _accessPointsCame.complete();
  }

  Future<Never> _stop(int code, String kind, String message) async {
    _line('error $kind $message');
    await stdout.flush();
    exit(code);
  }

  // --- the requests ------------------------------------------------------------------------------------------------

  Future<void> _accept(Socket socket) async {
    final remote = socket.remoteAddress;
    if (!remote.isLoopback) {
      _line('refused address');
      socket.destroy();
      return;
    }
    final text = await _readRequest(socket);
    final lines = text?.split('\r\n') ?? const <String>[];
    final first = lines.isEmpty ? const <String>[] : lines.first.split(' ');
    if (text == null || first.length < 2) {
      await _respond(socket, 400);
      _line('refused request');
      await _end(socket);
      return;
    }
    final method = first[0];
    final target = first[1];
    final head = method == 'HEAD';
    if (!head && method != 'GET') {
      await _respond(socket, 405);
      _line('refused method');
      await _end(socket);
      return;
    }
    if (target != path) {
      final tokenMatches = target.startsWith('/${options.token}/');
      await _respond(socket, tokenMatches ? 404 : 403);
      _line(tokenMatches ? 'refused path' : 'refused token');
      await _end(socket);
      return;
    }
    var start = 0;
    var end = layout.length - 1;
    var ranged = false;
    for (final line in lines.skip(1)) {
      if (line.toLowerCase().startsWith('range:')) {
        ranged = true;
        final range = _parseRange(line.substring(6).trim());
        if (range == null || range.$1 > range.$2 || range.$1 >= layout.length) {
          await _respond(socket, 416);
          _line('refused range');
          await _end(socket);
          return;
        }
        (start, end) = range;
        break;
      }
    }
    if (head) {
      await _respond(socket, ranged ? 206 : 200, start: start, end: end);
      await _end(socket);
      return;
    }
    _pending?.socket.destroy();
    _pending = _Request(socket, start, end, ranged: ranged);
    // The request being served is over: its write fails at once
    _serving?.destroy();
    _requestCame?.complete();
    _requestCame = null;
    _wakeDecoder();
  }

  /// Closes [socket] once what was written is gone, as the real one closes its socket after its answer
  Future<void> _end(Socket socket) async {
    try {
      await socket.close().timeout(const Duration(seconds: 1));
    } on Object {
      // The player went first
    }
    socket.destroy();
  }

  Future<String?> _readRequest(Socket socket) async {
    final received = BytesBuilder();
    final done = Completer<String?>();
    // Paused, not cancelled, once the request is read: the socket stays open for the answer, and destroying it ends
    // the subscription
    // ignore: cancel_subscriptions
    late StreamSubscription<Uint8List> subscription;
    subscription = socket.listen(
      (chunk) {
        received.add(chunk);
        final text = latin1.decode(received.toBytes());
        final end = text.indexOf('\r\n\r\n');
        if (end >= 0 && !done.isCompleted) {
          done.complete(text.substring(0, end));
          subscription.pause();
        } else if (received.length > 16384 && !done.isCompleted) {
          done.complete(null);
        }
      },
      onDone: () => done.isCompleted ? null : done.complete(null),
      onError: (Object _) => done.isCompleted ? null : done.complete(null),
    );
    return done.future.timeout(const Duration(seconds: 2), onTimeout: () => null);
  }

  /// bytes=a-b, bytes=a- or bytes=-n (the first range only)
  (int, int)? _parseRange(String value) {
    final match = RegExp(r'^bytes=(\d*)-(\d*)').firstMatch(value.toLowerCase());
    if (match == null) {
      return null;
    }
    final first = match.group(1)!;
    final last = match.group(2)!;
    final total = layout.length;
    if (first.isEmpty) {
      final suffix = int.tryParse(last);
      if (suffix == null || suffix == 0) {
        return null;
      }
      return (suffix >= total ? 0 : total - suffix, total - 1);
    }
    final start = int.parse(first);
    final end = last.isEmpty ? total - 1 : math.min(int.parse(last), total - 1);
    return (start, end);
  }

  Future<void> _respond(Socket socket, int status, {int start = 0, int end = 0}) async {
    final String text;
    if (status == 200 || status == 206) {
      final range = status == 206 ? 'Content-Range: bytes $start-$end/${layout.length}\r\n' : '';
      text =
          'HTTP/1.1 ${status == 206 ? '206 Partial Content' : '200 OK'}\r\nContent-Type: video/x-yuv4mpeg\r\n'
          'Accept-Ranges: bytes\r\n${range}Content-Length: ${end - start + 1}\r\nCache-Control: no-store\r\n'
          'Connection: close\r\n\r\n';
    } else if (status == 416) {
      text =
          'HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */${layout.length}\r\nContent-Length: 0\r\n'
          'Connection: close\r\n\r\n';
    } else {
      final reason = switch (status) {
        403 => 'Forbidden',
        404 => 'Not Found',
        405 => 'Method Not Allowed',
        _ => 'Bad Request',
      };
      text = 'HTTP/1.1 $status $reason\r\nContent-Length: 0\r\nConnection: close\r\n\r\n';
    }
    try {
      socket.add(latin1.encode(text));
      await socket.flush();
    } on Object {
      // The player went
    }
  }

  Future<_Request> _nextRequest() async {
    while (_pending == null) {
      await (_requestCame = Completer<void>()).future;
    }
    final request = _pending!;
    _pending = null;
    return request;
  }

  Future<void> _serve(_Request request) async {
    final socket = request.socket;
    await _respond(socket, request.ranged ? 206 : 200, start: request.start, end: request.end);
    var at = request.start;
    final end = request.end;
    final firstFrame = at < layout.headerLength ? 0 : (at - layout.headerLength) ~/ layout.recordBytes;
    _line('request bytes=$at-$end frame=$firstFrame');
    if (at < layout.headerLength) {
      final stop = math.min(end + 1, layout.headerLength);
      socket.add(header.sublist(at, stop));
      await socket.flush();
      at = stop;
    }
    // The index comes right after the start: a request before it waits for it
    await Future.any([_accessPointsCame.future, _whenPending()]);
    if (_pending != null) {
      return;
    }
    while (at <= end) {
      if (_pending != null) {
        return;
      }
      final k = (at - layout.headerLength) ~/ layout.recordBytes;
      final offset = (at - layout.headerLength) % layout.recordBytes;
      final got = await _picture(k);
      if (got == 0) {
        return;
      }
      if (got < 0) {
        _line('error short the stream ended at picture $_next, --frames is ${layout.frames}');
        return;
      }
      final record = Uint8List(layout.recordBytes)
        ..setAll(0, ascii.encode(y4mFrameMarker))
        ..setAll(y4mFrameMarker.length, fakeAv2Picture(layout, k));
      final size = math.min(layout.recordBytes - offset, end - at + 1);
      socket.add(Uint8List.sublistView(record, offset, offset + size));
      await socket.flush();
      at += size;
      if (offset + size == layout.recordBytes) {
        _served++;
      }
      _position = k + 1;
    }
  }

  Future<void> _whenPending() async {
    while (_pending == null) {
      await (_requestCame = Completer<void>()).future;
    }
  }

  // --- the decoder -------------------------------------------------------------------------------------------------

  int _accessPointBefore(int frame) {
    var found = 0;
    for (final point in accessPoints!) {
      if (point > frame) {
        break;
      }
      found = point;
    }
    return found;
  }

  void _restart(int unit) {
    generation++;
    _records.clear();
    _started = true;
    _ended = false;
    _expected = unit;
    _next = unit;
    _line('need $generation $unit');
  }

  /// Picture [k] made: 1, or 0 when a new request came while waiting for the app, or -1 when the stream has fewer
  /// pictures than --frames
  Future<int> _picture(int k) async {
    final r = _accessPointBefore(k);
    if (!_started || _ended || k < _next || r > _next) {
      _restart(r);
    }
    while (_next <= k) {
      if (_pending != null) {
        return 0;
      }
      if (_records.isEmpty) {
        await (_recordCame = Completer<void>()).future;
        continue;
      }
      final (unit, length) = _records.removeAt(0);
      if (unit != _expected) {
        await _stop(_exitProtocol, 'protocol', 'unit $unit came where unit $_expected was due');
      }
      _expected++;
      if (length == 0) {
        _ended = true;
        return -1;
      }
      if (mode == 'fail' && unit >= failAt) {
        await _stop(_exitVideo, 'decode', 'dav2d error -22 at picture $_next');
      }
      // The time a picture of the pattern takes at the speed asked
      final started = DateTime.now();
      await Future<void>.delayed(Duration(microseconds: 1000000 ~/ fps));
      _busy += DateTime.now().difference(started);
      _decoded++;
      _next++;
    }
    return 1;
  }

  // --- the report --------------------------------------------------------------------------------------------------

  void _report() {
    // The decoding speed over the last two seconds of decoding, the waits for the player and the app left out
    _busySeen.add(_busy);
    _decodedSeen.add(_decoded);
    if (_busySeen.length > 5) {
      _busySeen.removeAt(0);
      _decodedSeen.removeAt(0);
    }
    final busy = _busy - _busySeen.first;
    final decoded = _decoded - _decodedSeen.first;
    if (busy.inMilliseconds >= 50 && decoded > 0) {
      _fps = decoded * 1000000 / busy.inMicroseconds;
    }
    _line(
      'stat decoded=$_decoded served=$_served fps=${_fps.toStringAsFixed(1)} simd=$simd gen=$generation '
      'frame=$_position serving=${_serving == null ? 0 : 1}',
    );
  }
}
