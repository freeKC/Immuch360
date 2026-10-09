// What the libmpv probe (libmpv_probe_test.dart) and the measurement harness
// (integration_test/desktop_video_measure_test.dart) share: a reference video that needs no clip, and the filter that
// decides which lines of mpv's log a report may quote.
//
// mpv's verbose log names what it opens: file paths (the owner's folder names) and URLs (the media bridge puts its
// token in its URLs, an RTSP address carries the camera's password). The reports need a few of its lines only (the
// OpenGL version, the decoder, "dumb mode", what was disabled), so lines are kept by what they say, never all of them,
// and every URL and named path is replaced before a line is kept.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// mpv's own test pattern, decoded by nothing (raw frames from libavfilter): needs a libmpv built with libavdevice
String lavfiReference({int width = 1920, int height = 1080, int fps = 30}) =>
    'av://lavfi:testsrc2=size=${width}x$height:rate=$fps';

/// The parts of mpv's log a report may keep: the renderer, the decoder, the shaders and the errors
final _interesting = RegExp(
  r'GL_VERSION|GL_RENDERER|GL_VENDOR|GLSL version|Detected|dumb mode|Disabling|disabled|hwdec|Using hardware'
  r'|Using software|interop|FBO format|fbo format|shader|Shader|error|Error|failed|Failed|cannot|Cannot|not supported'
  r'|Unsupported|VO:|Decoder|decoder|Video:|\bvo/|ANGLE|d3d11|D3D11',
);

final _url = RegExp(r'\b[a-zA-Z][a-zA-Z0-9+.-]*://\S+');

/// A Windows or POSIX absolute path with at least one folder; mpv quotes them in single quotes or after "Opening"
final _absolutePath = RegExp(r'''(?:[A-Za-z]:[\\/]|\\\\|/(?=[^/\s]+/))[^\s'"]+''');

/// Keeps the lines of mpv's log that a report may quote, redacted; at most [maxLines], then counts the rest
class MpvLogFilter {
  /// [keepAll] keeps every line, still redacted: for a run that looks into a failure
  MpvLogFilter({Iterable<String> secrets = const [], this.maxLines = 400, this.keepAll = false})
    : _secrets = secrets.where((secret) => secret.isNotEmpty).toList()..sort((a, b) => b.length - a.length);

  final List<String> _secrets;
  final int maxLines;
  final bool keepAll;
  final List<String> lines = [];
  int dropped = 0;

  /// Counts of lines by marker, whether kept or not: "dumb mode" and "Disabling" are verdicts of the spikes
  final Map<String, int> markers = {'dumb mode': 0, 'Disabling': 0};

  /// Only what the line says about the renderer and the decoder, with every URL, path and given secret replaced
  static String? redact(String text, {List<String> secrets = const []}) {
    if (!_interesting.hasMatch(text)) {
      return null;
    }
    return scrub(text, secrets: secrets);
  }

  /// Any text with its URLs and absolute paths replaced, whatever it says: for errors quoted in a report
  static String scrub(String text, {List<String> secrets = const []}) {
    var line = text.trimRight();
    for (final secret in secrets) {
      line = line.replaceAll(secret, '<named>');
    }
    return line.replaceAll(_url, '<url>').replaceAll(_absolutePath, '<path>');
  }

  void add(PlayerLog log) => addText('${log.prefix}: ${log.text}');

  void addText(String text) {
    for (final marker in markers.keys) {
      if (text.contains(marker)) {
        markers[marker] = markers[marker]! + 1;
      }
    }
    final line = keepAll ? scrub(text, secrets: _secrets) : redact(text, secrets: _secrets);
    if (line == null) {
      return;
    }
    if (lines.length < maxLines) {
      lines.add(line);
    } else {
      dropped++;
    }
  }

  /// The first kept line that contains [needle], null when none
  String? firstWith(String needle) {
    for (final line in lines) {
      if (line.contains(needle)) {
        return line;
      }
    }
    return null;
  }
}

