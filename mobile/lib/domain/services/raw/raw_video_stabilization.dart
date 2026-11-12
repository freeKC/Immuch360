// The stabilisation of a raw 360° video at playback (issue 14, lot c): the table of its motion track (see
// stabilization.dart) built in a background isolate while the video plays, then handed to the native player.
//
// The file is read where it is (on the device, on the server by range requests, through the media bridge of a share):
// its reader stays in this isolate, which serves the reads the background isolate asks for, so that the readers of
// the motion tracks run unchanged there and the decoding and the integration of a long recording never hold the UI.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/raw/stabilization.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_plan.dart';
import 'package:immich_mobile/domain/services/raw/stabilization.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart' show ByteRangeReader;
import 'package:immich_mobile/platform/spherical_video_api.g.dart';
import 'package:logging/logging.dart';

final _log = Logger('RawVideoStabilization');

/// Whether the raw videos of [kind] carry a motion track the app reads: the gyroscope of an Insta360, CORI and GRAV of
/// a GoPro, the attitude of a DJI Osmo 360
bool rawKindHasMotionTrack(RawMediaKind kind) => switch (kind) {
  RawMediaKind.insta360Video || RawMediaKind.goProVideo || RawMediaKind.djiVideo => true,
  RawMediaKind.insta360Photo => false,
};

/// What the table of a raw video needs besides its bytes, plain values that go to a background isolate
class RawStabilizationRequest {
  const RawStabilizationRequest({
    required this.kind,
    required this.name,
    required this.fileSize,
    this.downBody,
    this.frameDurationUs,
    this.goProFace,
    this.options = const StabilizationOptions(),
  });

  /// The request for the raw video of [plan], whose file holding the motion track is [fileSize] bytes long: the
  /// gravity its stitch levels with (an Insta360 calibration), and the frame duration of its first track, so that frame
  /// i of the table is at the presentation time the player gives it (constant frame rate, as these cameras record)
  factory RawStabilizationRequest.of(
    RawVideoPlan plan, {
    required String name,
    required int fileSize,
    StabilizationOptions options = const StabilizationOptions(),
  }) {
    final frameRate = plan.tracks.firstOrNull?.frameRate;
    return RawStabilizationRequest(
      kind: plan.kind,
      name: name,
      fileSize: fileSize,
      downBody: plan.kind == RawMediaKind.insta360Video ? plan.calibration?.downBody : null,
      frameDurationUs: frameRate != null && frameRate.isFinite && frameRate > 0 ? 1e6 / frameRate : null,
      goProFace: plan.kind == RawMediaKind.goProVideo ? plan.eac?.face : null,
      options: options,
    );
  }

  final RawMediaKind kind;

  /// The file, for the logs
  final String name;

  final int fileSize;

  /// The gravity the stitch of an Insta360 levels with, in its body frame (DualFisheyeCalibration.downBody); null for
  /// the other cameras, whose view frame is fixed
  final List<double>? downBody;

  /// Duration of a frame on the timeline of the video, in microseconds; null puts the frames at the times of the track
  final double? frameDurationUs;

  /// Side of the EAC faces of a GoPro .360 (1344 on the MAX, 1920 on the MAX 2); null for the other cameras
  final int? goProFace;

  /// The settings of the table: the phone's by default, [StabilizationOptions.headset] for the Meta Quest
  final StabilizationOptions options;

  @override
  String toString() =>
      'RawStabilizationRequest(${kind.name}, $name, $fileSize bytes, downBody: $downBody, '
      'frameDurationUs: $frameDurationUs${goProFace == null ? '' : ', goProFace: $goProFace'}, $options)';
}

/// Builds the table of a request from the reads of its file
typedef RawStabilizationBuilder =
    Future<StabilizationTable?> Function(RawStabilizationRequest request, ByteRangeReader read);

/// Side of the EAC faces of the one GoPro whose GPMF axes were measured against its picture, the MAX
/// ([goProViewToGpmf])
const goProMeasuredFace = 1344;

/// Reads the motion track of [request] with [read] and builds its table, in this isolate: the gyroscope of an
/// Insta360 integrated (readInsta360Stabilization), the orientations of a GoPro (readGoProStabilization) or of a DJI
/// (readDjiStabilization). Null when the file has no track, and for a GoPro whose faces are not those of the MAX: the
/// axes of the MAX 2 were not measured, its video could play rolled by 90 degrees (the switch hides).
Future<StabilizationTable?> buildRawStabilization(RawStabilizationRequest request, ByteRangeReader read) {
  final face = request.goProFace;
  if (request.kind == RawMediaKind.goProVideo && face != null && face != goProMeasuredFace) {
    _log.info('${request.name}: GoPro faces of $face pixels, axes not measured, no stabilisation table');
    return Future.value();
  }
  return switch (request.kind) {
    RawMediaKind.insta360Video => readInsta360Stabilization(
      read,
      request.fileSize,
      downBody: request.downBody,
      frameDurationUs: request.frameDurationUs,
      options: request.options,
    ),
    RawMediaKind.goProVideo => readGoProStabilization(
      read,
      request.fileSize,
      frameDurationUs: request.frameDurationUs,
      options: request.options,
    ),
    RawMediaKind.djiVideo => readDjiStabilization(
      read,
      request.fileSize,
      frameDurationUs: request.frameDurationUs,
      options: request.options,
    ),
    RawMediaKind.insta360Photo => Future.value(),
  };
}

