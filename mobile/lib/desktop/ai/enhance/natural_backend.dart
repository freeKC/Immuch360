// "Natural" on the processor: VOSR 2.0 1.4B int8 (the ONNX export of moonbox-dev at 46811283, Apache-2.0) through
// the ONNX Runtime of the app, the pipeline of its model card as the probe of 23 November 2026 ran it
// (scripts/vosr_run.py), in a worker isolate of its own:
//  - the photo at its own size, taken as if it were already the bicubic x4 of a smaller one (a soft 12 MP photo looks
//    like one), in values from -1 to 1, padded to 512 px by mirroring when a side is shorter;
//  - tiles of 512 px with 64 of overlap; each tile through DINOv2-L (image_encoder, input "lq"), the encoder of the
//    Qwen-Image VAE (vae_encoder, "lq"), the one-step transformer (lq_latent, noise drawn from the seed, tokens) and
//    the decoder of the VAE (vae_decoder, "latent");
//  - the tiles blended with their feather, then VOSR's colour fix against the photo (enhance_pixels.dart).
// The sessions take the threads of the app's other ONNX Runtime work (the logical processors less two). A stop is
// read between two graphs: within a few seconds. Measured on the i9 of 24 threads: 16 s per tile (339.9 s for 3 MP,
// 989.9 s for 12 MP), 5.5 GB of working set and 8.5 to 9.7 GB of commit.

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_pixels.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';

/// The library of ONNX Runtime and the four graphs of VOSR
class VosrFiles {
  const VosrFiles({
    required this.library,
    required this.imageEncoder,
    required this.vaeEncoder,
    required this.transformer,
    required this.vaeDecoder,
  });

  final String library;
  final String imageEncoder;
  final String vaeEncoder;
  final String transformer;
  final String vaeDecoder;
}

/// See the top of this file
class OrtNaturalBackend implements EnhanceBackend {
  OrtNaturalBackend({required this.files, required this.modelSha256, int? threads})
    : threads = threads ?? OrtSessionSettings.forThisComputer().intraOpThreads;

  final VosrFiles files;
  final int threads;

  /// The SHA-256 of the transformer, the file that tells the version of the model
  @override
  final String modelSha256;

  @override
  String get model => 'VOSR 2.0 1.4B int8';

  @override
  bool get fellBack => false;

  @override
  Future<Uint8List> enhance(
    SbsDecoded picture, {
    required String workFolder,
    required int seed,
    required NativeCancelFlag cancel,
    required void Function(int done, int all) onStep,
  }) async {
    final port = ReceivePort();
    final done = Completer<Uint8List>();
    final subscription = port.listen((message) {
      switch (message) {
        case ('step', final int tile, final int all):
          onStep(tile, all);
        case ('done', final TransferableTypedData data):
          done.complete(data.materialize().asUint8List());
        case ('failed', final String code, final String text):
          done.completeError(BackendException(ImmersiveErrorCode.values.byName(code), text));
        case null:
          if (!done.isCompleted) {
            done.completeError(const BackendException(ImmersiveErrorCode.modelFailed, 'The VOSR worker stopped'));
          }
      }
    });
    final request = _VosrRequest(
      port: port.sendPort,
      files: files,
      width: picture.width,
      height: picture.height,
      rgba: TransferableTypedData.fromList([picture.rgba]),
      seed: seed,
      cancel: cancel.address,
      threads: threads,
    );
    final isolate = await Isolate.spawn(_vosrMain, request, debugName: 'enhance-vosr', onExit: port.sendPort);
    try {
      return await done.future;
    } finally {
      await subscription.cancel();
      port.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }
}

class _VosrRequest {
  const _VosrRequest({
    required this.port,
    required this.files,
    required this.width,
    required this.height,
    required this.rgba,
    required this.seed,
    required this.cancel,
    required this.threads,
  });

  final SendPort port;
  final VosrFiles files;
  final int width;
  final int height;
  final TransferableTypedData rgba;
  final int seed;
  final int cancel;
  final int threads;
}

void _vosrMain(_VosrRequest request) {
  final port = request.port;
  final cancelled = NativeCancelFlag.readerOf(request.cancel);
  final sessions = <OrtSession>[];
  try {
    final rgba = request.rgba.materialize().asUint8List();
    final out = runVosr(
      rgba,
      request.width,
      request.height,
      seed: request.seed,
      isCancelled: cancelled,
      onTile: (tile, all) => port.send(('step', tile, all)),
      open: (path) {
        final runtime = OrtRuntime.load(request.files.library);
        final session = runtime.openSession(path, settings: OrtSessionSettings(intraOpThreads: request.threads));
        sessions.add(session);
        return _OrtGraph(session);
      },
      files: request.files,
    );
    port.send(('done', TransferableTypedData.fromList([out])));
  } on BackendException catch (error) {
    port.send(('failed', error.code.name, error.message));
  } on OrtLoadException catch (error) {
    port.send(('failed', ImmersiveErrorCode.componentsMissing.name, error.message));
  } on OrtException catch (error) {
    final memory = error.message.toLowerCase().contains('alloc');
    port.send((
      'failed',
      (memory ? ImmersiveErrorCode.outOfMemory : ImmersiveErrorCode.modelFailed).name,
      memory ? '$enhanceMemoryMessage: ${error.message}' : error.message,
    ));
  } catch (error) {
    port.send(('failed', ImmersiveErrorCode.modelFailed.name, '$error'));
  } finally {
    for (final session in sessions) {
      session.close();
    }
  }
}

/// A session of one graph: the name of its first input, and a run that gives its first output (the tests give a fake)
abstract interface class VosrGraph {
  String get firstInput;

