// The tools of the engine without their systems, for the tests of the chain, the worker and the engine: a model the
// worker isolate can make from a plain description (FakeBackendSpec), a memory of a chosen size, codecs that record
// what they are given or refuse it. Every one of them is a plain object, so that it travels to the worker isolate.

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/ai_worker.dart';
import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

import 'fake_depth_backend.dart';

/// A FakeDepthBackend made in the worker isolate, which can take its time or end the isolate in the middle of a run
class FakeBackendSpec implements DepthBackendSpec {
  const FakeBackendSpec({
    this.shape = FakeDepthShape.gradient,
    this.failure,
    this.delay = Duration.zero,
    this.endIsolateInRun = false,
    this.modelSha256 = depthModelOnnxSha256,
  });

  final FakeDepthShape shape;
  final String? failure;

  /// How long each run of the model takes, the thread busy as with a real model
  final Duration delay;

  /// The worker isolate ends in the middle of the run, as after an error nobody caught
  final bool endIsolateInRun;
  final String modelSha256;

  @override
  DepthBackend create() => SlowDepthBackend(
    FakeDepthBackend(shape: shape, failure: failure, modelSha256: modelSha256),
    delay: delay,
    endIsolateInRun: endIsolateInRun,
  );
}

/// [inner], slowed down; [onEstimate] hears each run before it ends
class SlowDepthBackend implements DepthBackend {
  SlowDepthBackend(this.inner, {this.delay = Duration.zero, this.endIsolateInRun = false, this.onEstimate});

  final FakeDepthBackend inner;
  final Duration delay;
  final bool endIsolateInRun;
  final void Function()? onEstimate;

  @override
  int get inputWidth => inner.inputWidth;

  @override
  int get inputHeight => inner.inputHeight;

  @override
  String get modelSha256 => inner.modelSha256;

  @override
  DepthMap estimate(Float32List nchw) {
    if (delay > Duration.zero) {
      sleep(delay);
    }
    if (endIsolateInRun) {
      Isolate.exit();
    }
    onEstimate?.call();
    return inner.estimate(nchw);
  }

  @override
  void close() => inner.close();
}

/// A backend whose map is not the size of its input
class WrongSizeBackend implements DepthBackend {
  @override
  int get inputWidth => depthModelInputWidth;

  @override
  int get inputHeight => depthModelInputHeight;

  @override
  String get modelSha256 => depthModelOnnxSha256;

  @override
  DepthMap estimate(Float32List nchw) => DepthMap(10, 10, Float32List(100));

  @override
  void close() {}
}

/// A memory of a chosen size
class FixedMemoryProbe implements MemoryProbe {
  const FixedMemoryProbe({this.physical = 16 * 1024 * 1024 * 1024, this.available = 8 * 1024 * 1024 * 1024});

  final int? physical;
  final int? available;

  @override
  MemoryFacts read() => MemoryFacts(physical: physical, available: available);
}

/// [inner], keeping what it decoded and was asked to encode
class RecordingCodec implements SbsCodec {
  RecordingCodec(this.inner);

  final SbsCodec inner;
  final decoded = <SbsDecoded>[];
  final pictures = <SbsPicture>[];
  final options = <SbsEncodeOptions>[];

  @override
  String get name => inner.name;

  @override
  SbsDecoded decodeJpeg(Uint8List bytes) {
    final result = inner.decodeJpeg(bytes);
    decoded.add(result);
    return result;
  }

  @override
  Uint8List encodeSbs(SbsPicture picture, SbsEncodeOptions options) {
    // A copy: the engine owns its pair
    pictures.add(SbsPicture(width: picture.width, height: picture.height, rgba: Uint8List.fromList(picture.rgba)));
    this.options.add(options);
    return inner.encodeSbs(picture, options);
  }
}

/// A codec that refuses everything with [message], as the native codec says it: `<status>: <reason>`
class RefusingCodec implements SbsCodec {
  RefusingCodec(this.message);

  final String message;
  var calls = 0;

  @override
  String get name => 'refusing';

  @override
  SbsDecoded decodeJpeg(Uint8List bytes) {
    calls++;
    throw SbsCodecException(message);
  }

  @override
  Uint8List encodeSbs(SbsPicture picture, SbsEncodeOptions options) {
    calls++;
    throw SbsCodecException(message);
  }
}
