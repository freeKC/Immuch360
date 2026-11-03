// The AV2 videos of the computers (store/m2/av2-2026-11-02/plan-2026-11-02.md, sections 1.4 and 2.1 to 2.3; lot AD3),
// played through the companion immuch360-av2 (mobile/native/av2, lot AD2), which decodes them with dav2d and serves the
// pictures to the player of the app as a y4m on 127.0.0.1, so that no decoded byte crosses the app:
//  1. the head of the file says AV2 (av2_stream.dart; an IVF of AV1 or VP9 goes to mpv as any video), the probe of the
//     companion says its format, and what this version does not play (4:2:2, 4:4:4, 12 bits) is refused by its name;
//  2. the app reads the container (IVF or OBUs) and cuts it into temporal units, the random access points found in the
//     OBU headers alone; only a key unit that carries its sequence header is one (the companion empties its decoder at
//     each restart, which forgets the header), and a file cut short plays to its last picture without a gap;
//  3. the companion is started by the launcher of the AI programs (a job object on Windows, immuch360-run on Linux, the
//     journal of the session) at the normal priority, playback being the task in front, with --parent, and watched by
//     SidecarRun: its lines read, silent for 10 s it is stopped (its stat line comes every half second), an exit code
//     other than 0 named;
//  4. it answers "listening PORT": the player opens http://127.0.0.1:PORT/TOKEN/video.y4m as a file of a share, whose
//     length is known before anything is decoded: the duration is right, a seek is a byte range, a pause blocks the
//     companion's writes, then its reads of the units, then the app's writes (each one awaits its flush): no processor.
//     The token goes in the companion's environment, never on its command line, which any account of the computer
//     reads;
//  5. the app writes the index of the access points, then the units of each generation the companion asks for ("need G
//     U"), read from the file of this computer or from the share, and drops an older generation as soon as a newer one
//     is asked for;
//  6. its stat lines tell how fast this computer decodes the video: the link of the player is the decoder
//     (MediaKitVideoPlayerController), and the speed is kept per format (size, depth, frame rate) with the decoder
//     measures of this computer (decoder_measure.dart), so that a format this computer decoded below 0.95 times the
//     speed of the video says so before it plays (D2 of the plan; "Play anyway" plays it with its pauses);
//  7. the player let go of the video, the standard input is closed, which ends the companion; it is killed 300 ms later
//     if it is still there. Killed or crashed by itself, or silent, the video fails with "The AV2 decoder stopped on
//     this video" and the reason.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/process/sidecar_run.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/video/player_resource_options.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/av2_stream.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/y4m_layout.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('Av2Playback');

