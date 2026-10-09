// One video engine for every player of Immuch360 Desktop (design 2.2): a media_kit Player (libmpv) and, for a player
// that shows its video, the VideoController whose texture the Video widget draws. The viewer's flat player, the
// network page and the thumbnail grabber all go through it, through the pool (player_pool.dart), so that the mpv
// options below are set in one place.
//
// What libmpv is given: a path of this computer, or an http URL of the app's media bridge on 127.0.0.1 (the shares,
// and the server through ImmichServerFileSystem). Never the server's address, a cookie, a token or a header: the
// bridge reads those in Dart. Its own URLs carry the bridge's token, so every line of mpv's log and every error the
// app records goes through redactPlayerText first.
//
// What libmpv opens by itself: nothing a file refers to. A file of a share or a folder is not trusted, and an M3U
// list or a DASH manifest named clip.mp4 would make mpv or FFmpeg fetch its entries from any address, without a click
// since the thumbnails open every video of a folder; the phones' players follow no such reference. So
// access-references is off for the file played (see DesktopPlayer.open).

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
// The JPEG encoder of the photos' thumbnails (local_image_codec.dart), already in the lock through maplibre_gl
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/library/local_image_codec.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
import 'package:media_kit/media_kit.dart';
// The resolved path of libmpv, which the frame grab opens again in its own isolate (media_kit's screenshot does the
// same); the package does not export it
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:media_kit_video/media_kit_video.dart';

final _log = Logger('DesktopPlayer');

/// What a player is for: the pool keeps separate limits for each
enum PlayerKind {
  /// Shows a video on screen (the viewer, the network page): with a texture and sound
  playback,

  /// Takes one frame of a video for a thumbnail: muted, without texture or audio decoding
  thumbnail,
}

/// An audio track of the video, as the audio track menu lists it
@immutable
class DesktopAudioTrack {
  const DesktopAudioTrack({required this.id, this.title, this.language, this.channels, this.codec, this.isDefault});

  /// mpv's track id ("1", "2", ...)
  final String id;
  final String? title;

  /// The language the file declares, an ISO 639 code ("eng", "fre"), null when none
  final String? language;

  /// Number of channels, null when the file does not say
  final int? channels;
  final String? codec;
  final bool? isDefault;

  @override
  bool operator ==(Object other) =>
      other is DesktopAudioTrack &&
      other.id == id &&
      other.title == title &&
      other.language == language &&
      other.channels == channels &&
      other.codec == codec &&
      other.isDefault == isDefault;

  @override
  int get hashCode => Object.hash(id, title, language, channels, codec, isDefault);

  @override
  String toString() => 'DesktopAudioTrack($id, $language, $channels channels)';
}

/// The size of the decoded frames, rotation applied
typedef VideoFrameSize = ({int width, int height});

/// The box a frame grab is scaled into: inside it ([cover] false), or covering it ([cover] true, the timeline tiles);
/// never larger than the frame itself
typedef FrameBox = ({int width, int height, bool cover});

/// What libmpv tells about the file it opened, in order
enum PlayerEventKind {
  /// The file is open: duration and tracks are known
  loaded,

  /// A frame is shown after an open or a seek (mpv's playback-restart): the texture holds the frame of this file
  restarted,

  /// The file could not be played; [PlayerEvent.message] says why, redacted
  failed,
}

@immutable
class PlayerEvent {
  const PlayerEvent(this.kind, [this.message]);

  final PlayerEventKind kind;
  final String? message;

  @override
  String toString() => 'PlayerEvent(${kind.name}${message == null ? '' : ', $message'})';
}

/// What the adapter, the pool and the frame grabber use of a player. [DesktopPlayer] gives it over media_kit; the
/// tests give a fake one, so that all three are tested without libmpv.
abstract class PlaybackEngine {
  PlayerKind get kind;

  /// The texture of the video, null for a player without one (the frame grabber, the fakes of the tests)
  VideoController? get videoController;

  ValueListenable<Duration> get position;
  ValueListenable<Duration> get duration;
  ValueListenable<bool> get playing;

  /// mpv waits for its cache (paused-for-cache)
  ValueListenable<bool> get buffering;

  /// The end of the file was reached (and the file does not loop)
  ValueListenable<bool> get completed;

  /// The texture can no longer show a picture: its graphics device was lost (a driver update, a GPU reset, the
  /// computer waking up). Only a new player shows the video again (PlayerLease.discard).
  ValueListenable<bool> get textureLost;
  ValueListenable<VideoFrameSize?> get videoSize;

