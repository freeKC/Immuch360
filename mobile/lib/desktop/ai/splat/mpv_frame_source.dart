// The frames of a video for a splat scene taken by the app's own libmpv (plan 2026-11-01, section 2.2, lot SP5), the
// way VideoThumbnailGrabber takes a thumbnail: a muted player without texture or audio opens the file once, goes to the
// frame of each candidate exactly, and takes mpv's screenshot-raw of it. A video filmed upright with its rotation in
// the file comes out upright: with the null output of a player without texture, mpv turns the frames before its output
// (its autorotate filter), so the screenshot holds them turned. The grey copy and its sharpness are made in an isolate
// from mpv's memory; only the sharpest frame of a window is turned into RGBA, reduced to 1 600 pixels and encoded, in
// another isolate.
//
// How it goes to a frame: an exact seek (absolute+exact) decodes from the key frame before it, half a group of frames
// on average; the lighthouse video of the measure has one key frame every 4.27 s, and 600 exact seeks took 4 min 22 s
// on the PC (WSL, software VP9). The candidates follow each other 0.2 s apart, so the player steps from one to the next
// instead (mpv's frame-step, untimed: one decoding a frame, 4 to 5 ms), and seeks only for the first one, or for one
// further than [MpvSplatFrameSource.maxStep] ahead or behind. A step and a seek land on the same frame: the first one
// whose time is the candidate's or after it.
//
// The player is made for the job and disposed after it, outside the app's pool: the pool has one player for the
// thumbnails, which a minute of frames would hold from the library, or lose to it in the middle of the video. Nothing
// but a path of this computer is opened (a server original is copied first, as for the photos).

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/splat/sharpness.dart';
import 'package:immich_mobile/desktop/ai/splat/video_frames.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// Makes the player of the frames: a muted one of [PlayerKind.thumbnail], with the mpv options of the app
typedef SplatPlayerFactory = Future<DesktopPlayer> Function();

class MpvSplatFrameSource implements SplatFrameSource {
  MpvSplatFrameSource({
    SplatPlayerFactory? create,
    this.openTimeout = const Duration(seconds: 30),
    this.frameTimeout = const Duration(seconds: 15),
    this.longSide = SplatV1.photoLongSide,
    this.quality = SplatV1.photoQuality,
    this.codec = SbsCodecChoice.auto,
    this.maxStep = const Duration(seconds: 1),
  }) : _create = create ?? (() => DesktopPlayer.create(PlayerKind.thumbnail));

  final SplatPlayerFactory _create;

  /// Longest wait for the file to open and show its first frame
  final Duration openTimeout;

  /// Longest wait for one frame once sought
  final Duration frameTimeout;
  final int longSide;
  final int quality;
  final SbsCodecChoice codec;

  /// The farthest a candidate may be ahead of the frame shown to be stepped to rather than sought
  final Duration maxStep;

  /// The exact seeks and the frame steps so far, for the log
  int seeks = 0;
  int steps = 0;

  DesktopPlayer? _player;
  StreamSubscription<PlayerEvent>? _subscription;
  final _changed = StreamController<void>.broadcast();
  var _restarts = 0;
  String? _failure;
  int? _handle;

  /// The time of the frame shown, null before the first
  Duration? _shown;

  void _wake() {
    if (!_changed.isClosed) {
      _changed.add(null);
    }
  }

