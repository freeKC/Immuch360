// "Natural" on the processor: VOSR 2.0 1.4B int8 (the ONNX export of moonbox-dev at 46811283, Apache-2.0) through
// the ONNX Runtime of the app, the pipeline of its model card as the probe of 23 November 2026 ran it
// (scripts/vosr_run.py), in a worker isolate of its own:
//  - the photo at its own size, taken as if it were already the bicubic x4 of a smaller one (a soft 12 MP photo looks
//    like one), in values from -1 to 1, padded to 512 px by mirroring when a side is shorter;
//  - tiles of 512 px with 64 of overlap; each tile through DINOv2-L (image_encoder, input "lq"), the encoder of the
//    Qwen-Image VAE (vae_encoder, "lq"), the one-step transformer (lq_latent, noise drawn from the seed, tokens) and
//    the decoder of the VAE (vae_decoder, "latent");
//  - the tiles blended with their feather, then VOSR's colour fix against the photo (enhance_pixels.dart).
// The sessions take the threads of the app's other ONNX Runtime work (the logical processors less two), lowered as
// those of the 3D photos (thread_priority.dart). A stop is
// read between two graphs: within a few seconds. Measured on the i9 of 24 threads: 16 s per tile (339.9 s for 3 MP,
// 989.9 s for 12 MP), 5.5 GB of working set and 8.5 to 9.7 GB of commit.
//
// On a Mac with an Apple chip (release 53) each graph is opened with Core ML (the ML Program format on every unit Core
// ML chooses, the provider the 3D videos take there, depth_provider.dart), which runs what it can of the graph on the
// GPU and the Neural Engine and leaves the rest (the int8 matrix products, most likely) to the processor of the same
// session. A graph Core ML refuses to open, or whose run fails on it, is opened again on the processor alone and the
// job goes on there, a line in the log saying so and the photo marked as partly run on the processor (fellBack, the
// warning ai_enhance_fell_back of the panel); the session Core ML failed a run on is closed before the graph opens
// again, so that a 16 GB Mac never holds the graph twice. Checked on the macOS runner with tiny graphs of the same inputs and
// outputs (make_tiny_vosr.py), against the processor; whether Core ML is faster than the processor for the real int8
// graphs was never measured, nor was any run on a Mac.

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/thread_priority.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_pixels.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:logging/logging.dart';

final _log = Logger('EnhanceNatural');

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

/// Where the graphs of VOSR run: Core ML on Apple silicon, else the processor (see the top of this file)
OrtProvider naturalProviderOf({required bool appleSilicon}) => appleSilicon ? OrtProvider.coreMl : OrtProvider.cpu;

/// See the top of this file
class OrtNaturalBackend implements EnhanceBackend {
  OrtNaturalBackend({required this.files, required this.modelSha256, int? threads, this.provider = OrtProvider.cpu})
    : threads = threads ?? OrtSessionSettings.forThisComputer().intraOpThreads;

  final VosrFiles files;
  final int threads;

  /// The provider each graph is opened with first: the processor, or Core ML on Apple silicon
  final OrtProvider provider;

  /// What the last run said of its provider: the lines the worker sent ("Core ML refused ...: on the processor")
  final notes = <String>[];

  /// The SHA-256 of the transformer, the file that tells the version of the model
  @override
  final String modelSha256;

  @override
  String get model => 'VOSR 2.0 1.4B int8';

  /// Whether a graph of the last run went on the processor instead of [provider] (see the top of this file)
  @override
  bool get fellBack => notes.any((note) => note.endsWith(vosrOnProcessorNote) || note.endsWith(vosrFellBackNote));

  @override
  EnhanceTileProgress? get tileProgress => null;