  /// Whether the open file has a video track, null until it is open
  ValueListenable<bool?> get hasVideo;
  ValueListenable<List<DesktopAudioTrack>> get audioTracks;

  /// The id of the audio track that plays, null for none or not known yet
  ValueListenable<String?> get audioTrack;

  Stream<PlayerEvent> get events;

  /// Opens [resource], a path of this computer or a media bridge URL, paused at [start]. [streamed]: read over the
  /// network, with the larger cache.
  Future<void> open(String resource, {Duration start = Duration.zero, bool streamed = false});
  Future<void> play();
  Future<void> pause();

  /// Closes the file: the decoder and the cache are freed, the file of this computer is let go
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);

  /// From 0 to 1
  Future<void> setVolume(double volume);
  Future<void> setLoop(bool loop);
  Future<void> setAudioTrack(String id);

  /// The frame on screen as a JPEG scaled into [box], null when no frame is there yet
  Future<Uint8List?> grabFrame(FrameBox box);

  Future<void> dispose();
}

/// The mpv options of the app's players, and why (design 2.2 and 2.7, plan 2.7)
abstract final class DesktopPlayerOptions {
  /// Hardware decoding where mpv knows it works (D3D11VA, NVDEC, VA-API, VideoToolbox), software otherwise. "auto"
  /// would also try the methods mpv marks unsafe (with known wrong colours or crashes on some drivers).
  static const hwdec = 'auto-safe';

  /// The frame grab has no texture to hand frames to: a hardware decoder copies them back to memory
  static const thumbnailHwdec = 'auto-copy-safe';

  /// Streamed (the media bridge): up to a minute ahead, like the phones' players (StreamingLoadControl.kt, 50 to
  /// 60 s), so that a share that answers in bursts does not stall the video; bounded in bytes, since an 8K file at
  /// 210 Mbit/s would fill a minute with 1.5 GB on a computer that may have 16 GB for everything (plan 2.7). 256 MiB
  /// is 10 s of such a file and the whole minute of a 30 Mbit/s one.
  static const streamedCacheSeconds = 60;
  static const streamedMaxBytes = 256 * 1024 * 1024;
  static const streamedMaxBackBytes = 32 * 1024 * 1024;

  /// After a stall, mpv waits for this much media before it plays on (Media3's 5 s after a rebuffer on the phones)
  static const streamedResumeSeconds = 5;

  /// A file of this computer: the disk keeps up, a short cache is enough
  static const localCacheSeconds = 10;
  static const localMaxBytes = 64 * 1024 * 1024;
  static const localMaxBackBytes = 16 * 1024 * 1024;

  /// The frame grab reads a few seconds around one frame
  static const thumbnailMaxBytes = 16 * 1024 * 1024;

  /// The protocols FFmpeg may use for the file it is given: a path, or the bridge over http. This list has no host
  /// limit and does not cover mpv's own opens: what a file refers to is refused by access-references (see the top of
  /// this file). No https, rtsp or udp: no player of this phase reads anything else.
  static const protocols = ['file', 'http', 'tcp'];

  /// The render height of the texture (design 2.11): a 4K panel at 200 % would ask for 8.3 Mpx a frame, four times
  /// the 1080p budget; Flutter scales the texture up the rest of the way. 1440 lines is an assumption of the design,
  /// to be measured by the harness on the 3200 x 2000 panel.
  static const maxRenderHeight = 1440;