/// Whether [path] (a path of this computer, or the path of a URL of the media bridge) names an AV2 video by its
/// extension: .ivf or .obu, the extensions the computers list (NetworkEntry.desktopVideoExtensions)
bool isAv2VideoPath(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  return dot > 0 && NetworkEntry.desktopVideoExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// The program of the AV2 decoder in its archive
String av2ProgramFileName({bool? windows}) =>
    (windows ?? io.Platform.isWindows) ? 'immuch360-av2.exe' : 'immuch360-av2';

/// The Linux launcher beside it (managed_process.dart)
const _linuxLauncherName = 'immuch360-run';

/// The program of the companion and the launcher it is started through on Linux
typedef Av2CompanionFiles = ({String program, String? launcher});

/// The companion of the installed AV2 decoder, from [main], the file the components service gives for its archive: a
/// program of it, or its folder while the catalogue lists no file of it (no sums yet: the branch of the test build
/// alone has them). The launcher only on Linux, beside the program.
Av2CompanionFiles av2CompanionFilesIn(String main, {bool? windows, bool? linux, bool Function(String path)? isFolder}) {
  final onWindows = windows ?? io.Platform.isWindows;
  final path = onWindows ? p.windows : p.posix;
  final name = av2ProgramFileName(windows: onWindows);
  final folder = (isFolder ?? io.FileSystemEntity.isDirectorySync)(main);
  final program = folder ? path.join(main, name) : path.join(path.dirname(main), name);
  final launcher = (linux ?? io.Platform.isLinux) ? path.join(path.dirname(program), _linuxLauncherName) : null;
  return (program: program, launcher: launcher);
}

/// The bytes of an AV2 file: a file of this computer, or a file of a share read through its file system, as the media
/// bridge reads it (never copied)
abstract class Av2Bytes {
  /// A file of this computer
  factory Av2Bytes.file(String path) = _FileBytes;

  /// The file [path] of the share [fileSystem]
  factory Av2Bytes.share(NetworkFileSystem fileSystem, String path) = _ShareBytes;

  /// What tells this video from another for "Play anyway": its path, or its share and path
  String get key;

  /// The path of a file of this computer, which the probe of the companion reads itself; null for a share
  String? get localPath;

  Future<int> length();

  /// Up to [length] bytes from [offset]: fewer at the end of the file
  Future<Uint8List> read(int offset, int length);

  Future<void> close();
}

class _FileBytes implements Av2Bytes {
  _FileBytes(this.localPath);

  @override
  final String localPath;

  @override
  String get key => localPath;

  io.RandomAccessFile? _file;
  Future<void> _turn = Future.value();

  Future<io.RandomAccessFile> _open() async => _file ??= await io.File(localPath).open();

  @override
  Future<int> length() async => (await _open()).length();

  // A RandomAccessFile takes one operation at a time: the reads go one after the other
  @override
  Future<Uint8List> read(int offset, int length) {
    final result = _turn.then((_) async {
      final file = await _open();
      await file.setPosition(offset);
      return file.read(length);
    });
    _turn = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<void> close() async {
    await _turn;
    final file = _file;
    _file = null;
    await file?.close();
  }
}

class _ShareBytes implements Av2Bytes {
  _ShareBytes(this._fileSystem, this._path);

  final NetworkFileSystem _fileSystem;
  final String _path;

  @override
  String get key => '${_fileSystem.source.id}:$_path';

  @override
  String? get localPath => null;

  @override
  Future<int> length() async => (await _fileSystem.stat(_path)).size ?? 0;

  @override
  Future<Uint8List> read(int offset, int length) => _fileSystem.readRange(_path, offset, length);

  @override
  Future<void> close() async {}
}

/// The colour description of a stream, CICP codes (ITU-T H.273, as AV1 and AV2 write them)
typedef Av2Colour = ({int primaries, int transfer, int matrix});

/// What the probe of the companion says of the start of a file (mobile/native/av2/README.md, probe)
@immutable
class Av2Probe {
  const Av2Probe({
    required this.format,
    required this.playable,
    this.width,
    this.height,
    this.bits,
    this.refusal,
    this.fullRange = false,
    this.colour,
  });

  /// [json], the line of the probe; throws a FormatException for anything else
  factory Av2Probe.fromJson(Map<String, Object?> json) {
    final picture = json['picture'];
    final color = json['color'];
    final format = json['format'];
    final playable = json['playable'];
    if (format is! String || playable is! bool) {
      throw FormatException('not a probe of the AV2 decoder: ${jsonEncode(json)}');
    }
    int? number(Object? map, String key) => map is Map && map[key] is num ? (map[key] as num).toInt() : null;
    final described = color is Map && color['description'] == true;
    return Av2Probe(
      format: format,
      playable: playable,
      width: number(picture, 'width'),
      height: number(picture, 'height'),
      bits: number(picture, 'bits'),
      refusal: switch (json['refusal']) {
        final String refusal => refusal,
        _ => null,
      },
      fullRange: color is Map && color['range'] == 'full',
      colour: described
          ? (
              primaries: number(color, 'primaries') ?? 2,
              transfer: number(color, 'transfer') ?? 2,
              matrix: number(color, 'matrix') ?? 2,
            )
          : null,
    );
  }

  /// "4:2:0 10-bit", the words the app shows when it refuses a stream
  final String format;
  final bool playable;

  /// The first picture, null when none came out of the start of the file
  final int? width;
  final int? height;
  final int? bits;

  /// Why it does not play: its format, or "a stream without a picture in its start"
  final String? refusal;
  final bool fullRange;

  /// Null when the stream describes no colours (none of the streams made so far does)
  final Av2Colour? colour;

  /// The refusal of a start too short to hold a picture, which a longer start may hold
  static const noPictureYet = 'a stream without a picture in its start';
}

/// A stat line of the companion, every half second: the pictures decoded and served, the speed it decodes at (0 until
/// it measured it), the SIMD level of dav2d, the generation, the picture it is at, and whether it serves a request
@immutable
class Av2Stat {
  const Av2Stat({
    required this.decoded,
    required this.served,
    required this.fps,
    this.simd = '',
    this.generation = 0,
    this.frame = 0,
    this.serving = false,
  });

  final int decoded;
  final int served;
  final double fps;
  final String simd;
  final int generation;
  final int frame;
  final bool serving;

  /// The stat line [line] read, null for another line
  static Av2Stat? parse(String line) {
    if (!line.startsWith('stat ')) {
      return null;
    }
    final fields = <String, String>{
      for (final pair in line.substring(5).split(' '))
        if (pair.contains('=')) pair.substring(0, pair.indexOf('=')): pair.substring(pair.indexOf('=') + 1),
    };
    final decoded = int.tryParse(fields['decoded'] ?? '');
    final served = int.tryParse(fields['served'] ?? '');
    final fps = double.tryParse(fields['fps'] ?? '');
    if (decoded == null || served == null || fps == null) {
      return null;
    }
    return Av2Stat(
      decoded: decoded,
      served: served,
      fps: fps,
      simd: fields['simd'] ?? '',
      generation: int.tryParse(fields['gen'] ?? '') ?? 0,
      frame: int.tryParse(fields['frame'] ?? '') ?? 0,
      serving: fields['serving'] == '1',
    );
  }

  @override
  String toString() => 'stat decoded=$decoded served=$served fps=$fps simd=$simd gen=$generation frame=$frame';
}

/// The format of an AV2 video for the speed this computer decodes it at: its size, its depth, its frame rate
@immutable
class Av2Format {
  const Av2Format({required this.width, required this.height, required this.bits, required this.frameRate});

  final int width;
  final int height;
  final int bits;
  final double frameRate;

  bool same(Av2Format other) =>
      other.width == width && other.height == height && other.bits == bits && (other.frameRate - frameRate).abs() < 0.5;

  @override
  bool operator ==(Object other) =>
      other is Av2Format &&
      other.width == width &&
      other.height == height &&
      other.bits == bits &&
      other.frameRate == frameRate;

  @override
  int get hashCode => Object.hash(width, height, bits, frameRate);

  @override
  String toString() => '${width}x$height $bits-bit at ${frameRate.toStringAsFixed(2)} fps';
}

/// The speed this computer decoded a format at ([fps], pictures per second, as the stat lines measure it) with the
/// AV2 decoder [decoder] (its version: a newer dav2d decodes at another speed, so its predecessor's measures say
/// nothing), [at] when
@immutable
class Av2SpeedMeasure {
  const Av2SpeedMeasure({required this.format, required this.fps, required this.decoder, this.at});

  factory Av2SpeedMeasure.fromJson(Map<String, Object?> json) => Av2SpeedMeasure(
    format: Av2Format(
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      bits: (json['bits'] as num?)?.toInt() ?? 0,
      frameRate: (json['frameRate'] as num?)?.toDouble() ?? 0,
    ),
    fps: (json['fps'] as num?)?.toDouble() ?? 0,
    decoder: json['decoder'] as String? ?? '',
    at: DateTime.tryParse(json['at'] as String? ?? ''),
  );

  final Av2Format format;
  final double fps;
  final String decoder;
  final DateTime? at;

  /// The speed against the video's: 1 decodes exactly as fast as it plays
  double get ratio => format.frameRate > 0 ? fps / format.frameRate : 0;

  Map<String, Object?> toJson() => {
    'width': format.width,
    'height': format.height,
    'bits': format.bits,
    'frameRate': format.frameRate,
    'fps': fps,
    'decoder': decoder,
    if (at != null) 'at': at!.toUtc().toIso8601String(),
  };

  @override
  String toString() => 'Av2SpeedMeasure($format: ${fps.toStringAsFixed(1)} fps with $decoder)';
}

/// Below this share of the speed of the video, the last measure of a format stops a video of it before it plays
/// (plan 1.4: 0.95x)
const av2TooSlowRatio = 0.95;

/// Whether [measure] says this computer is too slow for a video of its format: under [av2TooSlowRatio]
bool av2IsTooSlow(Av2SpeedMeasure? measure) => measure != null && measure.ratio < av2TooSlowRatio;

/// Why an AV2 video does not play, with the English text of the app (the screens of lot AD5 show the translated one)
sealed class Av2PlaybackException implements Exception {
  const Av2PlaybackException();

  String get message;

  @override
  String toString() => message;
}

/// The setting "AV2 videos (experimental)" is off (av2_error_off)
class Av2TurnedOff extends Av2PlaybackException {
  const Av2TurnedOff();

  @override
  String get message => 'AV2 videos are turned off: Settings, Videos, AV2 videos';
}

/// The AV2 decoder is not installed (the card of lot AD5 offers it)
class Av2DecoderMissing extends Av2PlaybackException {
  const Av2DecoderMissing();

  @override
  String get message => 'The AV2 decoder is not installed';
}

/// A format this version does not play (av2_error_format)
class Av2FormatRefused extends Av2PlaybackException {
  const Av2FormatRefused(this.format);

  final String format;

  @override
  String get message => 'This AV2 video is $format: this version of the AV2 decoder does not play it yet';
}

/// The last measure of the format says this computer decodes it below [av2TooSlowRatio] (av2_too_slow): "Play
/// anyway" ([Av2Playbacks.playAnyway]) plays it with its pauses
class Av2TooSlow extends Av2PlaybackException {
  const Av2TooSlow({required this.fps, required this.needed, required this.key});

  final double fps;
  final double needed;

  /// The video, for [Av2Playbacks.playAnyway]
  final String key;

  @override
  String get message =>
      'This computer decodes this AV2 video at about ${fps.round()} frames per second and it needs '
      '${needed.round()}: it will pause to catch up';
}

/// The companion stopped on the video (av2_error_decoder_stopped): a damaged file, a crash, a kill, a silence
class Av2DecoderStopped extends Av2PlaybackException {
  const Av2DecoderStopped(this.reason);

  final String reason;

  @override
  String get message => 'The AV2 decoder stopped on this video: $reason';
}

/// Not an AV2 stream after all (an IVF of AV1 or VP9): the player gets the file as any other
class Av2NotAv2 implements Exception {
  const Av2NotAv2(this.reason);

  final String reason;

  @override
  String toString() => 'Not an AV2 stream: $reason';
}

/// What the companion is to its run (SidecarRun): its name and its failures
const av2SidecarProgram = SidecarProgram(
  name: 'immuch360-av2',
  failed: ImmersiveErrorCode.decodeFailed,
  stalled: ImmersiveErrorCode.decodeFailed,
  outOfMemory: ImmersiveErrorCode.outOfMemory,
  outOfMemoryTexts: ['error memory'],
  tailLines: 5,
);

/// "AV2R" read as a little endian 32-bit number: the mark of each record of the standard input
const av2RecordMagic = 0x52325641;

/// The unit number of the record of the index
const av2IndexUnit = 0xffffffff;

/// The 16-byte header of a record of the standard input (mobile/native/av2/README.md), then [payload]
Uint8List av2Record(int generation, int unit, List<int> payload) {
  final record = Uint8List(16 + payload.length);
  ByteData.sublistView(record)
    ..setUint32(0, av2RecordMagic, Endian.little)
    ..setUint32(4, generation, Endian.little)
    ..setUint32(8, unit, Endian.little)
    ..setUint32(12, payload.length, Endian.little);
  record.setAll(16, payload);
  return record;
}

/// The record of the index: generation 0, unit 0xffffffff, the access points as 32-bit numbers
Uint8List av2IndexRecord(List<int> accessPoints) {
  final numbers = ByteData(4 * accessPoints.length);
  for (final (i, unit) in accessPoints.indexed) {
    numbers.setUint32(4 * i, unit, Endian.little);
  }
  return av2Record(0, av2IndexUnit, numbers.buffer.asUint8List());
}

/// The units the companion may start at: unit 0, and every key unit that carries its sequence header (the companion
/// empties its decoder at each restart, and dav2d forgets the header with it), below [frames]
List<int> av2AccessPoints(Av2Index index, int frames) => [
  for (final unit in index.units)
    if (unit.index < frames && unit.isAccessPoint && unit.obuTypes.contains(Av2ObuType.sequenceHeader)) unit.index,
];

/// The pictures the companion serves for [index]: one per whole unit, but for an IVF cut short only those before the
/// first packet cut short (its whole units code pictures after the missing ones)
int av2FramesOf(Av2Index index) => math.min(index.framesBeforeCut ?? index.frameCount, index.frameCount);

/// The bytes the player's cache holds for an AV2 video: the 256 MiB of a streamed video (DesktopPlayerOptions), raised
/// up to 512 MiB while that holds less than a second of pictures (86 pictures of 1080p in 8 bits, 10 of 4K in 10 bits)
int av2CacheBytes(Y4mLayout layout) {
  const floor = 256 * 1024 * 1024;
  const ceiling = 512 * 1024 * 1024;
  final second = (layout.recordBytes * layout.fpsNumerator / layout.fpsDenominator).ceil();
  return second <= floor ? floor : math.min(ceiling, second);
}

/// The names mpv's format filter gives the CICP codes it knows, null for the others
String? _mpvPrimaries(int code) => const {
  1: 'bt.709',
  4: 'bt.470m',
  5: 'bt.601-625',
  6: 'bt.601-525',
  7: 'bt.601-525',
  9: 'bt.2020',
  11: 'dci-p3',
  12: 'display-p3',
}[code];

String? _mpvGamma(int code) => const {
  1: 'bt.1886',
  4: 'gamma2.2',
  5: 'gamma2.8',
  6: 'bt.1886',
  8: 'linear',
  13: 'srgb',
  14: 'bt.1886',
  15: 'bt.1886',
  16: 'pq',
  18: 'hlg',
}[code];

String? _mpvMatrix(int code) => const {1: 'bt.709', 5: 'bt.601', 6: 'bt.601', 9: 'bt.2020-ncl', 10: 'bt.2020-cl'}[code];

/// The options mpv opens the companion's y4m with, beyond those of a streamed video: the y4m demuxer without a probe,
/// the cache of [av2CacheBytes], and the colours of the stream, which a y4m does not carry, set by the format filter
/// when the stream describes them
Map<String, String> av2MpvOptions(Y4mLayout layout, Av2Colour? colour) {
  final filter = <String>[];
  if (colour != null) {
    final matrix = _mpvMatrix(colour.matrix);
    final primaries = _mpvPrimaries(colour.primaries);
    final gamma = _mpvGamma(colour.transfer);
    if (matrix != null) {
      filter.add('colormatrix=$matrix');
    }
    if (primaries != null) {
      filter.add('primaries=$primaries');
    }
    if (gamma != null) {
      filter.add('gamma=$gamma');
    }
  }
  return {
    'demuxer-lavf-format': 'yuv4mpegpipe',
    'demuxer-max-bytes': '${av2CacheBytes(layout)}',
    if (filter.isNotEmpty) 'vf': 'format=${filter.join(':')}',
  };
}

/// The URL the companion serves, see [isAv2CompanionUrl]
final _companionUrl = RegExp(r'^http://127\.0\.0\.1:\d{1,5}/[A-Za-z0-9_-]{16,128}/video\.y4m$');

/// Whether [resource] is the y4m of an AV2 companion: http://127.0.0.1:PORT/TOKEN/video.y4m
bool isAv2CompanionUrl(String resource) => _companionUrl.hasMatch(resource);

/// The variable of the companion's environment that holds its token (mobile/native/av2/README.md, serve): every account
/// of a computer can read the command line of a process, only its own account its environment
const av2TokenVariable = 'IMMUCH360_AV2_TOKEN';

/// A token of the companion: 32 letters and digits drawn by the system's generator
String _token() {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final random = math.Random.secure();
  return String.fromCharCodes(List.generate(32, (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length))));
}

/// A runner that hands the process it starts to [onProcess] too: the session writes to its standard input, which
/// SidecarRun does not give
class _HandingRunner implements ProcessRunner {
  _HandingRunner(this._runner, this._onProcess);

  final ProcessRunner _runner;
  final void Function(RunningProcess process) _onProcess;

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async {
    final process = await _runner.start(launch);
    _onProcess(process);
    return process;
  }
}

/// How long the probe of a file may take: it decodes the first picture (0.9 s for a 4K picture in 10 bits on a
/// four-core laptop)
const av2ProbeTimeout = Duration(seconds: 30);

/// How long the companion may take to listen
const av2ListenTimeout = Duration(seconds: 15);

/// How long the companion stays silent before it is stopped: its stat line comes every half second, whatever the
/// player does
const av2SilenceAllowed = Duration(seconds: 10);

/// How long the companion has to end once its standard input closed, before it is killed
const av2EndGrace = Duration(milliseconds: 300);

/// The bytes of the start of a file of a share the probe is given, in turn while it finds no picture there (the
/// companion's own steps for a file it reads)
const av2ProbeSteps = [1 << 20, 4 << 20, 16 << 20, 64 << 20];

/// Runs the probe of the companion [files] through [runner] on [bytes]: the file itself for a file of this computer,
/// the start of the file on the standard input for a share
Future<Av2Probe> runAv2Probe(ProcessRunner runner, Av2CompanionFiles files, Av2Bytes bytes) async {
  final path = bytes.localPath;
  if (path != null) {
    return _probeOnce(runner, files, ['probe', path], null);
  }
  final length = await bytes.length();
  Av2Probe? probe;
  for (final step in av2ProbeSteps) {
    final input = await bytes.read(0, math.min(step, length));
    probe = await _probeOnce(runner, files, ['probe', '-'], input);
    if (probe.refusal != Av2Probe.noPictureYet || input.length >= length) {
      break;
    }
  }
  return probe!;
}

Future<Av2Probe> _probeOnce(
  ProcessRunner runner,
  Av2CompanionFiles files,
  List<String> arguments,
  Uint8List? input,
) async {
  final lines = <String>[];
  final cancel = NativeCancelFlag();
  final started = Completer<RunningProcess>();
  final run = SidecarRun(
    runner: _HandingRunner(runner, started.complete),
    program: av2SidecarProgram,
    launch: ProcessLaunch(executable: files.program, arguments: arguments, lowPriority: false),
    cancel: cancel,
    elapsed: sidecarStopwatch(),
    stallTimeout: av2ProbeTimeout,
    onLine: (line, {required isError}) {
      if (!isError) {
        lines.add(line);
      }
      return null;
    },
  );
  final timer = Timer(av2ProbeTimeout, cancel.cancel);
  try {
    final running = run.run();
    if (input != null) {
      // The input goes once the program runs; a program that could not start ends the run first
      final process = await Future.any<RunningProcess?>([
        started.future,
        running.then<RunningProcess?>((_) => null, onError: (Object _) => null),
      ]);
      try {
        process?.stdin.add(input);
        await process?.stdin.flush();
        await process?.stdin.close();
      } catch (error) {
        // The probe ended before it read everything (a stream it refuses): its line says why
        _log.fine('The probe did not read its whole input: $error');
      }
    }
    try {
      await running;
    } on SidecarFailure catch (failure) {
      // Exit code 3 with {"error": ...}: not readable
      final said = _errorOf(lines);
      if (said != null) {
        throw Av2DecoderStopped(said);
      }
      throw Av2DecoderStopped(failure.message);
    } on BackendException catch (error) {
      throw Av2DecoderStopped(error.message);
    }
  } finally {
    timer.cancel();
    cancel.free();
  }
  for (final line in lines.reversed) {
    if (!line.startsWith('{')) {
      continue;
    }
    final json = jsonDecode(line);
    if (json is Map<String, Object?>) {
      if (json['error'] case final String error) {
        throw Av2DecoderStopped(error);
      }
      return Av2Probe.fromJson(json);
    }
  }
  throw const Av2DecoderStopped('the probe said nothing');
}

String? _errorOf(List<String> lines) {
  for (final line in lines.reversed) {
    if (line.startsWith('{')) {
      try {
        final json = jsonDecode(line);
        if (json is Map && json['error'] is String) {
          return json['error'] as String;
        }
      } on FormatException {
        // Not the probe's line
      }
    }
  }
  return null;
}

/// What the player's link is told of the decoder: the speed this computer decodes at ([fps], null until measured),
/// the speed the video needs ([needed]), and why the companion stopped ([failure], null while it runs)
typedef Av2Decoding = ({double? fps, double needed, String? failure});

/// One AV2 video served by its companion, from [start] to [stop] (see the top of this file)
class Av2Session {
  Av2Session._({
    required this.bytes,
    required this.index,
    required this.layout,
    required this.probe,
    required this.accessPoints,
    required this.decoderVersion,
  });

  final Av2Bytes bytes;
  final Av2Index index;
  final Y4mLayout layout;
  final Av2Probe probe;
  final List<int> accessPoints;

  /// The version of the AV2 decoder (the catalogue's), which the measures of speed carry
  final String decoderVersion;

  late final Uri url;

  /// The format of the video, for the measures of speed
  Av2Format get format => Av2Format(
    width: layout.width,
    height: layout.height,
    bits: layout.bits,
    frameRate: layout.fpsNumerator / layout.fpsDenominator,
  );

  /// The frames a second the video plays at
  double get neededFps => layout.fpsNumerator / layout.fpsDenominator;

  /// The options mpv opens [url] with ([av2MpvOptions])
  Map<String, String> get mpvOptions => av2MpvOptions(layout, probe.colour);

  /// The last stat line
  ValueListenable<Av2Stat?> get stat => _stat;
  final _stat = ValueNotifier<Av2Stat?>(null);

  /// The speed this computer decodes the video at: the companion's measure, or, while it has none (a player that reads
  /// at the pace of the video from the start), the pictures decoded over the last two seconds against the clock while
  /// it serves; null before anything is known
  ValueListenable<double?> get speed => _speed;
  final _speed = ValueNotifier<double?>(null);

  /// Why the companion stopped when it was not asked to, null while it runs
  ValueListenable<String?> get failure => _failure;
  final _failure = ValueNotifier<String?>(null);

  /// The picture the last request of the player began at (its "request" line), null before any
  ValueListenable<int?> get requestedFrame => _requestedFrame;
  final _requestedFrame = ValueNotifier<int?>(null);

  /// The speed the companion measured last (its fps above 0), which the store keeps
  double? get measuredFps => _measuredFps;
  double? _measuredFps;

  /// What the link of the player is told
  Av2Decoding get decoding => (fps: _speed.value, needed: neededFps, failure: _failure.value);

  /// Whether this computer decodes the video below [av2TooSlowRatio] of its speed, as measured now
  bool get tooSlow => (_measuredFps ?? double.infinity) < neededFps * av2TooSlowRatio;

  RunningProcess? _process;
  late final NativeCancelFlag _cancel;

  /// From the start of the session (the head of the file read): the times its log gives
  final _since = Stopwatch()..start();
  late final Future<void> _ended;
  bool _stopping = false;
  bool _stopped = false;

  // The feeding: the generation and the unit the companion asked for last
  int _generation = 0;
  int _from = 0;
  Completer<void> _asked = Completer<void>();

  // The speed against the clock: decoded counts of the last stat lines while serving, with their times
  final _decodedSeen = <(int decoded, Duration at)>[];
  final _clock = Stopwatch()..start();

  /// Probes [bytes] with the companion [files], reads its container and starts the companion's serve through
  /// [runner]; ready once the companion listens. Throws an [Av2PlaybackException], or [Av2NotAv2] for an IVF of
  /// another codec. [parentPid]: the app's process, which the companion watches (null in the tests that want none).
  /// [beforeServe] may refuse the format before any companion serves it (the measure of speed, see [Av2Playbacks]).
  static Future<Av2Session> start({
    required Av2Bytes bytes,
    required Av2CompanionFiles files,
    required ProcessRunner runner,
    required String decoderVersion,
    int? parentPid,
    int? threads,
    Future<Av2Probe> Function()? probe,
    Future<void> Function(Av2Format format)? beforeServe,
  }) async {
    try {
      return await _start(
        bytes: bytes,
        files: files,
        runner: runner,
        decoderVersion: decoderVersion,
        parentPid: parentPid,
        threads: threads,
        probe: probe,
        beforeServe: beforeServe,
      );
    } catch (_) {
      await bytes.close();
      rethrow;
    }
  }

  static Future<Av2Session> _start({
    required Av2Bytes bytes,
    required Av2CompanionFiles files,
    required ProcessRunner runner,
    required String decoderVersion,
    int? parentPid,
    int? threads,
    Future<Av2Probe> Function()? probe,
    Future<void> Function(Av2Format format)? beforeServe,
  }) async {
    final watch = Stopwatch()..start();
    final length = await bytes.length();
    final head = await bytes.read(0, math.min(av2HeadLength, length));
    if (readAv2Head(head) == null) {
      throw Av2NotAv2(length < av2HeadLength ? 'a file of $length bytes' : 'its first bytes');
    }
    final Av2Index index;
    try {
      index = await indexAv2Stream(bytes.read, length);
    } on Av2FormatException catch (error) {
      throw Av2NotAv2('$error');
    }
    final found = await (probe ?? () => runAv2Probe(runner, files, bytes))();
    if (!found.playable || found.width == null || found.height == null || found.bits == null) {
      throw Av2FormatRefused(found.refusal ?? found.format);
    }
    final frames = av2FramesOf(index);
    final points = av2AccessPoints(index, frames);
    if (frames < 1 || points.isEmpty || points.first != 0) {
      throw const Av2DecoderStopped('the stream does not start with a key frame and its sequence header');
    }
    if (index.end != Av2IndexEnd.complete) {
      _log.info('An AV2 file ${index.end.name} at ${index.endOffset} of ${index.fileLength}: $frames pictures play');
    }
    final rate = index.frameRate;
    final layout = Y4mLayout(
      width: found.width!,
      height: found.height!,
      bits: found.bits!,
      fpsNumerator: rate.numerator,
      fpsDenominator: rate.denominator,
      frames: frames,
      fullRange: found.fullRange,
    );
    final session = Av2Session._(
      bytes: bytes,
      index: index,
      layout: layout,
      probe: found,
      accessPoints: points,
      decoderVersion: decoderVersion,
    );
    await beforeServe?.call(session.format);
    final prepared = watch.elapsedMilliseconds;
    await session._serve(files, runner, parentPid: parentPid, threads: threads);
    _log.info(
      'AV2 video ${session.format}, ${layout.frames} pictures, ${points.length} access points: read and probed in '
      '$prepared ms, served from ${watch.elapsedMilliseconds} ms',
    );
    return session;
  }

  Future<void> _serve(Av2CompanionFiles files, ProcessRunner runner, {int? parentPid, int? threads}) async {
    final token = _token();
    final listening = Completer<int>();
    final rate = '${layout.fpsNumerator}/${layout.fpsDenominator}';
    _cancel = NativeCancelFlag();
    final run = SidecarRun(
      runner: _HandingRunner(runner, (process) => _process = process),
      program: av2SidecarProgram,
      launch: ProcessLaunch(
        executable: files.program,
        arguments: [
          'serve',
          '--width',
          '${layout.width}',
          '--height',
          '${layout.height}',
          '--bits',
          '${layout.bits}',
          '--fps',
          rate,
          '--frames',
          '${layout.frames}',
          '--range',
          layout.fullRange ? 'full' : 'limited',
          '--frame-bytes',
          '${layout.frameBytes}',
          if (threads != null) ...['--threads', '$threads'],
          if (parentPid != null) ...['--parent', '$parentPid'],
        ],
        environment: {av2TokenVariable: token},
        // Playback is the task in front: the decoder runs at the normal priority
        lowPriority: false,
      ),
      cancel: _cancel,
      elapsed: sidecarStopwatch(),
      stallTimeout: av2SilenceAllowed,
      onLine: (line, {required isError}) {
        if (!isError) {
          _onLine(line, listening);
        }
        return null;
      },
    );
    _ended = run
        .run()
        .then<void>(
          (_) {
            if (!_stopping) {
              _fail(_errorText ?? 'it ended by itself');
            }
          },
          onError: (Object error) {
            if (!_stopping) {
              _fail(_errorText ?? (error is BackendException ? error.message : '$error'));
            }
          },
        )
        .whenComplete(() {
          _stopped = true;
          _cancel.free();
          if (!listening.isCompleted) {
            listening.completeError(Av2DecoderStopped(_failure.value ?? _errorText ?? 'it did not start'));
          }
          _wake();
        });
    final int port;
    try {
      port = await listening.future.timeout(av2ListenTimeout);
    } on TimeoutException {
      await stop();
      throw const Av2DecoderStopped('it did not listen on 127.0.0.1');
    } catch (_) {
      await stop();
      rethrow;
    }
    url = Uri.parse('http://127.0.0.1:$port/$token/video.y4m');
    unawaited(_feed());
  }

  /// The message of the companion's last error line, which names its failure
  String? _errorText;

  void _onLine(String line, Completer<int> listening) {
    if (line.startsWith('listening ')) {
      final port = int.tryParse(line.split(' ')[1]);
      final length = RegExp(r'length=(\d+)').firstMatch(line)?.group(1);
      if (port != null && !listening.isCompleted) {
        if (length != null && int.parse(length) != layout.length) {
          _log.warning('The AV2 companion serves $length bytes, ${layout.length} expected');
        }
        listening.complete(port);
      }
      return;
    }
    if (line.startsWith('need ')) {
      final parts = line.split(' ');
      final generation = parts.length == 3 ? int.tryParse(parts[1]) : null;
      final unit = parts.length == 3 ? int.tryParse(parts[2]) : null;
      if (generation != null && unit != null && generation > _generation) {
        _generation = generation;
        _from = unit;
        _wake();
        _log.fine('The AV2 companion: $line (${_since.elapsedMilliseconds} ms)');
      }
      return;
    }
    final stat = Av2Stat.parse(line);
    if (stat != null) {
      _onStat(stat);
      return;
    }
    if (line.startsWith('error ')) {
      final rest = line.substring(6);
      final space = rest.indexOf(' ');
      final kind = space < 0 ? rest : rest.substring(0, space);
      final message = space < 0 ? rest : rest.substring(space + 1);
      if (kind == 'short') {
        // A file whose last unit holds no picture: the request ends early, nothing else
        _log.info('The AV2 companion: $message');
      } else {
        _errorText = message;
        _log.warning('The AV2 companion: $line');
      }
      return;
    }
    if (line.startsWith('request ')) {
      _requestedFrame.value = int.tryParse(RegExp(r'frame=(\d+)').firstMatch(line)?.group(1) ?? '');
      _log.fine('The AV2 companion: $line (${_since.elapsedMilliseconds} ms)');
    } else if (line.startsWith('refused ')) {
      _log.warning('The AV2 companion $line');
    } else if (line.startsWith('exit ')) {
      _log.fine('The AV2 companion: $line');
    }
  }

  void _onStat(Av2Stat stat) {
    _stat.value = stat;
    if (stat.fps > 0) {
      _measuredFps = stat.fps;
      _speed.value = stat.fps;
      _decodedSeen.clear();
      return;
    }
    // No measure yet: the pictures decoded against the clock, while it serves
    if (!stat.serving) {
      _decodedSeen.clear();
      return;
    }
    final now = _clock.elapsed;
    _decodedSeen.add((stat.decoded, now));
    while (_decodedSeen.length > 5) {
      _decodedSeen.removeAt(0);
    }
    if (_decodedSeen.length >= 2) {
      final (first, from) = _decodedSeen.first;
      final seconds = (now - from).inMicroseconds / 1e6;
      if (seconds > 0) {
        _speed.value = (stat.decoded - first) / seconds;
      }
    }
  }

  void _wake() {
    if (!_asked.isCompleted) {
      _asked.complete();
    }
  }

  /// Writes the index, then the units of each generation asked for, each write awaited (see the top of this file)
  Future<void> _feed() async {
    try {
      await _write(av2IndexRecord(accessPoints));
      var fed = 0;
      while (!_stopping && !_stopped) {
        if (_generation == fed) {
          _asked = Completer<void>();
          if (_generation == fed && !_stopping && !_stopped) {
            await _asked.future;
          }
          continue;
        }
        final generation = fed = _generation;
        var unit = _from;
        while (!_stopping && !_stopped && generation == _generation && unit < layout.frames) {
          final part = index.units[unit];
          final payload = await bytes.read(part.offset, part.length);
          if (generation != _generation || _stopping || _stopped) {
            break;
          }
          if (payload.length != part.length) {
            throw io.FileSystemException('the file is shorter than its index', bytes.key);
          }
          await _write(av2Record(generation, unit, payload));
          unit++;
        }
        if (generation == _generation && unit >= layout.frames && !_stopping && !_stopped) {
          // The end: the decoder gives its last pictures
          await _write(av2Record(generation, layout.frames, const []));
        }
      }
    } catch (error) {
      if (!_stopping && !_stopped) {
        // The file went away (a share, a drive pulled out), or the companion's pipe broke: it stops
        _log.warning('The units of an AV2 video could not be written: $error');
        _fail('its file could no longer be read');
        _process?.kill();
      }
    }
  }

  Future<void> _write(Uint8List record) async {
    final process = _process;
    if (process == null) {
      return;
    }
    process.stdin.add(record);
    await process.stdin.flush();
  }

  void _fail(String reason) {
    if (_failure.value == null) {
      _log.warning('The AV2 decoder stopped: $reason');
      _failure.value = reason;
    }
  }

  /// Ends the companion: its standard input closed, then killed after [av2EndGrace] if it is still there; the bytes
  /// of the file let go. Safe to call again.
  Future<void> stop() async {
    if (_stopping) {
      return _ended;
    }
    _stopping = true;
    _wake();
    final process = _process;
    if (process != null) {
      try {
        unawaited(process.stdin.close().then<void>((_) {}, onError: (Object _) {}));
      } on StateError {
        // A write waits for the pipe (the companion paused with its queue full): the kill below ends it
      }
      final ended = await process.exitCode.then((_) => true).timeout(av2EndGrace, onTimeout: () => false);
      if (!ended) {
        process.kill();
      }
    } else {
      _cancel.cancel();
    }
    await _ended;
    await bytes.close();
  }

  /// Whether the companion still runs
  bool get isRunning => !_stopped;

  /// Its process id, null before it started
  int? get pid => _process?.pid;
}

/// Where the app's sessions come from: the companion of the installed decoder, the runner of the AI programs, the
/// shares behind the media bridge, the setting, and the measures of speed
class Av2Playbacks {
  Av2Playbacks({
    required this.companion,
    required this.runner,
    required this.enabled,
    this.decoderVersion = '',
    this.loadMeasure,
    this.recordMeasure,
    this.parentPid,
    this.bridge,
  });

  /// The app's, once the providers made it (desktop_video_view.dart); the thumbnails of the library and of the shares
  /// take it from here
  static Av2Playbacks? app;

  /// The program and the launcher of the installed AV2 decoder, null when it is not installed
  final Future<Av2CompanionFiles?> Function() companion;

  /// The runner of the companions, given its Linux launcher (the session of the AI programs, managed_process.dart)
  final ProcessRunner Function(String? launcher) runner;

  /// Whether "AV2 videos (experimental)" is on
  final bool Function() enabled;

  /// The version of the installed decoder, which the measures carry
  final String decoderVersion;

  /// The last measure of a format with this decoder, and where a new one goes (decoder_measure.dart)
  final Future<Av2SpeedMeasure?> Function(Av2Format format, String decoder)? loadMeasure;
  final Future<void> Function(Av2SpeedMeasure measure)? recordMeasure;

  /// The app's process, which the companions watch
  final int? parentPid;

  /// The share and the path behind a URL of the app's media bridge (LocalMediaBridge.fileOf), for [openResource]
  final ({NetworkFileSystem fileSystem, String path})? Function(Uri url)? bridge;

  final _sessions = <String, Av2Session>{};
  final _anyway = <String>{};

  /// The URLs served for a thumbnail: a grab measures no speed (a burst of a few pictures, beside the player's start)
  final _thumbnails = <String>{};

  /// The session serving [url], null for another resource
  Av2Session? sessionOf(String url) => _sessions[url];

  /// The sessions running, for the tests
  @visibleForTesting
  Iterable<Av2Session> get sessions => _sessions.values;

  /// "Play anyway": [key] plays for the rest of the session of the app, whatever its format's measure says
  void playAnyway(String key) => _anyway.add(key);

  /// The y4m URL of [bytes], served by a new companion until [release]. Throws an [Av2PlaybackException] (the video
  /// does not play, see its message), or [Av2NotAv2] for a file the player opens itself. [forThumbnail]: a frame is all
  /// that is wanted, no measure of speed applies.
  Future<String> open(Av2Bytes bytes, {bool forThumbnail = false}) async {
    if (!enabled()) {
      throw const Av2TurnedOff();
    }
    final files = await companion();
    if (files == null) {
      throw const Av2DecoderMissing();
    }
    final session = await Av2Session.start(
      bytes: bytes,
      files: files,
      runner: runner(files.launcher),
      decoderVersion: decoderVersion,
      parentPid: parentPid,
      beforeServe: forThumbnail || _anyway.contains(bytes.key)
          ? null
          : (format) async {
              final measure = await loadMeasure?.call(format, decoderVersion);
              if (av2IsTooSlow(measure)) {
                throw Av2TooSlow(fps: measure!.fps, needed: format.frameRate, key: bytes.key);
              }
            },
    );
    final url = session.url.toString();
    _sessions[url] = session;
    desktopResourceOptions[url] = session.mpvOptions;
    if (forThumbnail) {
      _thumbnails.add(url);
    } else {
      session.stat.addListener(() => _measureOnce(session));
    }
    return url;
  }

  /// [open] for [resource], a path of this computer or a URL of the app's media bridge (the thumbnails of the library
  /// and of the shares); null for anything else, which the player opens as it is
  Future<String?> openResource(String resource, {bool forThumbnail = false}) async {
    final uri = resource.startsWith('http://') ? Uri.tryParse(resource) : null;
    if (uri != null) {
      final share = bridge?.call(uri);
      return share == null || !isAv2VideoPath(share.path)
          ? null
          : open(Av2Bytes.share(share.fileSystem, share.path), forThumbnail: forThumbnail);
    }
    return isAv2VideoPath(resource) ? open(Av2Bytes.file(resource), forThumbnail: forThumbnail) : null;
  }

  // The first measure of a session is kept at once: a video closed early still tells the next one
  final _measured = Expando<bool>('measured');

  void _measureOnce(Av2Session session) {
    if (_measured[session] == true || session.measuredFps == null) {
      return;
    }
    _measured[session] = true;
    unawaited(_record(session));
  }

  Future<void> _record(Av2Session session) async {
    final fps = session.measuredFps;
    final record = recordMeasure;
    if (fps == null || record == null) {
      return;
    }
    try {
      await record(Av2SpeedMeasure(format: session.format, fps: fps, decoder: decoderVersion, at: DateTime.now()));
    } catch (error) {
      _log.warning('The speed of an AV2 video could not be kept: $error');
    }
  }

  /// What the link of the player of [resource] is told of its decoder, null for a resource no session serves
  Av2Decoding? decodingOf(String resource) => _sessions[resource]?.decoding;

  /// Lets [resource] go: its companion stops (within a second), its last measure of speed is kept
  Future<void> release(String resource) async {
    final session = _sessions.remove(resource);
    if (session == null) {
      return;
    }
    desktopResourceOptions.remove(resource);
    await session.stop();
    if (!_thumbnails.remove(resource)) {
      await _record(session);
    }
  }

  /// Stops every companion, at the close of the app
  Future<void> releaseAll() => Future.wait([for (final url in _sessions.keys.toList()) release(url)]);
}