/// [buildRawStabilization] in a background isolate, which asks this isolate for each read of [read]: the bytes come
/// back as transferable data, the table as the result of the isolate. A read that fails fails the build.
Future<StabilizationTable?> buildRawStabilizationInIsolate(
  RawStabilizationRequest request,
  ByteRangeReader read,
) async {
  final reads = ReceivePort('stabilization reads');
  reads.listen((message) async {
    final (int id, int offset, int length, SendPort reply) = message as (int, int, int, SendPort);
    try {
      final bytes = await read(offset, length);
      reply.send((id, TransferableTypedData.fromList([bytes]), null));
    } catch (error) {
      reply.send((id, null, '$error'));
    }
  });
  try {
    return await _spawn(request, reads.sendPort);
  } finally {
    reads.close();
  }
}

// Its own function, so that the closure sent to the isolate holds the request and the port only
Future<StabilizationTable?> _spawn(RawStabilizationRequest request, SendPort reads) =>
    Isolate.run(() => _buildWithRemoteReads(request, reads), debugName: 'stabilization');

// In the background isolate: the reads go to [reads], each with the port of the answers and its number
Future<StabilizationTable?> _buildWithRemoteReads(RawStabilizationRequest request, SendPort reads) async {
  final answers = ReceivePort('stabilization answers');
  final waiting = <int, Completer<Uint8List>>{};
  answers.listen((message) {
    final (int id, TransferableTypedData? data, String? error) = message as (int, TransferableTypedData?, String?);
    final completer = waiting.remove(id);
    if (completer == null) {
      return;
    }
    if (data != null) {
      completer.complete(data.materialize().asUint8List());
    } else {
      completer.completeError(StateError('read failed: $error'));
    }
  });
  var next = 0;
  Future<Uint8List> read(int offset, int length) {
    final id = next++;
    final completer = Completer<Uint8List>();
    waiting[id] = completer;
    reads.send((id, offset, length, answers.sendPort));
    return completer.future;
  }

  try {
    return await buildRawStabilization(request, read);
  } finally {
    answers.close();
  }
}

/// Whether the table of the raw video of [plan] can be built: its camera writes a track the app reads, in a file the
/// plan can open ([RawVideoPlan.motionTrackInput]) at any position (see [RawVideoInput.readsAnywhere]: not the stream
/// of a share without ranges, which would be read whole). Not for a GoPro whose EAC faces are not those of the MAX
/// ([goProMeasuredFace]): no table would come, so its switch never shows.
bool rawVideoHasReadableTrack(RawVideoPlan plan) {
  final input = plan.motionTrackInput;
  final face = plan.kind == RawMediaKind.goProVideo ? plan.eac?.face : null;
  return rawKindHasMotionTrack(plan.kind) &&
      input != null &&
      (face == null || face == goProMeasuredFace) &&
      (input.readsAnywhere?.call() ?? true);
}

/// The table of the raw video of [plan]: its file holding the motion track ([RawVideoPlan.motionTrackInput]) opened,
/// the table built by [build] (in a background isolate by default), the file closed. Null when the camera of the plan
/// writes no track the app reads, when that file cannot be opened, read at any position or its size is unknown, when it
/// has no track, when the build fails (the log tells why), or once [cancelled] says so: each read after it fails, which
/// ends the build. [options] are the settings of the table (the phone's by default).
Future<StabilizationTable?> stabilizationOfRawVideo(
  RawVideoPlan plan, {
  RawStabilizationBuilder build = buildRawStabilizationInIsolate,
  bool Function()? cancelled,
  StabilizationOptions options = const StabilizationOptions(),
}) async {
  final input = plan.motionTrackInput;
  if (input == null || !rawVideoHasReadableTrack(plan)) {
    return null;
  }
  RawFileReader? file;
  try {
    file = await input.open();
    final size = file?.size;
    if (file == null || size == null || size <= 0) {
      _log.info('${input.name}: no file to read the motion track from');
      return null;
    }
    final request = RawStabilizationRequest.of(plan, name: input.name, fileSize: size, options: options);
    final started = DateTime.now();
    final read = file.read;
    final table = await build(
      request,
      cancelled == null
          ? read
          : (offset, length) {
              if (cancelled()) {
                throw StateError('the player closed');
              }
              return read(offset, length);
            },
    );
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    _log.info(table == null ? '${input.name}: no motion track ($elapsed ms)' : '${input.name}: $table in $elapsed ms');
    return table;
  } catch (error, stackTrace) {
    _log.warning('${input.name}: the stabilisation table could not be built', error, stackTrace);
    return null;
  } finally {
    try {
      await file?.close();
    } catch (error) {
      _log.fine('${input.name}: could not close the file: $error');
    }
  }
}

