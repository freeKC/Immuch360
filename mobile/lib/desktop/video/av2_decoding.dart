// What the screens of the AV2 videos read of a playback and of the measures of this computer (store/m2/av2-2026-11-02/
// plan-2026-11-02.md, sections 1.3 and 1.4). The screens (lot AD5) were written on these contracts before the playback
// (lot AD3) existed; the app wires them to it (av2_app.dart, lot AD6): [activeAv2Decoding] follows the stat lines of
// the companion immuch360-av2 (fps=, simd=) while an AV2 video plays, [av2ProbeProvider] answers with the probe of the
// companion, [av2SpeedProvider] with the speeds kept per format in the decoder measures of this computer, and
// [av2PlayAnywayProvider] tells the playback a video plays anyway. Without that wiring (the tests, the phones) a video
// is taken as its head says it (an IVF header gives its size and its frame rate) and no speed is known: no notice comes
// before it plays.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/av2_playback.dart';
import 'package:immich_mobile/domain/services/av2_stream.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('Av2Decoding');

/// The head of the file at [path] when it starts an AV2 stream, null for any other file and one that cannot be read
Future<Av2Head?> readAv2HeadOfFile(String path) async {
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    return readAv2Head(await file.read(av2HeadLength));
  } on FileSystemException catch (error) {
    _log.info('The head of ${p.basename(path)} could not be read: ${error.message}');
    return null;
  } finally {
    await file?.close();
  }
}

/// The heads of the .ivf and .obu files of the shares, read once in the session for each file (its share, its path,
/// its size and its date): a tile that comes back on screen does not read its 32 bytes again. [maxConcurrent] reads go
/// at a time and the others wait their turn, as the frames of the videos do. A read that fails is not kept: the next
/// tile or the player tries again. At most [maxKept] heads are kept, the oldest go first.
class NetworkAv2Heads {
  NetworkAv2Heads({this.maxConcurrent = 4, this.maxKept = 20000});

  final int maxConcurrent;
  final int maxKept;

  /// What each head said: null for a file that is no AV2 (an IVF of AV1)
  final _heads = <NetworkMediaKey, Av2Head?>{};
  final _pending = <NetworkMediaKey, Future<Av2Head?>>{};
  final _waiting = Queue<Completer<void>>();
  int _running = 0;

  /// The head of [key], read by [read] (its first bytes) unless known; the error of [read] when it fails
  Future<Av2Head?> head(NetworkMediaKey key, Future<List<int>> Function() read) async {
    if (_heads.containsKey(key)) {
      return _heads[key];
    }
    // Before any wait: a second tile asking meanwhile shares the read
    return _pending[key] ??= _read(key, read);
  }

  Future<Av2Head?> _read(NetworkMediaKey key, Future<List<int>> Function() read) async {
    await _takeTurn();
    try {
      final head = readAv2Head(await read());
      if (_heads.length >= maxKept) {
        _heads.remove(_heads.keys.first);
      }
      _heads[key] = head;
      return head;
    } finally {
      // The future it gives back is this read, which its callers await
      unawaited(_pending.remove(key));
      _endTurn();
    }
  }

  Future<void> _takeTurn() async {
    if (_running < maxConcurrent && _waiting.isEmpty) {
      _running++;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    // Handed over by _endTurn, the count of reads under way staying the same
    await turn.future;
  }

  void _endTurn() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _running--;
    }
  }
}

/// The heads of the files of the shares read in this session
final networkAv2HeadsProvider = Provider<NetworkAv2Heads>((ref) => NetworkAv2Heads());