  OrtTensor run(Map<String, OrtTensor> given);
}

class _OrtGraph implements VosrGraph {
  const _OrtGraph(this.session);

  final OrtSession session;

  @override
  String get firstInput => session.inputs.first.name;

  @override
  OrtTensor run(Map<String, OrtTensor> given) =>
      session.runNamed(given, outputs: [session.outputs.first.name]).values.single;
}

/// The picture VOSR restores from [rgba] of [width] x [height] (see the top of this file), the graphs opened by [open]
/// in the order image encoder, VAE encoder, transformer, VAE decoder; stopped with a cancelled BackendException when
/// [isCancelled] says so between two graphs. Synchronous: runs in the worker isolate.
Uint8List runVosr(
  Uint8List rgba,
  int width,
  int height, {
  required int seed,
  required bool Function() isCancelled,
  required void Function(int tile, int all) onTile,
  required VosrGraph Function(String path) open,
  required VosrFiles files,
}) {
  const tile = enhanceTileSize;
  const overlap = enhanceTileOverlap;
  final paddedWidth = math.max(width, tile);
  final paddedHeight = math.max(height, tile);
  final padded = paddedWidth == width && paddedHeight == height
      ? rgba
      : reflectPad(rgba, width, height, paddedWidth, paddedHeight);
  final imageEncoder = open(files.imageEncoder);
  final vaeEncoder = open(files.vaeEncoder);
  final transformer = open(files.transformer);
  final vaeDecoder = open(files.vaeDecoder);
  final random = _Gauss(seed);
  final tiles = planTiles(paddedWidth, paddedHeight);
  final blender = TileBlender(paddedWidth, paddedHeight);
  void check() {
    if (isCancelled()) {
      throw const BackendException(ImmersiveErrorCode.cancelled, 'Cancelled');
    }
  }

  for (final (index, at) in tiles.indexed) {
    check();
    final input = Float32List(3 * tile * tile);
    for (var y = 0; y < tile; y++) {
      for (var x = 0; x < tile; x++) {
        final from = 4 * ((at.y + y) * paddedWidth + at.x + x);
        final i = y * tile + x;
        input[i] = padded[from] / 127.5 - 1;
        input[tile * tile + i] = padded[from + 1] / 127.5 - 1;
        input[2 * tile * tile + i] = padded[from + 2] / 127.5 - 1;
      }
    }
    final lq = OrtTensor(const [1, 3, tile, tile], input);
    final tokens = imageEncoder.run({imageEncoder.firstInput: lq});
    check();
    final lqLatent = vaeEncoder.run({vaeEncoder.firstInput: lq});
    check();
    final noise = Float32List(elementCountOf(lqLatent.shape));
    for (var i = 0; i < noise.length; i++) {
      noise[i] = random.next();
    }
    final sampled = transformer.run({
      'lq_latent': lqLatent,
      'noise': OrtTensor(lqLatent.shape, noise),
      'tokens': tokens,
    });
    check();
    final values = vaeDecoder.run({vaeDecoder.firstInput: sampled}).values;
    if (values.length != 3 * tile * tile) {
      throw BackendException(ImmersiveErrorCode.outputRejected, 'VOSR gave ${values.length} values for a tile');
    }
    final pixels = Uint8List(4 * tile * tile);
    for (var i = 0; i < tile * tile; i++) {
      pixels[4 * i] = _unit(values[i]);
      pixels[4 * i + 1] = _unit(values[tile * tile + i]);
      pixels[4 * i + 2] = _unit(values[2 * tile * tile + i]);
      pixels[4 * i + 3] = 255;
    }
    blender.add(at, pixels, overlap: overlap);
    onTile(index + 1, tiles.length);
  }
  final whole = blender.toRgba();
  final restored = identical(padded, rgba) ? whole : cropRgba(whole, paddedWidth, paddedHeight, width, height);
  colourFix(restored, rgba, width, height);
  return restored;
}

/// A value of the decoder, -1 to 1, as a byte
int _unit(double value) {
  final byte = (value + 1) * 127.5;
  return byte <= 0 ? 0 : (byte >= 255 ? 255 : (byte + 0.5).toInt());
}

/// Normal values from a seed (Box and Muller)
class _Gauss {
  _Gauss(int seed) : _random = math.Random(seed);

  final math.Random _random;
  double? _spare;

  double next() {
    final spare = _spare;
    if (spare != null) {
      _spare = null;
      return spare;
    }
    final u = math.max(_random.nextDouble(), 1e-12);
    final v = _random.nextDouble();
    final radius = math.sqrt(-2 * math.log(u));
    _spare = radius * math.sin(2 * math.pi * v);
    return radius * math.cos(2 * math.pi * v);
  }
}
