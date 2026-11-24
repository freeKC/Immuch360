// The files of a 3D video job (store/m2/release-49/lots/video3d-plan.md, section 4.5), in its work folder
// .immuch360-work-<id> beside the destination: job.json (the source as it was, every setting, the segments done with
// their sums), pts.txt (the time of each decoded frame, one line each, appended), seg-NNNN.seg (the Matroska segments)
// and state-NNNN.bin (what the window loop holds at the end of segment NNNN: the 8 held maps, ref, the key inputs, the
// smoothed percentiles, the scene's start and the cut detector). A paused, crashed or closed job resumes from its last
// segment; a source changed since (size, time, the sums of its first and last 4 MiB) cannot. Once every frame is in a
// segment, job.json says so ([VideoJobEncoded]) and the states go: a job stopped during the final mux goes straight
// back to the mux. Only the state of the last segment is kept while the job runs, and the folder goes once the MP4 is
// in place.
//
// Pure Dart and dart:io, no Flutter.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:immich_mobile/desktop/ai/video3d/vda_window_loop.dart';
import 'package:path/path.dart' as p;

/// The version of job.json and of the state files this build writes and reads
const videoJobVersion = 1;

/// The prefix of the work folder of a 3D video job, beside its destination
const videoWorkPrefix = '.immuch360-work-';

/// The bytes read at each end of a source for its identity
const videoIdentityBytes = 4 * 1024 * 1024;

/// What identifies a source: its size, its modification time and the SHA-1 of its first and last 4 MiB
class VideoSourceIdentity {
  const VideoSourceIdentity({
    required this.size,
    required this.modified,
    required this.headSha1,
    required this.tailSha1,
  });

  final int size;
  final DateTime modified;
  final String headSha1;
  final String tailSha1;

  static Future<VideoSourceIdentity> of(File file) async {
    final stat = file.statSync();
    final reader = await file.open();
    try {
      final head = await reader.read(videoIdentityBytes);
      await reader.setPosition(stat.size > videoIdentityBytes ? stat.size - videoIdentityBytes : 0);
      final tail = await reader.read(videoIdentityBytes);
      return VideoSourceIdentity(
        size: stat.size,
        modified: stat.modified.toUtc(),
        headSha1: crypto.sha1.convert(head).toString(),
        tailSha1: crypto.sha1.convert(tail).toString(),
      );
    } finally {
      await reader.close();
    }
  }

  Map<String, Object> toJson() => {
    'size': size,
    'modified': modified.toUtc().toIso8601String(),
    'headSha1': headSha1,
    'tailSha1': tailSha1,
  };

  static VideoSourceIdentity fromJson(Map<String, Object?> json) => VideoSourceIdentity(
    size: json['size']! as int,
    modified: DateTime.parse(json['modified']! as String),
    headSha1: json['headSha1']! as String,
    tailSha1: json['tailSha1']! as String,
  );

  @override
  bool operator ==(Object other) =>
      other is VideoSourceIdentity &&
      other.size == size &&
      other.modified.millisecondsSinceEpoch == modified.millisecondsSinceEpoch &&
      other.headSha1 == headSha1 &&
      other.tailSha1 == tailSha1;

  @override
  int get hashCode => Object.hash(size, headSha1, tailSha1);
}

/// A segment written: its file, the frames it holds (video indices, last excluded), the slots of the grid it fills,
/// its bytes and its SHA-256
class VideoSegment {
  const VideoSegment({
    required this.index,
    required this.name,
    required this.firstFrame,
    required this.endFrame,
    required this.slots,
    required this.bytes,
    required this.sha256,
  });

  final int index;
  final String name;
  final int firstFrame;
  final int endFrame;
  final int slots;
  final int bytes;
  final String sha256;

  Map<String, Object> toJson() => {
    'index': index,
    'name': name,
    'firstFrame': firstFrame,
    'endFrame': endFrame,
    'slots': slots,
    'bytes': bytes,
    'sha256': sha256,
  };

  static VideoSegment fromJson(Map<String, Object?> json) => VideoSegment(
    index: json['index']! as int,
    name: json['name']! as String,
    firstFrame: json['firstFrame']! as int,
    endFrame: json['endFrame']! as int,
    slots: json['slots']! as int,
    bytes: json['bytes']! as int,
    sha256: json['sha256']! as String,
  );

  /// The name of the segment [index]
  static String nameOf(int index) => 'seg-${index.toString().padLeft(4, '0')}.seg';

  /// The name of the state written with the segment [index]
  static String stateNameOf(int index) => 'state-${index.toString().padLeft(4, '0')}.bin';
}