  /// mpv properties set once on every player, after media_kit's own (which turns cache-on-disk on without a cache
  /// folder: mpv then fails with "Failed to create file cache")
  static Map<String, String> common(PlayerKind kind) => {
    // The cache stays in memory, bounded per open (below); nothing of a private video is written to the disk
    'cache-on-disk': 'no',
    // The bridge may wait for a share that answers in bursts (HttpRangeReader waits 30 s); media_kit sets 5 s
    'network-timeout': '30',
    // A URL of the bridge is never handed to youtube-dl, whose hook would start a process for any http URL
    'ytdl': 'no',
    // No other file is opened next to the video (external subtitles or audio): the decoders stay bounded, and a
    // share is not listed for them
    'sub-auto': 'no',
    'audio-file-auto': 'no',
    // The downscale stays media_kit's bilinear one (dscale, correct-downscaling), although a 5.7K or 8K video is then
    // shrunk twice without a prefilter, to the render height (maxRenderHeight) then by Flutter to the view, which can
    // shimmer on fine detail. mpv's own downscaler takes it out of its "dumb mode" into passes over a 16 bit copy of
    // the whole video frame. Measured on an Intel UHD (profile build, 2880 x 1440 texture, 2026-10-09), a 5.7K video
    // then took 712 to 725 MB of GPU memory instead of 319 to 326, shared with the system, and the app's frames took
    // 22.6 to 27.4 ms at the median in all seven phases measured, never less (2.5 to 33.8 ms without it). A single
    // downscale, to the size of the view (design 2.11), would avoid the second pass without that cost.
    if (kind == PlayerKind.thumbnail) ...{
      // media_kit leaves vid=no until a VideoController is attached; the grab has none and wants the frames
      'vid': 'auto',
      'aid': 'no',
      'sid': 'no',
      'hwdec': thumbnailHwdec,
    },
  };

  /// mpv properties set before each open
  static Map<String, String> forOpen(PlayerKind kind, {required bool streamed}) {
    if (kind == PlayerKind.thumbnail) {
      return {
        'cache': 'yes',
        'cache-secs': '2',
        'demuxer-max-bytes': '$thumbnailMaxBytes',
        'demuxer-max-back-bytes': '0',
      };
    }
    return {
      'cache': 'yes',
      'cache-secs': '${streamed ? streamedCacheSeconds : localCacheSeconds}',
      'demuxer-max-bytes': '${streamed ? streamedMaxBytes : localMaxBytes}',
      'demuxer-max-back-bytes': '${streamed ? streamedMaxBackBytes : localMaxBackBytes}',
      'cache-pause-wait': '${streamed ? streamedResumeSeconds : 1}',
    };
  }
}

// Every URL whatever its scheme: the bridge's carry its token in the path, an rtsp one a password before the host
final _url = RegExp(
  r'\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'
  "'"
  r'<>]+',
);

// A request header that carries a credential, as mpv prints it at the verbose levels ("Set property:
// http-header-fields=...") or as an error may quote it
final _credentialHeader = RegExp(
  r'(http-header-fields|cookie|set-cookie|authorization|proxy-authorization|x-api-key|x-immich-[a-z-]+|x-plex-token)'
  r'(\s*[:=]\s*)[^\r\n]*',
  caseSensitive: false,
);

/// [text] (a line of mpv's log, an error of the player) without what could open a file or a session to whoever reads
/// the logs: every URL, and every header that carries a credential, are replaced
String redactPlayerText(String text) =>
    text.replaceAll(_url, '<url>').replaceAllMapped(_credentialHeader, (match) => '${match[1]}${match[2]}<hidden>');

/// Writes a line of mpv's log to the app's log, redacted. mpv's errors are warnings of the app (a bad frame, a
/// share that stalls): a file that cannot be played at all reaches the user through [PlayerEventKind.failed].
@visibleForTesting
void logPlayerLine(String level, String prefix, String text) {
  final line = redactPlayerText('$prefix: $text');
  // media_kit sets options this libmpv build does not have (osc) on every player: not an error of the video
  if (prefix == 'media_kit' && text.contains('property not found')) {
    _log.fine(line);
    return;
  }
  switch (level) {
    case 'fatal' || 'error':
      _log.warning(line);
    case 'warn':
      _log.fine(line);
    default:
      _log.finest(line);
  }
}

/// A media_kit player with the options of the app, see [PlaybackEngine]
class DesktopPlayer implements PlaybackEngine {
  DesktopPlayer._(this.kind, this._player, this.videoController);

  /// Makes a player of [kind]: the libmpv instance, and for [PlayerKind.playback] its texture
  static Future<DesktopPlayer> create(PlayerKind kind) async {
    // Read by the vendored media_kit_video when it sizes each texture (its IMMUCH360-NOTE.md, patch 3)
    VideoController.maxOutputHeight ??= DesktopPlayerOptions.maxRenderHeight;
    final player = Player(
      configuration: PlayerConfiguration(
        title: 'Immuch360',
        muted: kind == PlayerKind.thumbnail,
        // Warnings and errors only: the verbose levels print the request headers and every URL opened
        logLevel: MPVLogLevel.warn,
        bufferSize: DesktopPlayerOptions.localMaxBytes,
        protocolWhitelist: DesktopPlayerOptions.protocols,
      ),
    );
    final controller = kind == PlayerKind.playback
        ? VideoController(player, configuration: const VideoControllerConfiguration(hwdec: DesktopPlayerOptions.hwdec))
        : null;
    if (controller != null) {
      // The controller makes its texture after the next frame, and every call on the player waits for it: a page
      // that shows nothing moving would draw no frame, and its video would wait for the next one
      SchedulerBinding.instance.scheduleFrame();
    }
    final desktopPlayer = DesktopPlayer._(kind, player, controller);
    await desktopPlayer._setUp();
    return desktopPlayer;
  }