/// The head of the AV2 file [key] of a share, for the badge and the tile of the browser and for its player: the first
/// 32 bytes of an .ivf or .obu, read on the computers only (the phones do not list them), once in the session
/// (NetworkAv2Heads); null for any other file and one that is not AV2. A head that cannot be read is an error, never
/// "no AV2": the tile then asks mpv for no frame, and the player says why and tries again.
final networkAv2HeadProvider = FutureProvider.autoDispose.family<Av2Head?, NetworkMediaKey>((ref, key) async {
  if (!CurrentPlatform.isDesktop || !isAv2VideoPath(key.path)) {
    return null;
  }
  try {
    return await ref.read(networkAv2HeadsProvider).head(key, () async {
      final fileSystem = await ref.read(networkConnectionsProvider).fileSystem(key.sourceId);
      return fileSystem.readRange(key.path, 0, av2HeadLength);
    });
  } catch (error) {
    _log.info('The head of ${p.posix.basename(key.path)} could not be read: $error');
    rethrow;
  }
});

/// How fast the AV2 video playing decodes on this computer, from the stat lines of the companion
@immutable
class Av2DecodingStats {
  const Av2DecodingStats({required this.neededFps, this.decodedFps, this.simd});

  /// The frame rate of the video, the one its container gives
  final double neededFps;

  /// The frames this computer decodes and serves per second (fps= of the stat lines), null until a run of frames was
  /// measured (the companion writes 0.0 until then)
  final double? decodedFps;

  /// The SIMD level dav2d uses (simd= of the stat lines): avx512icl, avx2, sse41, ssse3, sse2, neon or c; null until
  /// the companion said it
  final String? simd;

  /// The SIMD levels of an x86 processor without AVX2, on which dav2d falls back to code 6 to 7 times slower in 8 bits
  /// (plan, section 1.4)
  static const _withoutAvx2 = {'sse41', 'ssse3', 'sse2'};

  /// Whether this processor has no AVX2: an x86 processor that gives dav2d SSE at most. An ARM processor (neon) is
  /// never said so
  bool get lacksAvx2 => _withoutAvx2.contains(simd);

  @override
  bool operator ==(Object other) =>
      other is Av2DecodingStats && other.neededFps == neededFps && other.decodedFps == decodedFps && other.simd == simd;

  @override
  int get hashCode => Object.hash(neededFps, decodedFps, simd);

  @override
  String toString() => 'Av2DecodingStats($decodedFps of $neededFps fps, simd: $simd)';
}

/// The AV2 video playing on this computer, null while none does: one video plays at a time on the computers
/// (activeDesktopVideo). Set by the playback of lot AD3, read by the "Video decoding" line of the details.
final activeAv2Decoding = ValueNotifier<Av2DecodingStats?>(null);

/// Keeps [target] (activeAv2Decoding) to the session the player plays ([playing], Av2Playbacks.playing): the speed it
/// decodes at (Av2Session.speed, null until measured), the speed the video needs, the SIMD level of dav2d; null while
/// no AV2 video plays
class Av2DecodingFollower {
  Av2DecodingFollower(this.playing, this.target) {
    playing.addListener(_follow);
    _follow();
  }

  final ValueListenable<Av2Session?> playing;
  final ValueNotifier<Av2DecodingStats?> target;
  Av2Session? _session;

  void _follow() {
    _session?.stat.removeListener(_update);
    _session?.speed.removeListener(_update);
    final session = _session = playing.value;
    session?.stat.addListener(_update);
    session?.speed.addListener(_update);
    _update();
  }

  void _update() {
    final session = _session;
    if (session == null) {
      target.value = null;
      return;
    }
    final simd = session.stat.value?.simd ?? '';
    target.value = Av2DecodingStats(
      neededFps: session.neededFps,
      decodedFps: session.speed.value,
      simd: simd.isEmpty ? null : simd,
    );
  }

  void dispose() {
    playing.removeListener(_follow);
    _session?.stat.removeListener(_update);
    _session?.speed.removeListener(_update);
    _session = null;
    target.value = null;
  }
}

/// The last speed this computer measured for a format of AV2 video
@immutable
class Av2Speed {
  const Av2Speed({required this.decodedFps, required this.neededFps});

  final double decodedFps;
  final double neededFps;

  /// How many times the real time this computer decodes the format
  double get ratio => neededFps <= 0 ? double.infinity : decodedFps / neededFps;

