// The dart:ffi binding of src/ht_api.h: the structures and the functions of immuch_head_tracker.dll, one to one. The
// sessions on top of it are in head_tracker.dart.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'package:immuch_head_tracker/src/head_camera.dart';
import 'package:immuch_head_tracker/src/head_sample.dart';

/// The version of ht_api.h this binding was written for (HT_API_VERSION)
const headTrackerApiVersion = 2;

final class HtOptions extends Struct {
  @Int32()
  external int detector;
  @Int32()
  external int detectEvery;
  @Int32()
  external int minScore;
  @Int32()
  external int detectLongSide;
  @Int32()
  external int width;
  @Int32()
  external int height;
  @Int32()
  external int fps;

  /// HT_FLAG_*
  @Int32()
  external int flags;
}

final class HtSample extends Struct {
  @Int64()
  external int timeUs;
  @Int64()
  external int sequence;
  @Double()
  external double faceX;
  @Double()
  external double faceY;
  @Double()
  external double faceWidth;
  @Double()
  external double faceHeight;
  @Double()
  external double confidence;
  @Int32()
  external int state;
  @Int32()
  external int detectUs;
  @Int32()
  external int frameWidth;
  @Int32()
  external int frameHeight;
  @Int32()
  external int status;
  @Int32()
  external int faces;
}

final class HtInfo extends Struct {
  @Int32()
  external int detector;
  @Int32()
  external int framing;
  @Int32()
  external int width;
  @Int32()
  external int height;
  @Int32()
  external int fpsNumerator;
  @Int32()
  external int fpsDenominator;
  @Uint32()
  external int nativeFourcc;
  @Int32()
  external int hresult;
}

/// The callback of a camera: the sequence of the newest sample and the status (an error stops the camera)
typedef HtSampleCallbackNative = Void Function(Int64 sequence, Int32 status);

typedef _VersionNative = Int32 Function();
typedef _Version = int Function();
typedef _NowNative = Int64 Function();
typedef _Now = int Function();
typedef _ListNative = Int32 Function(Pointer<Uint8> json, Int32 capacity);
typedef _List = int Function(Pointer<Uint8> json, int capacity);
typedef _OpenCameraNative =
    Pointer<Void> Function(
      Pointer<Utf8> id,
      Pointer<HtOptions> options,
      Pointer<NativeFunction<HtSampleCallbackNative>> callback,
      Pointer<Int32> status,
    );
typedef _OpenCamera =
    Pointer<Void> Function(
      Pointer<Utf8> id,
      Pointer<HtOptions> options,
      Pointer<NativeFunction<HtSampleCallbackNative>> callback,
      Pointer<Int32> status,
    );
typedef _OpenFileNative = Pointer<Void> Function(Pointer<Utf8> path, Pointer<HtOptions> options, Pointer<Int32> status);
typedef _OpenFile = Pointer<Void> Function(Pointer<Utf8> path, Pointer<HtOptions> options, Pointer<Int32> status);
typedef _OpenFramesNative = Pointer<Void> Function(Pointer<HtOptions> options, Pointer<Int32> status);
typedef _OpenFrames = Pointer<Void> Function(Pointer<HtOptions> options, Pointer<Int32> status);
typedef _NextNative = Int32 Function(Pointer<Void> tracker, Pointer<HtSample> sample);
typedef _Next = int Function(Pointer<Void> tracker, Pointer<HtSample> sample);
typedef _ProcessNative =
    Int32 Function(
      Pointer<Void> tracker,
      Pointer<Uint8> grey,
      Int32 width,
      Int32 height,
      Int32 stride,
      Int64 timeNs,
      Pointer<HtSample> sample,
    );
typedef _Process =
    int Function(
      Pointer<Void> tracker,
      Pointer<Uint8> grey,
      int width,
      int height,
      int stride,
      int timeNs,
      Pointer<HtSample> sample,
    );
typedef _InfoNative = Int32 Function(Pointer<Void> tracker, Pointer<HtInfo> info);
typedef _Info = int Function(Pointer<Void> tracker, Pointer<HtInfo> info);
typedef _CloseNative = Void Function(Pointer<Void> tracker);
typedef _Close = void Function(Pointer<Void> tracker);