/// How a player is told about the stabilisation of a video: SphericalVideoApi.setStabilization for the phone's 360°
/// player, ImmersiveApi.setStabilization for the immersive viewer of the Meta Quest (same arguments)
typedef StabilizationSender =
    Future<void> Function(
      String url,
      bool enabled,
      bool hasTrack,
      Int64List? presentationTimesUs,
      Float64List? corrections,
      String? summary,
    );

/// Tells the native player at [url] about the stabilisation of the raw video of [plan] (see
/// [SphericalVideoApi.setStabilization]), the setting [enabled]: [announce] right before the player opens (the switch
/// shows while the track is read), then [deliver] the table once [build] made it, or that the file has none. A failure
/// to tell the player never stops the playback: the log keeps it. The phone's player through [api]; another player
/// (the immersive viewer of the Meta Quest) through [send], with its own [options].
class RawVideoStabilizer {
  RawVideoStabilizer({
    SphericalVideoApi? api,
    StabilizationSender? send,
    required this.url,
    required this.enabled,
    required this.plan,
    this.build = buildRawStabilizationInIsolate,
    this.options = const StabilizationOptions(),
  }) : assert(api != null || send != null, 'a player to tell'),
       send = send ?? _senderOf(api!);

  /// Where the messages go
  final StabilizationSender send;

  /// The settings of the table
  final StabilizationOptions options;
  final String url;
  final bool enabled;
  final RawVideoPlan plan;
  final RawStabilizationBuilder build;

  /// Whether the camera of [plan] writes a track the app reads, in a file the plan can open at any position (see
  /// [rawVideoHasReadableTrack])
  bool get applies => rawVideoHasReadableTrack(plan);

  bool _cancelled = false;

  /// Whether [cancel] was called
  bool get cancelled => _cancelled;

  /// The player is about to open: its switch shows while the track is read
  Future<void> announce() => _send(hasTrack: true);

  /// The player closed: the build stops at its next read, and nothing more is sent
  void cancel() {
    if (!_cancelled) {
      _cancelled = true;
      _log.fine('$url: the player closed, the stabilisation table is no longer built');
    }
  }

  /// Builds the table and hands it to the player, or tells it the file has none; completes once told. Null without
  /// telling once [cancel] was called.
  Future<StabilizationTable?> deliver() async {
    final table = await stabilizationOfRawVideo(plan, build: build, cancelled: () => _cancelled, options: options);
    if (_cancelled) {
      return null;
    }
    await _send(hasTrack: table != null && !table.isEmpty, table: table);
    return table;
  }

  Future<void> _send({required bool hasTrack, StabilizationTable? table}) =>
      _tell(send, url, enabled: enabled, hasTrack: hasTrack, table: table);
}

// The phone's player: the API looked up at each call, so that a test's mock answers as stubbed then
StabilizationSender _senderOf(SphericalVideoApi api) =>
    (url, enabled, hasTrack, presentationTimesUs, corrections, summary) =>
        api.setStabilization(url, enabled, hasTrack, presentationTimesUs, corrections, summary);

/// Tells the native player at [url] the stabilisation setting [enabled] for a video Flutter builds no table for, right
/// before it opens: a plain 360° video, whose CAMM track (if any) Media3 applies itself, or a raw video without a
/// track the app reads. The switch of the player starts at the setting, and off keeps a CAMM track off: off means the
/// raw video for every file. A failure to tell the player never stops the playback: the log keeps it.
Future<void> tellStabilizationSetting(SphericalVideoApi api, String url, {required bool enabled}) =>
    _tell(_senderOf(api), url, enabled: enabled, hasTrack: false);

/// [tellStabilizationSetting] through [send]: the immersive viewer of the Meta Quest, for a video Flutter builds no
/// table for (the switch hides, and a message of an earlier opening of the same URL is replaced)
Future<void> tellStabilizationSettingWith(StabilizationSender send, String url, {required bool enabled}) =>
    _tell(send, url, enabled: enabled, hasTrack: false);

Future<void> _tell(
  StabilizationSender send,
  String url, {
  required bool enabled,
  required bool hasTrack,
  StabilizationTable? table,
}) async {
  try {
    final corrections = table == null ? null : Float64List.fromList(table.corrections);
    await send(
      url,
      enabled,
      hasTrack,
      hasTrack ? table?.presentationTimesUs : null,
      hasTrack ? corrections : null,
      table?.summary.toString(),
    );
  } catch (error, stackTrace) {
    _log.warning('Could not tell the 360° player about the stabilisation', error, stackTrace);
  }
}
