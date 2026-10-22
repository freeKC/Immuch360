// The head tracker as the app uses it: the camera list, a tracking session with its stream of samples, and the file and
// frame readers of the tests. The camera opens only when a session starts and is released when it closes; frames never
// reach Dart, only the samples do.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'package:immuch_head_tracker/src/head_camera.dart';
import 'package:immuch_head_tracker/src/head_sample.dart';
import 'package:immuch_head_tracker/src/native_head_tracker.dart';

/// The entry point: one per library (the app's DLL, or a test build)
class HeadTracker {
  HeadTracker._(this._native);

  /// The tracker of the app's own DLL on Windows; null on the other systems, which have no tracker yet
  static HeadTracker? windows() => Platform.isWindows ? HeadTracker.load() : null;

  /// The tracker of the library at [library] (the tests give a build folder, or a gcc build on Linux); throws when it
  /// cannot be loaded
  factory HeadTracker.load([String? library]) => HeadTracker._(NativeHeadTracker(library));

  final NativeHeadTracker _native;

  /// The path the library was loaded from
  String get library => _native.path;

  /// The clock of the camera samples, microseconds
  int nowUs() => _native.nowUs();

  /// Whether the AVX2 build of the detector can run on this computer
  bool get cpuAvx2 => _native.cpuAvx2;

  /// The video cameras, listed in a background isolate without opening any. Throws [HeadTrackerException]
  /// (noMediaFoundation on a Windows N edition without the Media Feature Pack).
  Future<List<HeadCamera>> cameras() => _listCameras(_native.path);

  // Static, so that the closure sent to the isolate holds the path only
  static Future<List<HeadCamera>> _listCameras(String library) =>
      Isolate.run(() => NativeHeadTracker(library).listCameras());

  /// Starts tracking with [camera]. Returns at once: the camera opens on the tracker's thread, and an error to open it
  /// (accessDenied, cameraBusy, noCamera) comes as an error of [HeadTrackingSession.samples]. Throws
  /// [HeadTrackerException] for an error found before (noMediaFoundation, noDetector).
  HeadTrackingSession start(HeadCamera camera, {HeadTrackerOptions options = const HeadTrackerOptions()}) {
    final session = HeadTrackingSession._(_native);
    try {
      session._handle = _native.openCamera(camera.id, options, session._callable.nativeFunction);
    } catch (_) {
      session._callable.close();
      rethrow;
    }
    return session;
  }

  /// A video file read frame by frame, for the tests: the same source reader setup and luma path as a camera
  HeadFileReader openFile(String path, {HeadTrackerOptions options = const HeadTrackerOptions()}) =>
      HeadFileReader._(_native, _native.openFile(path, options));

  /// A tracker fed with grey frames, for the tests
  HeadFrameProcessor openFrames({HeadTrackerOptions options = const HeadTrackerOptions()}) =>
      HeadFrameProcessor._(_native, _native.openFrames(options));
}

/// A camera being tracked. [samples] gives each analysed frame (15 a second by default); an error that stops the
/// camera (accessDenied, cameraBusy, deviceLost, noCamera) comes as a [HeadTrackerException] on the same stream, after
/// which no sample follows. Close it when the Spatial page closes, the window is minimised or tracking is turned off:
/// the camera is released and its light goes off.
class HeadTrackingSession {
  HeadTrackingSession._(NativeHeadTracker native)
    : _native = native,
      _testLatest = null,
      _testNowUs = null,
      _testInfo = null,
      _testOnClose = null {
    _callable = NativeCallable<HtSampleCallbackNative>.listener(signal);
  }

  /// A session without a library, driven by [signal], for the tests of the code that consumes sessions
  @visibleForTesting
  HeadTrackingSession.forTesting({
    required ({HeadSample sample, int status})? Function() latest,
    int Function()? nowUs,
    HeadTrackerInfo Function()? info,
    Future<void> Function()? onClose,
  }) : _native = null,
       _testLatest = latest,
       _testNowUs = nowUs,
       _testInfo = info,
       _testOnClose = onClose;

  final NativeHeadTracker? _native;
  late final NativeCallable<HtSampleCallbackNative> _callable;
  Pointer<Void> _handle = nullptr;
  final ({HeadSample sample, int status})? Function()? _testLatest;
  final int Function()? _testNowUs;
  final HeadTrackerInfo Function()? _testInfo;