  @override
  final PlayerKind kind;

  final Player _player;

  @override
  final VideoController? videoController;

  NativePlayer get _native => _player.platform! as NativePlayer;

  final _position = ValueNotifier(Duration.zero);
  final _duration = ValueNotifier(Duration.zero);
  final _playing = ValueNotifier(false);
  final _buffering = ValueNotifier(false);
  final _completed = ValueNotifier(false);
  final _textureLost = ValueNotifier(false);
  final _videoSize = ValueNotifier<VideoFrameSize?>(null);
  final _hasVideo = ValueNotifier<bool?>(null);
  final _audioTracks = ValueNotifier<List<DesktopAudioTrack>>(const []);
  final _audioTrack = ValueNotifier<String?>(null);
  final _events = StreamController<PlayerEvent>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _removers = <void Function()>[];
  bool _disposed = false;

  @override
  ValueListenable<Duration> get position => _position;
  @override
  ValueListenable<Duration> get duration => _duration;
  @override
  ValueListenable<bool> get playing => _playing;
  @override
  ValueListenable<bool> get buffering => _buffering;
  @override
  ValueListenable<bool> get completed => _completed;
  @override
  ValueListenable<bool> get textureLost => _textureLost;
  @override
  ValueListenable<VideoFrameSize?> get videoSize => _videoSize;
  @override
  ValueListenable<bool?> get hasVideo => _hasVideo;
  @override
  ValueListenable<List<DesktopAudioTrack>> get audioTracks => _audioTracks;
  @override
  ValueListenable<String?> get audioTrack => _audioTrack;
  @override
  Stream<PlayerEvent> get events => _events.stream;

  Future<void> _setUp() async {
    final stream = _player.stream;
    _subscriptions.addAll([
      stream.position.listen((value) => _position.value = value),
      stream.duration.listen((value) => _duration.value = value),
      stream.playing.listen((value) => _playing.value = value),
      stream.buffering.listen((value) => _buffering.value = value),
      stream.completed.listen((value) => _completed.value = value),
      stream.videoParams.listen((params) {
        final rotated = params.rotate == 90 || params.rotate == 270;
        final width = rotated ? params.dh : params.dw;
        final height = rotated ? params.dw : params.dh;
        _videoSize.value = width != null && height != null && width > 0 && height > 0
            ? (width: width, height: height)
            : null;
      }),
      stream.tracks.listen((tracks) {
        _hasVideo.value = tracks.video.any((track) => !_isPseudoTrack(track.id));
        _audioTracks.value = [
          for (final track in tracks.audio)
            if (!_isPseudoTrack(track.id))
              DesktopAudioTrack(
                id: track.id,
                title: track.title,
                language: track.language,
                channels: track.audiochannels ?? track.channelscount,
                codec: track.codec,
                isDefault: track.isDefault,
              ),
        ];
      }),
      stream.track.listen((track) => _audioTrack.value = _isPseudoTrack(track.audio.id) ? null : track.audio.id),
      stream.log.listen((log) => logPlayerLine(log.level, log.prefix, log.text)),
    ]);
    // The vendored media_kit_video gives the texture id 0 when its graphics device was lost (its IMMUCH360-NOTE.md,
    // patch 4); a texture id is never 0 otherwise on Windows
    final controller = videoController;
    if (controller != null && CurrentPlatform.isWindows) {
      void onTexture() => _textureLost.value = controller.id.value == 0;
      controller.id.addListener(onTexture);
      _removers.add(() => controller.id.removeListener(onTexture));
    }
    // What the file refers to is not opened (see the top of this file). Turned off when mpv starts to load the file
    // (on_load, before its demuxer exists), since media_kit hands mpv each file through a list of one entry
    // (loadlist), which mpv does not read without it; turned on again before the next open.
    _native.onLoadHooks.add(() => _set('access-references', 'no'));
    await _native.observeEvent(mpv.mpv_event_id.MPV_EVENT_FILE_LOADED, (_) async {
      _emit(const PlayerEvent(PlayerEventKind.loaded));
    });
    await _native.observeEvent(mpv.mpv_event_id.MPV_EVENT_PLAYBACK_RESTART, (_) async {
      _emit(const PlayerEvent(PlayerEventKind.restarted));
    });
    await _native.observeEvent(mpv.mpv_event_id.MPV_EVENT_END_FILE, (event) async {
      final endFile = event.ref.data.cast<mpv.mpv_event_end_file>().ref;
      if (endFile.reason == mpv.mpv_end_file_reason.MPV_END_FILE_REASON_ERROR) {
        _emit(PlayerEvent(PlayerEventKind.failed, _errorText(endFile.error)));
      }
    });
    for (final MapEntry(:key, :value) in DesktopPlayerOptions.common(kind).entries) {
      await _set(key, value);
    }
  }