  @override
  Future<Uint8List> enhance(
    SbsDecoded picture, {
    required String workFolder,
    required int seed,
    required NativeCancelFlag cancel,
    required void Function(int done, int all) onStep,
  }) async {
    notes.clear();
    final port = ReceivePort();
    final done = Completer<Uint8List>();
    final subscription = port.listen((message) {
      switch (message) {
        case ('step', final int tile, final int all):
          onStep(tile, all);
        case ('note', final String note):
          notes.add(note);
          _log.info(note);
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
      provider: provider,
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
    required this.provider,
  });

  final SendPort port;
  final VosrFiles files;
  final int width;
  final int height;
  final TransferableTypedData rgba;
  final int seed;
  final int cancel;
  final int threads;
  final OrtProvider provider;
}

void _vosrMain(_VosrRequest request) {
  final port = request.port;
  final cancelled = NativeCancelFlag.readerOf(request.cancel);
  final sessions = <OrtSession>[];
  final priority = ComputePriority(ThreadPriorityPlatform.system());
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
        // Loaded first, so that what loading starts is not taken for a thread of the session; the threads of each
        // session are lowered, as those of the 3D photos, so that the computer stays usable for the minutes it runs
        final runtime = OrtRuntime.load(request.files.library);
        OrtSession openOn(OrtProvider provider) {
          final session = priority
              .lowerThreadsBornDuring(
                () => runtime.openSession(
                  path,
                  settings: OrtSessionSettings(intraOpThreads: request.threads, provider: provider),
                ),
              )
              .value;
          sessions.add(session);
          return session;
        }

        void note(String text) => port.send(('note', text));
        void release(VosrGraph graph) {
          if (graph is _OrtGraph && sessions.remove(graph.session)) {
            graph.session.close();
          }
        }

        return openVosrGraph(
          path,
          request.provider,
          open: (provider) => _OrtGraph(openOn(provider)),
          note: note,
          release: release,
        );
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

/// The end of the note of a graph a provider refused to open, now on the processor
const vosrOnProcessorNote = ': on the processor';

/// The end of the note of a graph whose run failed on its provider, now on the processor
const vosrFellBackNote = ': on the processor from now on';

/// The graph at [path] opened with [provider] by [open], on the processor when that provider refuses it or fails a
/// run (see the top of this file), [note] told each time, the graph that failed a run given to [release] before the
/// graph opens on the processor; a stop of the run is never a failure of the provider
VosrGraph openVosrGraph(
  String path,
  OrtProvider provider, {
  required VosrGraph Function(OrtProvider provider) open,
  required void Function(String note) note,
  void Function(VosrGraph graph)? release,
}) {
  final name = path.split(RegExp(r'[/\\]')).last;
  if (provider == OrtProvider.cpu) {
    return open(OrtProvider.cpu);
  }
  try {
    final graph = open(provider);
    note('$name opened with ${provider.title}');
    return _FallbackGraph(graph, () => open(OrtProvider.cpu), (error) {
      note('$name failed a run with ${provider.title} ($error)$vosrFellBackNote');
    }, release ?? (_) {});
  } on OrtRunStopped {
    rethrow;
  } on OrtLoadException {
    rethrow;
  } on OrtException catch (error) {
    note('${provider.title} refused $name (${error.message})$vosrOnProcessorNote');
    return open(OrtProvider.cpu);
  }
}

/// A graph on a provider that falls back to the processor at its first failed run, the run made again there
class _FallbackGraph implements VosrGraph {
  _FallbackGraph(this._graph, this._onProcessor, this._failed, this._release);

  VosrGraph _graph;
  final VosrGraph Function() _onProcessor;
  final void Function(Object error) _failed;
  final void Function(VosrGraph graph) _release;
  var _fellBack = false;

  @override
  String get firstInput => _graph.firstInput;

  @override
  OrtTensor run(Map<String, OrtTensor> given) {
    try {
      return _graph.run(given);
    } on OrtRunStopped {
      rethrow;
    } on OrtException catch (error) {
      if (_fellBack) {
        rethrow;
      }
      _fellBack = true;
      _failed(error.message);
      // The session of the provider goes first: the graph is never held twice
      _release(_graph);
      _graph = _onProcessor();
      return _graph.run(given);
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
