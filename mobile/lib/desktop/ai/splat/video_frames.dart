// The frames of a video made ready for COLMAP (plan 2026-11-01, section 2.2, lot SP5): 150 frames for a video of up to
// two minutes, one every 0.8 s beyond, 250 at most (SplatV1), each the sharpest of a few candidates of its window of
// time, as the measure of the morning chose them (tools/pick_sharp.py: 150 windows, the variance of the Laplacian of a
// grey copy of 512 pixels, a window whose best stays under half the median of its neighbours left out as blurred). The
// frames are numbered in the order of time in one folder: one camera for COLMAP, whose sequential matching follows
// the names.
//
// The frames come from a SplatFrameSource: the app's own libmpv in the build (mpv_frame_source.dart: a muted player,
// an exact seek, then mpv's screenshot-raw, as VideoThumbnailGrabber takes a thumbnail), synthetic frames in the tests.
// The best candidate of a window is encoded while the next window is sought.

import 'dart:io';
import 'dart:math' as math;

import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/write_failure.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/splat/sharpness.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_inputs.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('VideoFrames');

/// The candidates of a window, the sharpest of which is kept: 4.4 a window in the measure (664 for 150 windows)
const splatFrameCandidates = 4;

/// The folder of the frames of a video under the images folder: one camera
const splatVideoFolder = 'video';

/// How many frames a video of [duration] gives: SplatV1.videoFrames up to SplatV1.videoFramesUntil, then one every
/// SplatV1.videoFramesUntil / SplatV1.videoFrames, SplatV1.maxVideoFrames at most
int splatVideoFrameCount(Duration duration) {
  if (duration <= SplatV1.videoFramesUntil) {
    return SplatV1.videoFrames;
  }
  final every = SplatV1.videoFramesUntil.inMicroseconds / SplatV1.videoFrames;
  return math.min(SplatV1.maxVideoFrames, (duration.inMicroseconds / every).ceil());
}

/// One window of time of a video, and the moments of its candidates
class SplatFrameWindow {
  const SplatFrameWindow(this.start, this.end, this.candidates);

  final Duration start;
  final Duration end;
  final List<Duration> candidates;

  @override
  String toString() => 'SplatFrameWindow($start to $end, ${candidates.length} candidates)';
}

/// The windows of a video of [duration] at [fps] frames a second (null when not known): [frames] equal windows
/// ([splatVideoFrameCount] by default), never more than the video has frames, each with [candidates] moments spread
/// evenly in it (no more than the frames it holds), none in the last frame of the video, where a seek may find nothing
List<SplatFrameWindow> planVideoFrames(
  Duration duration, {
  double? fps,
  int candidates = splatFrameCandidates,
  int? frames,
}) {
  final length = duration.inMicroseconds;
  if (length <= 0) {
    return const [];
  }
  final frameLength = fps != null && fps > 0 ? 1e6 / fps : null;
  var count = frames ?? splatVideoFrameCount(duration);
  if (frameLength != null) {
    // A hundredth of a frame of slack: windows are whole microseconds, frames are not
    count = math.max(1, math.min(count, (length / frameLength + 0.01).floor()));
  }
  final last = length - (frameLength ?? 50000).round();
  final windows = <SplatFrameWindow>[];
  for (var i = 0; i < count; i++) {
    final start = length * i ~/ count;
    final end = length * (i + 1) ~/ count;
    final span = end - start;
    final inWindow = frameLength == null
        ? candidates
        : math.max(1, math.min(candidates, (span / frameLength + 0.01).floor()));
    windows.add(
      SplatFrameWindow(Duration(microseconds: start), Duration(microseconds: end), [
        for (var j = 0; j < inWindow; j++)
          Duration(microseconds: math.max(0, math.min(last, start + (span * (2 * j + 1)) ~/ (2 * inWindow)))),
      ]),
    );
  }
  return windows;
}

/// What a video tells once open
class SplatVideoFacts {
  const SplatVideoFacts({required this.duration, this.fps});

  final Duration duration;

  /// Frames a second, null when the file does not say
  final double? fps;
}

/// A frame of the video, upright, with its sharpness (sharpness.dart); its pixels stay where the source keeps them
/// until [writeJpeg]
abstract interface class SplatFrame {
  /// Where it is in the video
  Duration get time;

  /// Its size as decoded, upright
  int get width;
  int get height;
  double get sharpness;

  /// Writes it to [path] as a JPEG of SplatV1.photoQuality, reduced to SplatV1.photoLongSide on its longest side; the
  /// size written
  Future<({int width, int height})> writeJpeg(String path);
}

/// The frames of one video
abstract interface class SplatFrameSource {
  /// Opens [resource], a path of this computer; throws a ConversionException (sourceLost, decodeFailed) when it does
  /// not open as a video
  Future<SplatVideoFacts> open(String resource);

  /// The frame shown at [time], decoded exactly there; null when none came
  Future<SplatFrame?> frameAt(Duration time);

  /// Lets the video go: its decoder, its file
  Future<void> close();
}

/// "1:02.4", a moment of a video as the left out list names it
String splatMomentName(Duration time) {
  final tenths = time.inMilliseconds ~/ 100;
  final seconds = tenths ~/ 10;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}.${tenths % 10}';
}