/// A moving pattern of [frames] frames written as an uncompressed AVI (raw I420, which FFmpeg reads with its rawvideo
/// decoder), for the libmpv builds without mpv's lavfi input; played in a loop it stands for a clip. AVI because the
/// "video" build of libmpv that media_kit ships has the avi demuxer and not the YUV4MPEG2 one.
Future<File> aviReference(Directory folder, {int width = 1280, int height = 720, int frames = 30, int fps = 30}) async {
  assert(width.isEven && height.isEven);
  await folder.create(recursive: true);
  final frameSize = width * height * 3 ~/ 2;
  final file = File(p.join(folder.path, 'reference_${width}x${height}_$fps.avi'));
  final sink = file.openWrite();

  Uint8List chunk(String id, int size) =>
      (ByteData(8)
            ..setUint32(0, _fourcc(id), Endian.little)
            ..setUint32(4, size, Endian.little))
          .buffer
          .asUint8List();
  Uint8List list(String type, int size) => Uint8List.fromList([...chunk('LIST', size + 4), ..._fourccBytes(type)]);
  Uint8List words(List<int> values) {
    final data = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      data.setUint32(i * 4, values[i] & 0xffffffff, Endian.little);
    }
    return data.buffer.asUint8List();
  }

  final avih = words([1000000 ~/ fps, frameSize * fps, 0, 0x10, frames, 0, 1, frameSize, width, height, 0, 0, 0, 0]);
  final strh = Uint8List.fromList([
    ..._fourccBytes('vids'),
    ..._fourccBytes('I420'),
    ...words([0, 0, 0, 1, fps, 0, frames, frameSize, 0xffffffff, 0]),
    ...(ByteData(8)
          ..setInt16(4, width, Endian.little)
          ..setInt16(6, height, Endian.little))
        .buffer
        .asUint8List(),
  ]);
  final strf = Uint8List.fromList([
    ...words([40, width, height]),
    ...(ByteData(4)
          ..setUint16(0, 1, Endian.little)
          ..setUint16(2, 12, Endian.little))
        .buffer
        .asUint8List(),
    ..._fourccBytes('I420'),
    ...words([frameSize, 0, 0, 0, 0]),
  ]);
  final strl = [...chunk('strh', strh.length), ...strh, ...chunk('strf', strf.length), ...strf];
  final hdrl = [...chunk('avih', avih.length), ...avih, ...list('strl', strl.length), ...strl];
  final movieSize = frames * (8 + frameSize);
  final indexSize = frames * 16;
  final riffSize = 4 + (12 + hdrl.length) + (12 + movieSize) + (8 + indexSize);

  sink
    ..add(chunk('RIFF', riffSize))
    ..add(_fourccBytes('AVI '))
    ..add(list('hdrl', hdrl.length))
    ..add(hdrl)
    ..add(list('movi', movieSize));
  final luma = Uint8List(width * height);
  final chroma = Uint8List(width * height ~/ 4);
  for (var frame = 0; frame < frames; frame++) {
    final shift = frame * 256 ~/ frames;
    for (var y = 0; y < height; y++) {
      final row = y * width;
      for (var x = 0; x < width; x++) {
        // A gradient that moves one step a frame, with a checkerboard so that scaling and drops are visible
        luma[row + x] = ((x + shift) & 255) ~/ 2 + ((x ~/ 32 + y ~/ 32).isEven ? 32 : 96);
      }
    }
    sink
      ..add(chunk('00dc', frameSize))
      ..add(luma);
    chroma.fillRange(0, chroma.length, (128 + shift ~/ 4) & 255);
    sink.add(chroma);
    chroma.fillRange(0, chroma.length, (192 - shift ~/ 4) & 255);
    sink.add(chroma);
  }
  final index = BytesBuilder();
  for (var frame = 0; frame < frames; frame++) {
    // Offsets from the "movi" type, as the AVI index has them; every raw frame is a key frame
    index
      ..add(_fourccBytes('00dc'))
      ..add(words([0x10, 4 + frame * (8 + frameSize), frameSize]));
  }
  sink
    ..add(chunk('idx1', indexSize))
    ..add(index.takeBytes());
  await sink.close();
  return file;
}

int _fourcc(String code) => ByteData.sublistView(_fourccBytes(code)).getUint32(0, Endian.little);

Uint8List _fourccBytes(String code) => Uint8List.fromList(code.codeUnits);

/// Opens the reference video in [player]: mpv's lavfi pattern when the libmpv build has that input, else an uncompressed
/// AVI written to [folder]. Returns which one plays ("lavfi" or "avi"); when neither does, the error tells what mpv
/// said, redacted.
Future<String> openReference(
  Player player,
  Directory folder, {
  int width = 1920,
  int height = 1080,
  int fps = 30,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final native = player.platform! as NativePlayer;
  final errors = <String>[];
  final errorSubscription = player.stream.error.listen((error) => errors.add(MpvLogFilter.scrub(error)));
  try {
    await native.setProperty('loop-file', 'inf');
    // media_kit leaves the video track off (vid=no) until a VideoController attaches; a player without one decodes too
    await native.setProperty('vid', 'auto');
    // media_kit turns cache-on-disk on, and mpv has no cache folder of its own without a config folder ("Failed to
    // create file cache"): the demuxer cache goes to the reference folder
    await native.setProperty('demuxer-cache-dir', folder.path);
    await player.open(Media(lavfiReference(width: width, height: height, fps: fps)));
    if (await waitForVideo(player, timeout, failed: () => errors.isNotEmpty)) {
      return 'lavfi';
    }
    errors.clear();
    // At most 1280 x 720: 1.4 MB a frame, 41 MB for the second of frames that loops
    final file = await aviReference(
      folder,
      width: width.clamp(2, 1280) & ~1,
      height: height.clamp(2, 720) & ~1,
      fps: fps,
    );
    await player.open(Media(file.path));
    if (await waitForVideo(player, timeout, failed: () => errors.isNotEmpty)) {
      return 'avi';
    }
    final state = <String>[
      for (final name in ['vid', 'vo', 'idle-active', 'track-list/count', 'file-format', 'current-demuxer'])
        '$name=${MpvLogFilter.scrub(await native.getProperty(name))}',
    ];
    throw StateError('Neither the lavfi pattern nor the AVI file opened: ${state.join(', ')}; errors: $errors');
  } finally {
    await errorSubscription.cancel();
  }
}

/// Whether mpv decodes a video frame size within [timeout]; read from mpv's "width" property rather than from the
/// player's streams, so that it holds with any video output. Stops early when [failed] says so (an error came).
Future<bool> waitForVideo(Player player, Duration timeout, {bool Function()? failed}) async {
  final native = player.platform! as NativePlayer;
  final watch = Stopwatch()..start();
  while (watch.elapsed < timeout && !(failed?.call() ?? false)) {
    if ((int.tryParse(await native.getProperty('width')) ?? 0) > 0) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return false;
}