/// Every frame of the job is in a segment: what the final mux and the result need, written before the mux starts
class VideoJobEncoded {
  const VideoJobEncoded({
    required this.frames,
    required this.firstTime,
    required this.windows,
    required this.cuts,
    required this.holesMean,
  });

  /// Frames decoded and given a depth
  final int frames;

  /// The time of the first frame in the source, seconds (the offset of the video at the mux)
  final double firstTime;
  final int windows;
  final List<int> cuts;
  final double holesMean;

  Map<String, Object> toJson() => {
    'frames': frames,
    'firstTime': firstTime,
    'windows': windows,
    'cuts': cuts,
    'holesMean': holesMean,
  };

  static VideoJobEncoded fromJson(Map<String, Object?> json) => VideoJobEncoded(
    frames: json['frames']! as int,
    firstTime: (json['firstTime']! as num).toDouble(),
    windows: json['windows']! as int,
    cuts: (json['cuts']! as List).cast<int>(),
    holesMean: (json['holesMean']! as num).toDouble(),
  );
}

/// job.json: the source, the settings (free JSON values the engine writes and reads back), the segments done, and once
/// every frame is encoded, [encoded]
class VideoJobFile {
  VideoJobFile({
    required this.id,
    required this.sourcePath,
    required this.identity,
    required this.outputPath,
    required this.settings,
    List<VideoSegment>? segments,
    this.encoded,
    this.finished = false,
  }) : segments = segments ?? [];

  final String id;
  final String sourcePath;
  final VideoSourceIdentity identity;
  final String outputPath;
  final Map<String, Object?> settings;
  final List<VideoSegment> segments;

  /// Set when the last segment is written: the job only needs its final mux
  VideoJobEncoded? encoded;
  bool finished;

  Map<String, Object?> toJson() => {
    'version': videoJobVersion,
    'id': id,
    'source': sourcePath,
    'identity': identity.toJson(),
    'output': outputPath,
    'settings': settings,
    'segments': [for (final segment in segments) segment.toJson()],
    if (encoded != null) 'encoded': encoded!.toJson(),
    'finished': finished,
  };

  /// The job of [json], null for another version or a damaged file
  static VideoJobFile? fromJson(Object? json) {
    if (json is! Map<String, Object?> || json['version'] != videoJobVersion) {
      return null;
    }
    try {
      return VideoJobFile(
        id: json['id']! as String,
        sourcePath: json['source']! as String,
        identity: VideoSourceIdentity.fromJson((json['identity']! as Map).cast<String, Object?>()),
        outputPath: json['output']! as String,
        settings: (json['settings']! as Map).cast<String, Object?>(),
        segments: [
          for (final segment in json['segments']! as List)
            VideoSegment.fromJson((segment as Map).cast<String, Object?>()),
        ],
        encoded: json['encoded'] is Map
            ? VideoJobEncoded.fromJson((json['encoded']! as Map).cast<String, Object?>())
            : null,
        finished: json['finished'] == true,
      );
    } on Object {
      return null;
    }
  }

  /// Written to [folder]/job.json through a temporary file, so that a crash leaves the old one or the new one
  Future<void> write(Directory folder) async {
    final target = File(p.join(folder.path, 'job.json'));
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(const JsonEncoder.withIndent(' ').convert(toJson()), flush: true);
    await temporary.rename(target.path);
  }

  static Future<VideoJobFile?> read(Directory folder) async {
    final file = File(p.join(folder.path, 'job.json'));
    if (!file.existsSync()) {
      return null;
    }
    try {
      return fromJson(jsonDecode(await file.readAsString()));
    } on FormatException {
      return null;
    }
  }
}

const _stateMagic = 0x53563349; // "I3VS"

