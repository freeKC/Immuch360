// The dart:ffi binding of src/ht_api.h: the structures and the functions of the tracker's library, one to one. The
// sessions on top of it are in head_tracker.dart.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'package:immuch_head_tracker/src/head_camera.dart';
import 'package:immuch_head_tracker/src/head_sample.dart';

/// The version of ht_api.h this binding was written for (HT_API_VERSION)
const headTrackerApiVersion = 3;

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
  @Double()
  external double eyeX;
  @Double()
  external double eyeY;
  @Double()
  external double eyeDistance;
  @Double()
  external double headX;
  @Double()
  external double filteredX;
  @Double()
  external double velocityX;
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
  @Int32()
  external int detectWidth;
  @Int32()
  external int reserved;
}

final class HtFace extends Struct {
  @Int32()
  external int score;
  @Int32()
  external int reserved;
  @Double()
  external double eyeX;
  @Double()
  external double eyeY;
  @Double()
  external double eyeDistance;
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
typedef _OpenCameraNative = Pointer<Void> Function(
  Pointer<Utf8> id,
  Pointer<HtOptions> options,
  Pointer<NativeFunction<HtSampleCallbackNative>> callback,
  Pointer<Int32> status,
);
typedef _OpenCamera = Pointer<Void> Function(
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
typedef _ProcessNative = Int32 Function(
  Pointer<Void> tracker,
  Pointer<Uint8> grey,
  Int32 width,
  Int32 height,
  Int32 stride,
  Int64 timeNs,
  Pointer<HtSample> sample,
);
typedef _Process = int Function(
  Pointer<Void> tracker,
  Pointer<Uint8> grey,
  int width,
  int height,
  int stride,
  int timeNs,
  Pointer<HtSample> sample,
);
typedef _LandmarksNative = Int32 Function(
  Pointer<Void> tracker,
  Pointer<HtFace> faces,
  Int32 count,
  Int64 timeNs,
  Pointer<HtSample> sample,
);
typedef _Landmarks = int Function(
  Pointer<Void> tracker,
  Pointer<HtFace> faces,
  int count,
  int timeNs,
  Pointer<HtSample> sample,
);
typedef _PredictNative = Int32 Function(Pointer<Void> tracker, Int64 nowUs, Pointer<Double> headX);
typedef _Predict = int Function(Pointer<Void> tracker, int nowUs, Pointer<Double> headX);
typedef _RecenterNative = Int32 Function(Pointer<Void> tracker);
typedef _Recenter = int Function(Pointer<Void> tracker);
typedef _InfoNative = Int32 Function(Pointer<Void> tracker, Pointer<HtInfo> info);
typedef _Info = int Function(Pointer<Void> tracker, Pointer<HtInfo> info);
typedef _CloseNative = Void Function(Pointer<Void> tracker);
typedef _Close = void Function(Pointer<Void> tracker);

/// ht_api_version of the macOS code asset of hook/build.dart, only for finding its file
@Native<_VersionNative>(symbol: 'ht_api_version', assetId: 'package:immuch_head_tracker/immuch_head_tracker.dart')
external int _assetApiVersion();

/// Dl_info of <dlfcn.h>
final class _DlInfo extends Struct {
  external Pointer<Utf8> fileName;
  external Pointer<Void> fileBase;
  external Pointer<Utf8> symbolName;
  external Pointer<Void> symbolAddress;
}

/// The functions of the tracker's library. [library] is its path, the app's own library by default (the tests give a
/// build folder, or on Linux a gcc build of test_native).
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
      _landmarks = dll.lookupFunction<_LandmarksNative, _Landmarks>('ht_process_landmarks'),
      _predict = dll.lookupFunction<_PredictNative, _Predict>('ht_predict'),
      _recenter = dll.lookupFunction<_RecenterNative, _Recenter>('ht_recenter'),
      _latest = dll.lookupFunction<_NextNative, _Next>('ht_latest'),
      _info = dll.lookupFunction<_InfoNative, _Info>('ht_info'),
      _close = dll.lookupFunction<_CloseNative, _Close>('ht_close') {
    final version = _version();
    if (version != headTrackerApiVersion) {
      throw StateError('$path has the interface version $version, this binding $headTrackerApiVersion');
    }
  }

  /// The app's library: the DLL next to the executable on Windows, the .so of the bundle's lib folder on Linux (found
  /// through the executable's run path); on macOS the code asset of the build hook, wherever Flutter put it (the
  /// framework inside the app, or the build folder of a test run), found by its own address
  static String get defaultLibrary {
    if (Platform.isWindows) {
      return 'immuch_head_tracker.dll';
    }
    if (Platform.isMacOS) {
      return macosAssetPath() ?? '@executable_path/../Frameworks/immuch_head_tracker.framework/immuch_head_tracker';
    }
    return 'libimmuch_head_tracker.so';
  }

  /// The file of the macOS code asset: the address of one of its functions, resolved by the Dart runtime, then dladdr
  /// for the image that holds it. Null when the asset is not there.
  static String? macosAssetPath() {
    try {
      final address = Native.addressOf<NativeFunction<_VersionNative>>(_assetApiVersion);
      final dladdr = DynamicLibrary.process()
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<_DlInfo>),
            int Function(Pointer<Void>, Pointer<_DlInfo>)
          >('dladdr');
      final info = calloc<_DlInfo>();
      try {
        if (dladdr(address.cast(), info) == 0 || info.ref.fileName == nullptr) {
          return null;
        }
        return info.ref.fileName.toDartString();
      } finally {
        calloc.free(info);
      }
    } catch (_) {
      return null;
    }
  }

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
  final _Landmarks _landmarks;
  final _Predict _predict;
  final _Recenter _recenter;
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

  /// Analyses the faces of one frame given as landmarks (a track line) at [timeNs]
  HeadSample processLandmarks(Pointer<Void> tracker, List<HeadLandmarks> faces, int timeNs) {
    final native = calloc<HtFace>(faces.isEmpty ? 1 : faces.length);
    try {
      for (var i = 0; i < faces.length; i++) {
        native[i]
          ..score = faces[i].score
          ..eyeX = faces[i].eyeX
          ..eyeY = faces[i].eyeY
          ..eyeDistance = faces[i].eyeDistance;
      }
      return _withSample((sample) {
        final result = _landmarks(tracker, native, faces.length, timeNs, sample);
        if (result < 0) {
          throw HeadTrackerException.fromStatus(result);
        }
        return true;
      })!;
    } finally {
      calloc.free(native);
    }
  }

  /// The head position at [nowUs] from the newest sample, moved on by its speed (ht_predict); null without a face
  double? predict(Pointer<Void> tracker, int nowUs) {
    final out = calloc<Double>();
    try {
      return _predict(tracker, nowUs, out) == 1 ? out.value : null;
    } finally {
      calloc.free(out);
    }
  }

  /// The next frame takes the largest face again and the filter starts afresh
  void recenter(Pointer<Void> tracker) => _recenter(tracker);

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
        detector: switch (info.ref.detector) {
          2 => FaceDetectorBuild.avx2,
          3 => FaceDetectorBuild.neon,
          _ => FaceDetectorBuild.plain,
        },
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
  eyeX: sample.eyeX,
  eyeY: sample.eyeY,
  eyeDistance: sample.eyeDistance,
  headPosition: sample.headX,
  filteredX: sample.filteredX,
  velocityX: sample.velocityX,
  detectWidth: sample.detectWidth,
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