  static bool _isPseudoTrack(String id) => id == 'auto' || id == 'no';

  /// mpv's words for an error code ("loading failed", "unrecognized file format"): no path, no URL
  static String _errorText(int code) {
    try {
      final text = mpv.MPV(DynamicLibrary.open(NativeLibrary.path)).mpv_error_string(code).cast<Utf8>().toDartString();
      return 'libmpv: $text';
    } catch (_) {
      return 'libmpv error $code';
    }
  }

  void _emit(PlayerEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  Future<void> _set(String name, String value) async {
    try {
      await _native.setProperty(name, value);
    } catch (error) {
      // An option this libmpv build does not know: the player works without it
      _log.warning('mpv refused $name: ${redactPlayerText('$error')}');
    }
  }

  @override
  Future<void> open(String resource, {Duration start = Duration.zero, bool streamed = false}) async {
    _completed.value = false;
    _videoSize.value = null;
    _hasVideo.value = null;
    _audioTracks.value = const [];
    _audioTrack.value = null;
    for (final MapEntry(:key, :value) in DesktopPlayerOptions.forOpen(kind, streamed: streamed).entries) {
      await _set(key, value);
    }
    // For media_kit's list of one entry only: off again once mpv loads the file (_setUp)
    await _set('access-references', 'yes');
    await _player.open(Media(resource, start: start > Duration.zero ? start : null), play: false);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    _videoSize.value = null;
    _hasVideo.value = null;
    _audioTracks.value = const [];
    _audioTrack.value = null;
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Future<void> setVolume(double volume) => _player.setVolume((volume.clamp(0, 1) * 100).toDouble());

  @override
  Future<void> setLoop(bool loop) => _player.setPlaylistMode(loop ? PlaylistMode.single : PlaylistMode.none);

  @override
  Future<void> setAudioTrack(String id) async {
    final track = _player.state.tracks.audio.where((track) => track.id == id).firstOrNull;
    if (track != null) {
      await _player.setAudioTrack(track);
    }
  }

  @override
  Future<Uint8List?> grabFrame(FrameBox box) async {
    if (_disposed) {
      return null;
    }
    return _grabInBackground(_GrabRequest(await _player.handle, NativeLibrary.path, box.width, box.height, box.cover));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final remove in _removers) {
      remove();
    }
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _events.close();
    await _player.dispose();
  }
}

/// What the isolate of a frame grab needs: plain values only
@immutable
class _GrabRequest {
  const _GrabRequest(this.handle, this.library, this.width, this.height, this.cover);