/// The functions of the tracker's library. [library] is the DLL's path, its name next to the executable by default
/// (the tests give the build folder, or on Linux a gcc build of test_native).
class NativeHeadTracker {
  NativeHeadTracker([String? library])
    : this._(DynamicLibrary.open(library ?? defaultLibrary), library ?? defaultLibrary);

  NativeHeadTracker._(DynamicLibrary dll, this.path)
    : _version = dll.lookupFunction<_VersionNative, _Version>('ht_api_version'),
      _now = dll.lookupFunction<_NowNative, _Now>('ht_now_us'),
      _cpuAvx2 = dll.lookupFunction<_VersionNative, _Version>('ht_cpu_avx2'),
      _list = dll.lookupFunction<_ListNative, _List>('ht_list_cameras'),
      _openCamera = dll.lookupFunction<_OpenCameraNative, _OpenCamera>('ht_open_camera'),
      _openFile = dll.lookupFunction<_OpenFileNative, _OpenFile>('ht_open_file'),
      _openFrames = dll.lookupFunction<_OpenFramesNative, _OpenFrames>('ht_open_frames'),
      _next = dll.lookupFunction<_NextNative, _Next>('ht_next'),
      _process = dll.lookupFunction<_ProcessNative, _Process>('ht_process_frame'),
      _latest = dll.lookupFunction<_NextNative, _Next>('ht_latest'),
      _info = dll.lookupFunction<_InfoNative, _Info>('ht_info'),
      _close = dll.lookupFunction<_CloseNative, _Close>('ht_close') {
    final version = _version();
    if (version != headTrackerApiVersion) {
      throw StateError('$path has the interface version $version, this binding $headTrackerApiVersion');
    }
  }

  /// The DLL Flutter bundles next to the executable
  static String get defaultLibrary => Platform.isWindows ? 'immuch_head_tracker.dll' : 'libimmuch_head_tracker.so';

  final String path;
  final _Version _version;
  final _Now _now;
  final _Version _cpuAvx2;
  final _List _list;
  final _OpenCamera _openCamera;
  final _OpenFile _openFile;
  final _OpenFrames _openFrames;
  final _Next _next;
  final _Process _process;
  final _Next _latest;
  final _Info _info;
  final _Close _close;

  int nowUs() => _now();

  bool get cpuAvx2 => _cpuAvx2() == 1;

  /// The cameras; blocks for as long as Media Foundation takes to list them (call it off the UI isolate)
  List<HeadCamera> listCameras() {
    var capacity = 16 * 1024;
    while (true) {
      final out = calloc<Uint8>(capacity);
      try {
        final length = _list(out, capacity);
        if (length < 0) {
          throw HeadTrackerException.fromStatus(length);
        }
        if (length <= capacity) {
          return parseHeadCameras(utf8.decode(out.asTypedList(length), allowMalformed: true));
        }
        capacity = length;
      } finally {
        calloc.free(out);
      }
    }
  }

  /// Starts a camera; [callback] is the native function of a NativeCallable.listener
  Pointer<Void> openCamera(
    String id,
    HeadTrackerOptions options,
    Pointer<NativeFunction<HtSampleCallbackNative>> callback,
  ) => _withOptions(options, (nativeOptions, status) {
    final text = id.toNativeUtf8(allocator: calloc);
    try {
      return _openCamera(text, nativeOptions, callback, status);
    } finally {
      calloc.free(text);
    }
  });

  Pointer<Void> openFile(String path, HeadTrackerOptions options) => _withOptions(options, (nativeOptions, status) {
    final text = path.toNativeUtf8(allocator: calloc);
    try {
      return _openFile(text, nativeOptions, status);
    } finally {
      calloc.free(text);
    }
  });

  Pointer<Void> openFrames(HeadTrackerOptions options) =>
      _withOptions(options, (nativeOptions, status) => _openFrames(nativeOptions, status));

  /// The next analysed frame of a file, null at its end
  HeadSample? next(Pointer<Void> tracker) => _withSample((sample) {
    final result = _next(tracker, sample);
    if (result < 0) {
      throw HeadTrackerException.fromStatus(result, hresult: info(tracker).hresult);
    }
    return result == 1;
  });

