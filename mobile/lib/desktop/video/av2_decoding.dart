// What the screens of the AV2 videos read of a playback and of the measures of this computer (store/m2/av2-2026-11-02/
// plan-2026-11-02.md, sections 1.3 and 1.4). The screens (lot AD5) are written on these contracts before the playback
// (lot AD3) exists: the playback sets [activeAv2Decoding] from the stat lines of the companion immuch360-av2 (fps=,
// simd=) while an AV2 video plays, and answers [av2ProbeProvider] with the probe of the companion and
// [av2SpeedProvider] with the speeds it keeps per format in the decoder measures of this computer. Until then a video
// is taken as its head says it (an IVF header gives its size and its frame rate) and no speed is known: no notice comes
// before it plays.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/av2_stream.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('Av2Decoding');

/// The extensions of the AV2 files the app reads (plan, section 1.1): IVF and Section 5 OBU streams
const av2FileExtensions = {'ivf', 'obu'};

/// Whether [name] is named like an AV2 file the app reads; its head tells whether it is one (readAv2Head)
bool isAv2FileName(String name) {
  final extension = p.extension(name).toLowerCase();
  return extension.length > 1 && av2FileExtensions.contains(extension.substring(1));
}

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

/// The head of the AV2 file [key] of a share, for the badge and the tile of the browser and for its player: the first
/// 32 bytes of an .ivf or .obu, read on the computers only (the phones do not list them); null for any other file, one
/// that is not AV2, and one that cannot be read
final networkAv2HeadProvider = FutureProvider.autoDispose.family<Av2Head?, NetworkMediaKey>((ref, key) async {
  if (!CurrentPlatform.isDesktop || !isAv2FileName(key.path)) {
    return null;
  }
  try {
    final fileSystem = await ref.read(networkConnectionsProvider).fileSystem(key.sourceId);
    return readAv2Head(await fileSystem.readRange(key.path, 0, av2HeadLength));
  } on NetworkFileSystemException catch (error) {
    _log.info('The head of ${p.posix.basename(key.path)} could not be read: $error');
    return null;
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

/// The last speed this computer measured for a format of AV2 video
@immutable
class Av2Speed {
  const Av2Speed({required this.decodedFps, required this.neededFps});

  final double decodedFps;
  final double neededFps;

  /// Under this share of the frame rate of a video, its format is too slow for this computer: the video does not start
  /// by itself, the notice says how fast it decodes and offers to play it anyway (plan, section 1.4)
  static const tooSlowRatio = 0.95;

  /// How many times the real time this computer decodes the format
  double get ratio => neededFps <= 0 ? double.infinity : decodedFps / neededFps;

  /// Whether the video would pause to catch up
  bool get tooSlow => ratio < tooSlowRatio;

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

/// A path in quotes, spaces allowed, as FileSystemException and others write it
final _quotedPath = RegExp(r"""(['"])((?:[A-Za-z]:\\|\\\\|/)[^'"]*)\1""");

/// A path of Windows (C:\..., \\server\...) or of the other systems (/home/...), up to a space or a quote
final _windowsPath = RegExp(r"""(?:[A-Za-z]:|\\\\[^\\\s'"]+)\\[^\s'"]*""");
final _posixPath = RegExp(r"""(?<![\w.~:/])/(?:[^\s/'"]+/)+[^\s/'"]*""");

/// The last part of [path], a path of any system
String _lastPart(String path) => path.contains('\\') ? p.windows.basename(path) : p.posix.basename(path);

/// The reason the screens of the AV2 videos give for [error], after "The AV2 decoder stopped on this video:" or "The
/// AV2 decoder was not downloaded:": what went wrong in a few words, never the type of the error nor a path of this
/// computer, which holds the name of the user (a file keeps its name). Lot AD6 adds the errors of the playback.
String av2ErrorReason(Object error) {
  final text = switch (error) {
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