  final int handle;
  final String library;
  final int width;
  final int height;
  final bool cover;
}

/// The size a frame of [sourceWidth] by [sourceHeight] gets in [box]: inside it, or covering it, never larger than
/// the frame
@visibleForTesting
VideoFrameSize frameSizeIn(int sourceWidth, int sourceHeight, FrameBox box) {
  final scaleX = box.width / sourceWidth;
  final scaleY = box.height / sourceHeight;
  final scale = math.min(1.0, box.cover ? math.max(scaleX, scaleY) : math.min(scaleX, scaleY));
  return (width: math.max(1, (sourceWidth * scale).round()), height: math.max(1, (sourceHeight * scale).round()));
}

/// [source] (BGR0 rows of [stride] bytes, mpv's screenshot format) scaled to [width] by [height] RGBA pixels, each
/// the mean of up to 4 x 4 samples of the area it covers: a thumbnail without the shimmer of a single sample, at a
/// cost that depends on the thumbnail, not on the 8K frame
@visibleForTesting
Uint8List scaleBgr0ToRgba(
  Uint8List source, {
  required int sourceWidth,
  required int sourceHeight,
  required int stride,
  required int width,
  required int height,
}) {
  final rgba = Uint8List(width * height * 4);
  final cellWidth = sourceWidth / width;
  final cellHeight = sourceHeight / height;
  final samplesX = math.max(1, math.min(4, cellWidth.floor()));
  final samplesY = math.max(1, math.min(4, cellHeight.floor()));
  var out = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var r = 0;
      var g = 0;
      var b = 0;
      for (var sy = 0; sy < samplesY; sy++) {
        final row = math.min(sourceHeight - 1, ((y + (sy + 0.5) / samplesY) * cellHeight).floor());
        for (var sx = 0; sx < samplesX; sx++) {
          final column = math.min(sourceWidth - 1, ((x + (sx + 0.5) / samplesX) * cellWidth).floor());
          final i = row * stride + column * 4;
          b += source[i];
          g += source[i + 1];
          r += source[i + 2];
        }
      }
      final count = samplesX * samplesY;
      rgba[out++] = r ~/ count;
      rgba[out++] = g ~/ count;
      rgba[out++] = b ~/ count;
      rgba[out++] = 0xFF;
    }
  }
  return rgba;
}

/// [_grabFrame] in another isolate: the copy and the scaling of an 8K frame take a while, and the JPEG encoder too.
/// Its own function, so that the closure sent there holds the request only, never the player.
Future<Uint8List?> _grabInBackground(_GrabRequest request) => Isolate.run(() => _grabFrame(request));

/// mpv's "screenshot-raw" of the frame on screen, scaled and encoded as a JPEG; null when there is no frame yet
Uint8List? _grabFrame(_GrabRequest request) {
  final lib = mpv.MPV(DynamicLibrary.open(request.library));
  final ctx = Pointer<mpv.mpv_handle>.fromAddress(request.handle);
  const args = ['screenshot-raw', 'video'];
  final argv = calloc<Pointer<Int8>>(args.length + 1);
  final node = calloc<mpv.mpv_node>();
  var filled = false;
  try {
    for (var i = 0; i < args.length; i++) {
      argv[i] = args[i].toNativeUtf8().cast();
    }
    // mpv reads the list up to its null entry, which calloc left
    if (lib.mpv_command_ret(ctx, argv, node) < 0) {
      return null;
    }
    filled = true;
    if (node.ref.format != mpv.mpv_format.MPV_FORMAT_NODE_MAP) {
      return null;
    }
    int? width;
    int? height;
    int? stride;
    Pointer<Uint8>? data;
    int? size;
    final map = node.ref.u.list.ref;
    for (var i = 0; i < map.num; i++) {
      final key = map.keys[i].cast<Utf8>().toDartString();
      final value = map.values[i];
      switch (key) {
        case 'w':
          width = value.u.int64;
        case 'h':
          height = value.u.int64;
        case 'stride':
          stride = value.u.int64;
        case 'data' when value.format == mpv.mpv_format.MPV_FORMAT_BYTE_ARRAY:
          data = value.u.ba.ref.data.cast<Uint8>();
          size = value.u.ba.ref.size;
      }
    }
    if (width == null || height == null || stride == null || data == null || size == null || width <= 0) {
      return null;
    }
    if (size < stride * height) {
      return null;
    }
    final target = frameSizeIn(width, height, (width: request.width, height: request.height, cover: request.cover));
    final rgba = scaleBgr0ToRgba(
      data.asTypedList(size),
      sourceWidth: width,
      sourceHeight: height,
      stride: stride,
      width: target.width,
      height: target.height,
    );
    final image = img.Image.fromBytes(width: target.width, height: target.height, bytes: rgba.buffer, numChannels: 4);
    // The quality and the colour sampling of the photos' thumbnails
    return img.encodeJpg(image, quality: thumbnailJpegQuality, chroma: img.JpegChroma.yuv420);
  } finally {
    if (filled) {
      lib.mpv_free_node_contents(node);
    }
    for (var i = 0; i < args.length; i++) {
      if (argv[i] != nullptr) {
        calloc.free(argv[i]);
      }
    }
    calloc.free(argv);
    calloc.free(node);
  }
}