/// Takes the frames of the video [resource] into [imagesFolder] (emptied first), by [source]: the sharpest candidate
/// of each window of [planVideoFrames] ([frames] and [candidates] as it takes them), then the windows whose best is
/// blurred left out, the others numbered in the order of time in [splatVideoFolder]. [onProgress] gets the windows
/// done of all. Throws a ConversionException: cancelled once [cancel] is set, diskFull or readOnly when a frame cannot
/// be written, the one of [source] when the video does not open.
Future<SplatInputs> takeVideoFrames(
  String resource, {
  required SplatFrameSource source,
  required String imagesFolder,
  required NativeCancelFlag cancel,
  void Function(int done, int total)? onProgress,
  int candidates = splatFrameCandidates,
  int? frames,
}) async {
  final images = Directory(imagesFolder);
  if (images.existsSync()) {
    await images.delete(recursive: true);
  }
  final folder = await Directory(p.join(imagesFolder, splatVideoFolder)).create(recursive: true);
  final watch = Stopwatch()..start();
  final best = <int, SplatFrame>{};
  final written = <int, ({int width, int height})>{};
  final leftOut = <int, SplatLeftOut>{};
  final writing = <Future<void>>[];
  Object? writeFailure;
  var seeks = 0;
  var windows = const <SplatFrameWindow>[];
  try {
    final facts = await source.open(resource);
    windows = planVideoFrames(facts.duration, fps: facts.fps, candidates: candidates, frames: frames);
    for (final (index, window) in windows.indexed) {
      SplatFrame? sharpest;
      for (final time in window.candidates) {
        if (cancel.isCancelled) {
          throw const ConversionException(ImmersiveErrorCode.cancelled);
        }
        seeks++;
        final frame = await source.frameAt(time);
        if (frame != null && (sharpest == null || frame.sharpness > sharpest.sharpness)) {
          sharpest = frame;
        }
      }
      if (writeFailure != null) {
        throw _writeFailed(writeFailure!);
      }
      if (sharpest == null) {
        leftOut[index] = SplatLeftOut(splatMomentName(window.start), SplatLeftOutReason.unreadable, 'no frame');
      } else {
        best[index] = sharpest;
        // Two writes at most under way: the next window is sought meanwhile
        if (writing.length >= 2) {
          await writing.removeAt(0);
        }
        writing.add(
          sharpest
              .writeJpeg(p.join(folder.path, 'w${splatImageName(index)}'))
              .then((size) {
                written[index] = size;
              })
              .catchError((Object error) {
                writeFailure ??= error;
              }),
        );
      }
      onProgress?.call(index + 1, windows.length);
    }
    await Future.wait(writing);
    writing.clear();
    if (writeFailure != null) {
      throw _writeFailed(writeFailure!);
    }

    // The blurred windows, against the windows just before and after them and under a quarter of the median of all (a
    // run of close-ups out of focus, lot SPF2)
    final order = best.keys.toList()..sort();
    final blurred = blurredAmong([for (final index in order) best[index]!.sharpness], floor: SplatV1.blurFloorRatio);
    final kept = <SplatImage>[];
    for (final (position, index) in order.indexed) {
      final frame = best[index]!;
      final staged = File(p.join(folder.path, 'w${splatImageName(index)}'));
      if (blurred.contains(position)) {
        leftOut[index] = SplatLeftOut(splatMomentName(frame.time), SplatLeftOutReason.blurred);
        await staged.delete();
        continue;
      }
      final name = splatImageName(kept.length);
      await staged.rename(p.join(folder.path, name));
      kept.add(
        SplatImage(
          folder: splatVideoFolder,
          name: name,
          width: written[index]!.width,
          height: written[index]!.height,
          sharpness: frame.sharpness,
          source: splatMomentName(frame.time),
        ),
      );
    }
    final out = [for (var index = 0; index < windows.length; index++) ?leftOut[index]];
    _log.info(
      '${kept.length} of ${windows.length} frames taken from $seeks seeks in ${watch.elapsedMilliseconds} ms; '
      '${out.where((left) => left.reason == SplatLeftOutReason.blurred).length} windows blurred, '
      '${out.where((left) => left.reason == SplatLeftOutReason.unreadable).length} without a frame',
    );
    return SplatInputs(
      images: kept,
      leftOut: out,
      total: windows.length,
      cameras: const {splatVideoFolder: null},
      fromVideo: true,
    );
  } on FileSystemException catch (error) {
    throw ConversionException(writeFailureOf(error).errorCode, error.osError?.message ?? error.message);
  } finally {
    // A cancel lets the writes under way end before the job ends: none writes into a folder the queue is deleting
    await Future.wait(writing);
    await source.close();
  }
}

/// What a frame that could not be written ends the job with: the failure of the disk, or a frame the codecs refused
Exception _writeFailed(Object error) => switch (error) {
  final FileSystemException failure => failure,
  final ConversionException failure => failure,
  _ => ConversionException(ImmersiveErrorCode.writeFailed, '$error'),
};

/// [takeVideoFrames] on the video [member]: read (a server original is copied first), its frames taken, then released.
/// A video given as bytes only is written next to [imagesFolder] first, as libmpv reads a file.
Future<SplatInputs> takeMemberFrames(
  SplatMember member, {
  required SplatFrameSource source,
  required String imagesFolder,
  required NativeCancelFlag cancel,
  void Function(int done, int total)? onProgress,
}) async {
  File? written;
  try {
    final video = await member.load(cancel);
    var path = video.path;
    if (path == null) {
      written = File(p.join(p.dirname(imagesFolder), 'video${p.extension(video.name)}'));
      await written.writeAsBytes(video.bytes!);
      path = written.path;
    }
    return await takeVideoFrames(
      path,
      source: source,
      imagesFolder: imagesFolder,
      cancel: cancel,
      onProgress: onProgress,
    );
  } on FileSystemException catch (error) {
    throw ConversionException(writeFailureOf(error).errorCode, error.osError?.message ?? error.message);
  } finally {
    if (written != null && written.existsSync()) {
      await written.delete();
    }
    await member.release();
  }
}