  /// Whether the video would pause to catch up: under [av2TooSlowRatio] of its frame rate, the video does not start by
  /// itself, the notice says how fast it decodes and offers to play it anyway (plan, section 1.4)
  bool get tooSlow => ratio < av2TooSlowRatio;

  @override
  bool operator ==(Object other) => other is Av2Speed && other.decodedFps == decodedFps && other.neededFps == neededFps;

  @override
  int get hashCode => Object.hash(decodedFps, neededFps);
}

/// What the app knows of an AV2 video before it plays it: what its head says, then what the probe of the companion
/// read in its sequence header
@immutable
class Av2VideoFormat {
  const Av2VideoFormat({this.width, this.height, required this.frameRate, this.bitDepth, this.refusedFormat});

  /// The format its head gives: the frame size and the frame rate of an IVF header; a Section 5 stream says neither,
  /// and plays at 30 frames per second (av2DefaultFrameRate)
  factory Av2VideoFormat.ofHead(Av2Head head) {
    final rate = head.frameRate ?? av2DefaultFrameRate;
    return Av2VideoFormat(width: head.width, height: head.height, frameRate: rate.numerator / rate.denominator);
  }

  final int? width;
  final int? height;
  final double frameRate;

  /// 8 or 10, null until the companion read it
  final int? bitDepth;

  /// The words of the companion for a stream this version of the decoder does not play ("4:4:4 10-bit"), null for one
  /// it plays
  final String? refusedFormat;

  @override
  bool operator ==(Object other) =>
      other is Av2VideoFormat &&
      other.width == width &&
      other.height == height &&
      other.frameRate == frameRate &&
      other.bitDepth == bitDepth &&
      other.refusedFormat == refusedFormat;

  @override
  int get hashCode => Object.hash(width, height, frameRate, bitDepth, refusedFormat);

  @override
  String toString() => 'Av2VideoFormat(${width}x$height, $frameRate fps, $bitDepth bits, refused: $refusedFormat)';
}

/// An AV2 video the app opens: a file of this computer (the folder library, "Open with") at [path], or a file of a
/// share ([sourceId], [sharePath]), with the head its first bytes gave
@immutable
class Av2VideoRef {
  const Av2VideoRef.file(String this.path, this.head) : sourceId = null, sharePath = null;

  const Av2VideoRef.share(String this.sourceId, String this.sharePath, this.head) : path = null;

  final String? path;
  final String? sourceId;
  final String? sharePath;
  final Av2Head head;

  /// The same for the same file, whichever page opens it
  String get key => path ?? '$sourceId:$sharePath';

  @override
  bool operator ==(Object other) => other is Av2VideoRef && other.key == key && other.head == head;

  @override
  int get hashCode => Object.hash(key, head);

  @override
  String toString() => 'Av2VideoRef($key, $head)';
}

/// The format of [video], read once the AV2 decoder is installed: the probe of the companion (lot AD3), by default what
/// its head says
final av2ProbeProvider = Provider<Future<Av2VideoFormat> Function(Av2VideoRef video)>(
  (ref) =>
      (video) async => Av2VideoFormat.ofHead(video.head),
);

/// The last speed this computer measured for [format], null when it never played one (lot AD3 keeps them in the
/// decoder measures, which it reads from their file); by default none is known
final av2SpeedProvider = Provider<Future<Av2Speed?> Function(Av2VideoFormat format)>(
  (ref) =>
      (_) async => null,
);

/// "Play anyway" on the notice of a format measured too slow here: the playback plays [video] whatever its measure
/// says, for the rest of the session of the app (Av2Playbacks.playAnyway); by default nobody is told
final av2PlayAnywayProvider = Provider<void Function(Av2VideoRef video)>((ref) => (_) {});

/// A path in quotes, spaces allowed, as FileSystemException and others write it
final _quotedPath = RegExp(r"""(['"])((?:[A-Za-z]:\\|\\\\|/)[^'"]*)\1""");