/// The state of the window loop as bytes: "I3VS", the version, the length of a JSON header, the header (the numbers and
/// the shapes), then the held maps and ref (float64), the key inputs (float32) and the last histogram (float64); for a
/// 360° video then the alignment of the faces (float64) and the state of each face, each encoded the same way
Uint8List encodeVdaLoopState(VdaLoopState state) {
  // The faces of a 360° video, each a state of its own after the rest
  final viewBytes = [for (final view in state.views) encodeVdaLoopState(view)];
  final header = utf8.encode(
    jsonEncode({
      'nextIndex': state.nextIndex,
      'sceneStart': state.sceneStart,
      'sceneFrames': state.sceneFrames,
      'windows': state.windows,
      'firstHeld': state.firstHeld,
      'lo': state.lo,
      'hi': state.hi,
      'distances': state.distances,
      'resets': state.resets.toList()..sort(),
      'held': [for (final map in state.held) map.length],
      'ref': [for (final map in state.ref) map.length],
      'keyInputs': [for (final input in state.keyInputs) input.length],
      'histogram': state.previousHistogram?.length,
      if (state.alignment != null) 'alignment': state.alignment!.length,
      if (state.views.isNotEmpty) 'views': [for (final view in viewBytes) view.length],
    }),
  );
  final builder = BytesBuilder(copy: false);
  final head = ByteData(12)
    ..setUint32(0, _stateMagic, Endian.little)
    ..setUint32(4, videoJobVersion, Endian.little)
    ..setUint32(8, header.length, Endian.little);
  builder
    ..add(head.buffer.asUint8List())
    ..add(header);
  void add(TypedData data) => builder.add(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  // Little endian on every computer the app runs on
  for (final map in [...state.held, ...state.ref]) {
    add(map);
  }
  for (final input in state.keyInputs) {
    add(input);
  }
  if (state.previousHistogram != null) {
    add(state.previousHistogram!);
  }
  if (state.alignment != null) {
    add(state.alignment!);
  }
  for (final view in viewBytes) {
    builder.add(view);
  }
  return builder.takeBytes();
}

/// The state of [bytes], null for another format or version, or bytes cut short
VdaLoopState? decodeVdaLoopState(Uint8List bytes) {
  if (bytes.length < 12) {
    return null;
  }
  final head = ByteData.sublistView(bytes, 0, 12);
  if (head.getUint32(0, Endian.little) != _stateMagic || head.getUint32(4, Endian.little) != videoJobVersion) {
    return null;
  }
  final headerLength = head.getUint32(8, Endian.little);
  try {
    final header = jsonDecode(utf8.decode(bytes.sublist(12, 12 + headerLength))) as Map<String, Object?>;
    var at = 12 + headerLength;
    Float64List doubles(int count) {
      final out = Float64List(count);
      out.buffer.asUint8List().setAll(0, bytes.sublist(at, at + count * 8));
      at += count * 8;
      return out;
    }

    Float32List floats(int count) {
      final out = Float32List(count);
      out.buffer.asUint8List().setAll(0, bytes.sublist(at, at + count * 4));
      at += count * 4;
      return out;
    }

    final held = [for (final count in (header['held']! as List).cast<int>()) doubles(count)];
    final ref = [for (final count in (header['ref']! as List).cast<int>()) doubles(count)];
    final keyInputs = [for (final count in (header['keyInputs']! as List).cast<int>()) floats(count)];
    final histogramLength = header['histogram'] as int?;
    final histogram = histogramLength == null ? null : doubles(histogramLength);
    final alignmentLength = header['alignment'] as int?;
    final alignment = alignmentLength == null ? null : doubles(alignmentLength);
    final views = <VdaLoopState>[];
    for (final length in ((header['views'] as List?) ?? const []).cast<int>()) {
      final view = decodeVdaLoopState(Uint8List.sublistView(bytes, at, at + length));
      if (view == null) {
        return null;
      }
      views.add(view);
      at += length;
    }
    if (at != bytes.length) {
      return null;
    }
    return VdaLoopState(
      nextIndex: header['nextIndex']! as int,
      sceneStart: header['sceneStart']! as int,
      sceneFrames: header['sceneFrames']! as int,
      windows: header['windows']! as int,
      held: held,
      ref: ref,
      keyInputs: keyInputs,
      lo: (header['lo'] as num?)?.toDouble(),
      hi: (header['hi'] as num?)?.toDouble(),
      previousHistogram: histogram,
      distances: [for (final distance in header['distances']! as List) (distance as num).toDouble()],
      firstHeld: header['firstHeld']! as int,
      resets: {...(header['resets']! as List).cast<int>()},
      views: views,
      alignment: alignment,
    );
  } on Object {
    return null;
  }
}

/// The SHA-256 of [file], read in pieces
Future<String> sha256OfFile(File file) async => (await crypto.sha256.bind(file.openRead()).first).toString();

/// About the bytes of one state file for a model input of [modelWidth] x [modelHeight]: the 8 held maps and the 2 of
/// ref in float64, the 10 key inputs of 3 planes in float32 (55 MB at 700 x 392); the header and the histogram aside
int videoStateBytes(int modelWidth, int modelHeight) =>
    (vdaBlended + 2) * 8 * modelWidth * modelHeight + vdaKeyFrames.length * 3 * 4 * modelWidth * modelHeight;