  /// Analyses one grey frame (or the luma plane of a YUV frame) given in [grey] at [timeNs]
  HeadSample processFrame(Pointer<Void> tracker, Pointer<Uint8> grey, int width, int height, int stride, int timeNs) =>
      _withSample((sample) {
        final result = _process(tracker, grey, width, height, stride, timeNs, sample);
        if (result < 0) {
          throw HeadTrackerException.fromStatus(result);
        }
        return true;
      })!;

  /// The newest sample of a tracker, null before the first. [status] of the sample is kept: an error of a camera
  /// arrives as a sample whose status is negative.
  ({HeadSample sample, int status})? latest(Pointer<Void> tracker) {
    final sample = calloc<HtSample>();
    try {
      if (_latest(tracker, sample) != 1) {
        return null;
      }
      return (sample: sampleOf(sample.ref), status: sample.ref.status);
    } finally {
      calloc.free(sample);
    }
  }

  HeadTrackerInfo info(Pointer<Void> tracker) {
    final info = calloc<HtInfo>();
    try {
      _info(tracker, info);
      final fourcc = info.ref.nativeFourcc;
      return HeadTrackerInfo(
        detector: info.ref.detector == 2 ? FaceDetectorBuild.avx2 : FaceDetectorBuild.plain,
        framing: AutoFramingState.values[info.ref.framing.clamp(0, AutoFramingState.values.length - 1)],
        width: info.ref.width,
        height: info.ref.height,
        fpsNumerator: info.ref.fpsNumerator,
        fpsDenominator: info.ref.fpsDenominator,
        nativeFourcc: fourccText(fourcc),
        hresult: info.ref.hresult,
      );
    } finally {
      calloc.free(info);
    }
  }

  /// Stops and frees a tracker; for a camera, blocks until the camera is released (call it off the UI isolate)
  void close(Pointer<Void> tracker) => _close(tracker);

  Pointer<Void> _withOptions(
    HeadTrackerOptions options,
    Pointer<Void> Function(Pointer<HtOptions> options, Pointer<Int32> status) open,
  ) {
    final nativeOptions = calloc<HtOptions>();
    final status = calloc<Int32>();
    try {
      nativeOptions.ref
        ..detector = options.detector.index
        ..detectEvery = options.detectEvery
        ..minScore = options.minScore
        ..detectLongSide = options.detectLongSide
        ..width = options.width
        ..height = options.height
        ..fps = options.fps
        ..flags = options.colourOnly ? HeadTrackerOptions.colourOnlyFlag : 0;
      final tracker = open(nativeOptions, status);
      if (tracker == nullptr) {
        throw HeadTrackerException.fromStatus(status.value == 0 ? HeadTrackerStatus.failed : status.value);
      }
      return tracker;
    } finally {
      calloc.free(nativeOptions);
      calloc.free(status);
    }
  }

  static HeadSample? _withSample(bool Function(Pointer<HtSample> sample) read) {
    final sample = calloc<HtSample>();
    try {
      return read(sample) ? sampleOf(sample.ref) : null;
    } finally {
      calloc.free(sample);
    }
  }
}

/// The Dart sample of a native one
HeadSample sampleOf(HtSample sample) => HeadSample(
  timeUs: sample.timeUs,
  sequence: sample.sequence,
  faceX: sample.faceX,
  faceY: sample.faceY,
  faceWidth: sample.faceWidth,
  faceHeight: sample.faceHeight,
  confidence: sample.confidence,
  state: switch (sample.state) {
    1 => HeadFaceState.face,
    3 => HeadFaceState.lost,
    _ => HeadFaceState.noFace,
  },
  detectUs: sample.detectUs,
  frameWidth: sample.frameWidth,
  frameHeight: sample.frameHeight,
  faces: sample.faces,
);

/// "NV12" for the FOURCC of MFVideoFormat_NV12 (its Data1, the characters in little endian order); the subtypes
/// that are not FOURCC codes (RGB32 is 22, for one) as a number
String fourccText(int fourcc) {
  if (fourcc == 0) {
    return '';
  }
  final codes = [for (var shift = 0; shift < 32; shift += 8) (fourcc >> shift) & 0xFF];
  if (codes.every((code) => code >= 0x20 && code < 0x7F)) {
    return String.fromCharCodes(codes).trimRight();
  }
  return fourcc.toString();
}