/// A path of Windows (C:\..., \\server\...) or of the other systems (/home/...), up to a space or a quote
final _windowsPath = RegExp(r"""(?:[A-Za-z]:|\\\\[^\\\s'"]+)\\[^\s'"]*""");
final _posixPath = RegExp(r"""(?<![\w.~:/])/(?:[^\s/'"]+/)+[^\s/'"]*""");

/// The last part of [path], a path of any system
String _lastPart(String path) => path.contains('\\') ? p.windows.basename(path) : p.posix.basename(path);

/// The reason the screens of the AV2 videos give for [error], after "The AV2 decoder stopped on this video:" or "The
/// AV2 decoder was not downloaded:": what went wrong in a few words, never the type of the error nor a path of this
/// computer, which holds the name of the user (a file keeps its name). The errors of the playback (av2_playback.dart)
/// give their reason, never "The AV2 decoder stopped on this video" a second time.
String av2ErrorReason(Object error) {
  final text = switch (error) {
    Av2DecoderStopped(:final reason) => reason,
    Av2PlaybackException(:final message) => message,
    Av2NotAv2(:final reason) => 'not an AV2 stream: $reason',
    FileSystemException(:final osError?) when osError.message.trim().isNotEmpty => osError.message,
    FileSystemException(:final message) => message,
    ProcessException(:final message) => message,
    FormatException(:final message) => message,
    StateError(:final message) => message,
    TimeoutException() => 'no answer in time',
    _ => '$error'.replaceFirst(RegExp(r'^(?:Exception|Error)\b:?\s*'), ''),
  };
  final line = const LineSplitter().convert(text.trim()).firstOrNull?.trim() ?? '';
  final named = line
      .replaceAllMapped(_quotedPath, (match) => '${match[1]}${_lastPart(match[2]!)}${match[1]}')
      .replaceAllMapped(_windowsPath, (match) => _lastPart(match[0]!))
      .replaceAllMapped(_posixPath, (match) => _lastPart(match[0]!));
  if (named.isEmpty) {
    return 'no reason given';
  }
  return named.length <= 160 ? named : '${named.substring(0, 159)}…';
}

// The English texts of the failures of the playback (av2_playback.dart, Av2PlaybackException), which reach the player
// as its message, after "This video cannot be played on the computer: " when the source could not be resolved
final _decoderStopped = RegExp(r'The AV2 decoder stopped on this video: (.+)$', dotAll: true);
final _formatRefused = RegExp(r'This AV2 video is (.+): this version of the AV2 decoder does not play it yet');
final _tooSlow = RegExp(
  r'This computer decodes this AV2 video at about (\d+) frames per second and it needs (\d+): it will pause to catch up',
);
const _turnedOff = 'AV2 videos are turned off: ';

/// The failure of a player, [message], in the words of the screens of the AV2 videos ([t]) when the playback of an AV2
/// video gave it (the companion stopped, a format it does not play, a computer too slow, the setting off); null for
/// any other message, which the failure panel shows as it is
String? av2FailureText(String message, Translations t) {
  final stopped = _decoderStopped.firstMatch(message);
  if (stopped != null) {
    return t.av2_error_decoder_stopped(reason: stopped[1]!.trim());
  }
  final refused = _formatRefused.firstMatch(message);
  if (refused != null) {
    return t.av2_error_format(format: refused[1]!);
  }
  final slow = _tooSlow.firstMatch(message);
  if (slow != null) {
    return t.av2_too_slow(fps: slow[1]!, needed: slow[2]!);
  }
  if (message.contains(_turnedOff)) {
    return t.av2_error_off;
  }
  return null;
}

/// A number of frames per second as the AV2 texts give it in [locale]: whole from 10 up, one decimal below ("7.4"), and
/// the frame rate of a video with the decimals it has ("29.97", "30") when [exact]
String av2FpsText(double fps, String locale, {bool exact = false}) {
  final pattern = exact
      ? '#,##0.##'
      : fps >= 10
      ? '#,##0'
      : '#,##0.#';
  try {
    return NumberFormat(pattern, locale).format(fps);
  } on ArgumentError {
    return NumberFormat(pattern, 'en').format(fps);
  }
}