  /// The release of the camera in the tests: a close that takes its time
  final Future<void> Function()? _testOnClose;

  final _samples = StreamController<HeadSample>.broadcast();
  HeadSample? _latest;
  HeadTrackerException? _error;
  bool _closed = false;
  Future<void>? _closing;

  /// Each analysed frame, then the error that stopped the camera if one did
  Stream<HeadSample> get samples => _samples.stream;

  /// The newest sample, null before the first
  HeadSample? get latest => _latest;

  /// The error that stopped the camera, null while it runs
  HeadTrackerException? get error => _error;

  bool get isClosed => _closed;

  /// The clock of [HeadSample.timeUs], to ask [HeadViewpoint.valueAt] for "now" in the same clock
  int nowUs() => _testNowUs?.call() ?? _native!.nowUs();
  int nowNanos() => nowUs() * 1000;

  /// The detector build, the camera's format and frame rate, and the state of automatic framing (known after the
  /// first frame)
  HeadTrackerInfo info() => _testInfo?.call() ?? _native!.info(_handle);

  /// The native callback: a new sample, or the error that stopped the camera. Several calls may come for one sample
  /// read (the listener posts them); a sample already given is not given again.
  @visibleForTesting
  void signal(int sequence, int status) {
    if (_closed || _error != null) {
      return;
    }
    final testLatest = _testLatest;
    final read = testLatest != null ? testLatest() : _native!.latest(_handle);
    if (read == null) {
      return;
    }
    if (read.status < 0) {
      _error = HeadTrackerException.fromStatus(read.status, hresult: _testLatest == null ? info().hresult : 0);
      _samples.addError(_error!);
      return;
    }
    if (_latest != null && read.sample.sequence <= _latest!.sequence) {
      return;
    }
    _latest = read.sample;
    _samples.add(read.sample);
  }

  /// Stops the camera and releases it. The native close waits for the capture thread (a frame, then the release of
  /// the camera), so it runs in a background isolate; the callback stays open until it has returned.
  Future<void> close() {
    return _closing ??= () async {
      _closed = true;
      final native = _native;
      if (native != null && _handle != nullptr) {
        final address = _handle.address;
        _handle = nullptr;
        await _closeInBackground(native.path, address);
      }
      if (native != null) {
        _callable.close();
      }
      await _testOnClose?.call();
      await _samples.close();
    }();
  }
}

// Static, so that the closure sent to the isolate holds the path and the address only
Future<void> _closeInBackground(String library, int address) =>
    Isolate.run(() => NativeHeadTracker(library).close(Pointer<Void>.fromAddress(address)));

/// A video file read one analysed frame at a time, at the file's own timestamps
class HeadFileReader {
  HeadFileReader._(this._native, this._handle);

  final NativeHeadTracker _native;
  Pointer<Void> _handle;

  /// The next analysed frame, null at the end of the file. Throws [HeadTrackerException].
  HeadSample? next() => _native.next(_handle);

  HeadTrackerInfo info() => _native.info(_handle);

  void close() {
    if (_handle != nullptr) {
      _native.close(_handle);
      _handle = nullptr;
    }
  }
}

/// A tracker fed with grey frames: each frame given is analysed
class HeadFrameProcessor {
  HeadFrameProcessor._(this._native, this._handle);

  final NativeHeadTracker _native;
  Pointer<Void> _handle;
  Pointer<Uint8> _buffer = nullptr;
  int _capacity = 0;

  /// Analyses [grey], [width] x [height] pixels, rows [stride] bytes apart (the width by default), seen at [timeNs]
  HeadSample process(Uint8List grey, int width, int height, int timeNs, {int? stride}) {
    if (grey.length > _capacity) {
      if (_buffer != nullptr) {
        calloc.free(_buffer);
      }
      _buffer = calloc<Uint8>(grey.length);
      _capacity = grey.length;
    }
    _buffer.asTypedList(grey.length).setAll(0, grey);
    return _native.processFrame(_handle, _buffer, width, height, stride ?? width, timeNs);
  }

  HeadTrackerInfo info() => _native.info(_handle);

  void close() {
    if (_handle != nullptr) {
      _native.close(_handle);
      _handle = nullptr;
    }
    if (_buffer != nullptr) {
      calloc.free(_buffer);
      _buffer = nullptr;
      _capacity = 0;
    }
  }
}