  Future<bool> _until(bool Function() condition, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      final left = deadline.difference(DateTime.now());
      if (_failure != null || left <= Duration.zero) {
        return false;
      }
      // The duration comes as a property, not an event: a short poll catches it
      const poll = Duration(milliseconds: 100);
      await _changed.stream.first.timeout(left < poll ? left : poll, onTimeout: () {});
    }
    return true;
  }

  @override
  Future<SplatVideoFacts> open(String resource) async {
    final player = _player = await _create();
    _subscription = player.events.listen((event) {
      switch (event.kind) {
        case PlayerEventKind.restarted:
          _restarts++;
        case PlayerEventKind.failed:
          _failure = event.message ?? 'failed';
        case PlayerEventKind.loaded:
          break;
      }
      _wake();
    });
    // A frame step tells its frame by the position only
    player.position.addListener(_wake);
    await player.open(resource);
    if (!await _until(() => _restarts > 0 && player.duration.value > Duration.zero, openTimeout)) {
      throw ConversionException(ImmersiveErrorCode.decodeFailed, _failure ?? 'The video did not open');
    }
    if (player.hasVideo.value == false) {
      throw const ConversionException(ImmersiveErrorCode.decodeFailed, 'The file has no video');
    }
    _handle = await player.mpvHandle;
    await player.setUntimed(true);
    _shown = player.position.value;
    final fps = double.tryParse(await player.mpvProperty('container-fps'));
    return SplatVideoFacts(duration: player.duration.value, fps: fps != null && fps.isFinite && fps > 0 ? fps : null);
  }

  @override
  Future<SplatFrame?> frameAt(Duration time) async {
    final player = _player;
    final handle = _handle;
    if (player == null || handle == null) {
      return null;
    }
    // A frame whose time is a millisecond before the candidate's is its frame: times are rounded in the files
    const slack = Duration(milliseconds: 1);
    final shown = _shown;
    if (shown == null || time < shown - slack || time - shown > maxStep) {
      final before = _restarts;
      await player.seekExact(time);
      seeks++;
      if (!await _until(() => _restarts > before, frameTimeout)) {
        _shown = null;
        return null;
      }
      // Read from mpv: the position event of the seek may come after its playback-restart
      final position = double.tryParse(await player.mpvProperty('time-pos'));
      _shown = position == null ? time : Duration(microseconds: (position * 1e6).round());
    } else {
      while (_shown! < time - slack) {
        final was = player.position.value;
        await player.stepFrame();
        steps++;
        if (!await _until(() => player.position.value != was || player.completed.value, frameTimeout) ||
            player.position.value == was) {
          // The end of the video, or a frame that did not come: the next candidate seeks
          _shown = null;
          return null;
        }
        _shown = player.position.value;
      }
    }
    final at = _shown ?? time;
    final library = mpvLibraryPath;
    // mpv restarted, so the frame is on its (null) output; a screenshot may still miss it for a moment
    for (var attempt = 0; attempt < 10; attempt++) {
      final grab = await _grabInBackground(handle, library);
      if (grab != null) {
        return _MpvFrame(at, grab, this);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return null;
  }

  @override
  Future<void> close() async {
    _player?.position.removeListener(_wake);
    await _subscription?.cancel();
    _subscription = null;
    await _changed.close();
    final player = _player;
    _player = null;
    _handle = null;
    await player?.dispose();
  }
}

/// A screenshot of mpv, its rows packed (4 bytes a pixel, BGR0), with the sharpness of its grey copy
class _Grab {
  const _Grab(this.width, this.height, this.sharpness, this.pixels);

  final int width;
  final int height;
  final double sharpness;
  final TransferableTypedData pixels;
}

/// [_grab] in another isolate. Its own function, so that the closure sent there holds the handle and the path only
Future<_Grab?> _grabInBackground(int handle, String library) => Isolate.run(() => _grab(handle, library));

_Grab? _grab(int handle, String library) => withMpvScreenshot(handle, library, (frame) {
  final sharpness = sharpnessOf(
    frame.bgr0,
    width: frame.width,
    height: frame.height,
    stride: frame.stride,
    order: PixelOrder.bgr0,
  );
  final rowBytes = frame.width * 4;
  final packed = Uint8List(rowBytes * frame.height);
  for (var y = 0; y < frame.height; y++) {
    packed.setRange(y * rowBytes, (y + 1) * rowBytes, frame.bgr0, y * frame.stride);
  }
  return _Grab(frame.width, frame.height, sharpness, TransferableTypedData.fromList([packed]));
});

class _MpvFrame implements SplatFrame {
  _MpvFrame(this.time, this._grab, this._source);

  @override
  final Duration time;
  final _Grab _grab;
  final MpvSplatFrameSource _source;

  @override
  int get width => _grab.width;

  @override
  int get height => _grab.height;

  @override
  double get sharpness => _grab.sharpness;

  @override
  Future<({int width, int height})> writeJpeg(String path) {
    final request = _EncodeRequest(
      _grab.pixels,
      _grab.width,
      _grab.height,
      path,
      _source.longSide,
      _source.quality,
      _source.codec,
    );
    return _encodeInBackground(request);
  }
}

class _EncodeRequest {
  const _EncodeRequest(this.pixels, this.width, this.height, this.path, this.longSide, this.quality, this.codec);

  final TransferableTypedData pixels;
  final int width;
  final int height;
  final String path;
  final int longSide;
  final int quality;
  final SbsCodecChoice codec;
}

/// [_encode] in another isolate, the closure holding the request only
Future<({int width, int height})> _encodeInBackground(_EncodeRequest request) => Isolate.run(() => _encode(request));

/// The frame as RGBA, reduced to [_EncodeRequest.longSide], encoded and written, its size given back; in an isolate of
/// its own
({int width, int height}) _encode(_EncodeRequest request) {
  final rgba = request.pixels.materialize().asUint8List();
  for (var at = 0; at < rgba.length; at += 4) {
    final blue = rgba[at];
    rgba[at] = rgba[at + 2];
    rgba[at + 2] = blue;
    rgba[at + 3] = 0xFF;
  }
  final fitted = fitEye(
    SbsDecoded(width: request.width, height: request.height, rgba: rgba),
    maxWidth: request.longSide,
    maxHeight: request.longSide,
  );
  SbsCodecException? refusal;
  for (final codec in request.codec.codecs()) {
    try {
      final jpeg = codec.encodeSbs(
        SbsPicture.single(width: fitted.width, height: fitted.height, rgba: fitted.rgba),
        SbsEncodeOptions(quality: request.quality, subsampling: ChromaSubsampling.s420),
      );
      File(request.path).writeAsBytesSync(jpeg);
      return (width: fitted.width, height: fitted.height);
    } on SbsCodecException catch (error) {
      refusal = error;
    }
  }
  throw refusal ?? const SbsCodecException('No codec');
}
