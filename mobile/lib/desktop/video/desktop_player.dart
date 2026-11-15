// One video engine for every player of Immuch360 Desktop (design 2.2): a media_kit Player (libmpv) and, for a player
// that shows its video, the VideoController whose texture the Video widget draws. The viewer's flat player, the
// network page, the thumbnail grabber and the camera live view all go through it, through the pool
// (player_pool.dart), so that the mpv options below are set in one place.
//
// What libmpv is given: a path of this computer, or an http URL of the app's media bridge on 127.0.0.1 (the shares,
// and the server through ImmichServerFileSystem). Never the server's address, a cookie, a token or a header: the
// bridge reads those in Dart. Its own URLs carry the bridge's token, so every line of mpv's log and every error the
// app records goes through redactPlayerText first. The one exception is the live view's RTSP address, which holds
// the camera account because FFmpeg's RTSP client answers the camera's Digest challenge itself: that account is
// registered with hidePlayerSecret before the address reaches libmpv.
//
// How libmpv is given it: by mpv's loadfile command (DesktopPlayer.open), never through a file. media_kit's own open
// writes what it plays to a list file in the temporary folder and deletes it five seconds later (TempFile in its
// real.dart), which would leave each bridge URL, its token with it, on the disk for five seconds at every open.
//
// What libmpv opens by itself: nothing a file refers to. A file of a share or a folder is not trusted, and an M3U
// list or a DASH manifest named clip.mp4 would make mpv or FFmpeg fetch its entries from any address, without a click
// since the thumbnails open every video of a folder; the phones' players follow no such reference. So
// access-references is off on every player from its creation (DesktopPlayerOptions.common).

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
// The JPEG encoder of the photos' thumbnails (local_image_codec.dart), already in the lock through maplibre_gl
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/library/local_image_codec.dart';
import 'package:immich_mobile/desktop/video/decoder_measure.dart';
import 'package:immich_mobile/desktop/video/player_resource_options.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
import 'package:media_kit/media_kit.dart';
// The resolved path of libmpv, which the frame grab opens again in its own isolate (media_kit's screenshot does the
// same); the package does not export it
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

final _log = Logger('DesktopPlayer');

/// What a player is for: the pool keeps separate limits for each
enum PlayerKind {
  /// Shows a video on screen (the viewer, the network page): with a texture and sound
  playback,

  /// Takes one frame of a video for a thumbnail: muted, without texture or audio decoding
  thumbnail,

  /// Shows the live stream of a camera over RTSP (camera_live_view.dart): with a texture, muted until the user turns
  /// the sound on
  live,
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

/// A subtitle track of the video, as the subtitle menu lists it: one of the file, or a side file of subtitles the app
/// added to it ([PlaybackEngine.addExternalSubtitle])
@immutable
class DesktopSubtitleTrack {
  const DesktopSubtitleTrack({
    required this.id,
    this.title,
    this.language,
    this.codec,
    this.isDefault,
    this.isForced,
    this.external,
  });

  /// mpv's track id ("1", "2", ...)
  final String id;
  final String? title;

  /// The language the file declares, an ISO 639 code ("eng", "fre"), null when none
  final String? language;
  final String? codec;
  final bool? isDefault;

  /// Whether the file marks it as forced (the lines of the parts in another language), null when mpv does not say
  final bool? isForced;

  /// The address of the side file it was read from (a media bridge URL, which holds the bridge's token: never logged),
  /// null for a track of the file
  final String? external;

  bool get isExternal => external != null;

  @override
  bool operator ==(Object other) =>
      other is DesktopSubtitleTrack &&
      other.id == id &&
      other.title == title &&
      other.language == language &&
      other.codec == codec &&
      other.isDefault == isDefault &&
      other.isForced == isForced &&
      other.external == external;

  @override
  int get hashCode => Object.hash(id, title, language, codec, isDefault, isForced, external);

  @override
  String toString() => 'DesktopSubtitleTrack($id, $language${isExternal ? ', external' : ''})';
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

  /// How far the file is loaded in mpv's cache, a position in the file (demuxer-cache-time)
  ValueListenable<Duration> get buffered;

  /// The end of the file was reached (and the file does not loop)
  ValueListenable<bool> get completed;

  /// The texture can no longer show a picture: its graphics device was lost (a driver update, a GPU reset, the
  /// computer waking up). Only a new player shows the video again (PlayerLease.discard).
  ValueListenable<bool> get textureLost;
  ValueListenable<VideoFrameSize?> get videoSize;

  /// Whether the open file has a video track, null until it is open
  ValueListenable<bool?> get hasVideo;

  /// How mpv decodes the video of the open file (hwdec-current: "d3d11va", "d3d11va-copy", "no" for the processor),
  /// null until it says; for the "Video decoding" line of the video details (video_gpu.dart)
  ValueListenable<String?> get hwdec;
  ValueListenable<List<DesktopAudioTrack>> get audioTracks;

  /// The id of the audio track that plays, null for none or not known yet
  ValueListenable<String?> get audioTrack;

  /// The subtitle tracks of the open file, the side files added to it ([addExternalSubtitle]) among them; none until
  /// it is open
  ValueListenable<List<DesktopSubtitleTrack>> get subtitleTracks;

  /// The id of the subtitle track shown, null for none
  ValueListenable<String?> get subtitleTrack;

  Stream<PlayerEvent> get events;

  /// The codec of an audio track whose decoder mpv could not open ("truehd" in the libmpv of the computers, which has
  /// none), each time mpv says it (see audioDecoderFailureOf): the track then plays silent
  Stream<String> get audioDecoderFailures;

  /// Opens [resource], a path of this computer or a media bridge URL (for [PlayerKind.live], the RTSP address of a
  /// camera), paused at [start]. [streamed]: read over the network, with the larger cache.
  Future<void> open(String resource, {Duration start = Duration.zero, bool streamed = false});
  Future<void> play();
  Future<void> pause();

  /// Closes the file: the decoder and the cache are freed, the file of this computer is let go
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);

  /// After a stall, mpv waits for [wait] of media in its cache before it plays on (cache-pause-wait): what the link of
  /// the video asks (see linkTargetMs)
  Future<void> setResumeWait(Duration wait);

  /// From 0 to 1
  Future<void> setVolume(double volume);
  Future<void> setLoop(bool loop);
  Future<void> setAudioTrack(String id);

  /// Shows the subtitle track [id] of [subtitleTracks], or none for null
  Future<void> setSubtitleTrack(String? id);

  /// Adds the side file of subtitles at [uri] (a media bridge URL, SubRip, WebVTT or ASS) to the open file, named
  /// [title] in [language], and shows it: it is then one of [subtitleTracks], with [uri] as its
  /// [DesktopSubtitleTrack.external], until the next open. mpv opens no such file by itself (sub-auto, see DesktopPlayerOptions.common).
  Future<void> addExternalSubtitle(String uri, {String? title, String? language});

  /// The frame on screen as a JPEG scaled into [box], null when no frame is there yet
  Future<Uint8List?> grabFrame(FrameBox box);

  Future<void> dispose();

  /// At the close of the window, for a player whose [dispose] did not end in time: libmpv stops calling Dart, whose
  /// isolate is about to end (a call after that would end the app on a crash). Nothing else changes: the player is
  /// left as it is to the end of the process.
  void silence();
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

  /// The live view's: the RTSP connection to the camera and nothing else. FFmpeg's RTSP client opens its connection
  /// through tcp, or tls for an rtsps:// address (a UniFi Protect link of a camera of another brand, release 48);
  /// with the RTP packets inside it (rtsp-transport) it opens no rtp or udp socket, so neither is listed.
  static const liveProtocols = ['rtsp', 'rtsps', 'tcp', 'tls'];

  static List<String> protocolsFor(PlayerKind kind) => kind == PlayerKind.live ? liveProtocols : protocols;

  /// A camera that stops sending is given up after this long and the live view opens its stream again: the timeout
  /// the phones give Media3 for the same streams (CameraLiveView.kt)
  static const liveTimeoutSeconds = 8;

  /// A live stream cannot be read ahead of the camera: the cache only holds what came while the player waited, a few
  /// seconds of a 2K stream at most, and keeps nothing behind
  static const liveMaxBytes = 16 * 1024 * 1024;

  /// How much of a live stream FFmpeg reads before it plays (see forOpen)
  static const liveAnalyzeSeconds = 0.5;

  /// The render height of the texture (design 2.11): a 4K panel at 200 % would ask for 8.3 Mpx a frame, four times
  /// the 1080p budget; Flutter scales the texture up the rest of the way. 1440 lines is an assumption of the design,
  /// to be measured by the harness on the 3200 x 2000 panel.
  static const maxRenderHeight = 1440;

  /// mpv properties set once on every player, after media_kit's own (which turns cache-on-disk on without a cache
  /// folder: mpv then fails with "Failed to create file cache")
  static Map<String, String> common(PlayerKind kind) => {
    // The cache stays in memory, bounded per open (below); nothing of a private video is written to the disk
    'cache-on-disk': 'no',
    // What the file played refers to is not opened (see the top of this file). Off from the start: the address
    // reaches mpv through loadfile, not as the entry of a list, which mpv would not read with it off.
    'access-references': 'no',
    // The bridge may wait for a share that answers in bursts (HttpRangeReader waits 30 s); media_kit sets 5 s. A
    // camera is local and sends all the time: a silence means it is gone (liveTimeoutSeconds).
    'network-timeout': kind == PlayerKind.live ? '$liveTimeoutSeconds' : '30',
    // A URL of the bridge is never handed to youtube-dl, whose hook would start a process for any http URL
    'ytdl': 'no',
    // No other file is opened next to the video by mpv itself (external subtitles or audio): the decoders stay
    // bounded, and a share is not listed for them. The side files of subtitles of a film of a media server are added
    // by the app, one at a time, when the user picks one (PlaybackEngine.addExternalSubtitle).
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
    if (kind == PlayerKind.live) ...{
      // RTP inside the RTSP connection, as on the phones (setForceUseRtpTcp): nothing lost on a busy Wi-Fi, no UDP
      // port for the firewall to open. mpv's default, set so that another default never opens UDP sockets.
      'rtsp-transport': 'tcp',
      'sid': 'no',
    },
  };

  /// mpv properties set before each open
  static Map<String, String> forOpen(PlayerKind kind, {required bool streamed}) {
    if (kind == PlayerKind.live) {
      return {
        'cache': 'yes',
        'demuxer-max-bytes': '$liveMaxBytes',
        'demuxer-max-back-bytes': '0',
        // FFmpeg reads up to 5 s of the stream to learn its tracks, and mpv then plays from the first packet read:
        // the picture stayed that far behind the camera for as long as it played (1.1 s ahead in mpv's cache with
        // the default, none with 0.5 s, and the first frame 1.7 s after the open instead of 3.1 s, measured on a
        // synthetic 720p stream of H.264 and G.711 on 2026-10-10). The cameras describe both tracks in their SDP.
        'demuxer-lavf-analyzeduration': '$liveAnalyzeSeconds',
      };
    }
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

// Every URL whatever its scheme: the bridge's carry its token in the path, an rtsp one a password before the host.
// A secret already hidden inside it (<hidden>, see hidePlayerSecret) does not end it.
final _url = RegExp(
  r'\b[a-zA-Z][a-zA-Z0-9+.-]*://(?:[^\s"'
  "'"
  r'<>]|<hidden>)+',
);

// A request header that carries a credential, as mpv prints it at the verbose levels ("Set property:
// http-header-fields=...") or as an error may quote it
final _credentialHeader = RegExp(
  r'(http-header-fields|cookie|set-cookie|authorization|proxy-authorization|x-api-key|x-immich-[a-z-]+|x-plex-token)'
  r'(\s*[:=]\s*)[^\r\n]*',
  caseSensitive: false,
);

// The secrets given to libmpv outside a header (hidePlayerSecret), longest first so that one holding another is
// hidden whole
final _secrets = <String>[];

/// Hides [secret] in every text [redactPlayerText] gives back from now on, for the life of the app: the camera
/// account that the live view puts in its RTSP address (camera_live_view.dart). The URL rule hides the whole address;
/// this one hides the account where a line quotes it on its own, or decoded, or cut by a space the URL rule stops at.
/// Kept after the stream stops, since mpv's lines arrive after the stop.
void hidePlayerSecret(String secret) {
  if (secret.isEmpty || _secrets.contains(secret)) {
    return;
  }
  _secrets
    ..add(secret)
    ..sort((a, b) => b.length.compareTo(a.length));
}

/// [text] (a line of mpv's log, an error of the player) without what could open a file, a session or a camera to
/// whoever reads the logs: every secret of [hidePlayerSecret], every URL, and every header that carries a credential,
/// are replaced. The secrets go first: a password with a space would end the URL rule's match inside it.
String redactPlayerText(String text) {
  var redacted = text;
  for (final secret in _secrets) {
    redacted = redacted.replaceAll(secret, '<hidden>');
  }
  return redacted
      .replaceAll(_url, '<url>')
      .replaceAllMapped(_credentialHeader, (match) => '${match[1]}${match[2]}<hidden>');
}

/// Whether a line of mpv's log comes from hardware decoding looking for a decoder this computer has: hwdec auto-safe
/// tries them in turn, CUDA without an NVIDIA driver, VA-API without a driver for the GPU (a Linux computer, a virtual
/// machine), a hardware device that cannot be made; mpv goes on to the next one, then to software decoding, which the
/// decoder measure watches (decoder_measure.dart). The OpenGL render path of media_kit_video (Linux) loads the
/// interops of those decoders with its render context, under prefixes such as libmpv_render/vaapi/vaapi
@visibleForTesting
bool isDecoderProbeLine(String prefix, String text) =>
    prefix.split('/').any(_probedDecoders.contains) || text.startsWith('AVHWDeviceContext:');

const _probedDecoders = {'vaapi', 'vdpau', 'cuda'};

/// Writes a line of mpv's log to the app's log, redacted. mpv's errors are warnings of the app (a bad frame, a
/// share that stalls): a file that cannot be played at all reaches the user through [PlayerEventKind.failed].
@visibleForTesting
void logPlayerLine(String level, String prefix, String text) {
  final line = redactPlayerText('$prefix: $text');
  // media_kit sets options this libmpv build does not have (osc) on every player, and hardware decoding tries the
  // decoders in turn: not errors of the video
  if ((prefix == 'media_kit' && text.contains('property not found')) || isDecoderProbeLine(prefix, text)) {
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

/// The codec of the line of mpv's log ([prefix], [text]) that says a decoder of audio could not be opened ("ad: Failed
/// to initialize a decoder for codec 'truehd'."), lower case; null for any other line
@visibleForTesting
String? audioDecoderFailureOf(String prefix, String text) {
  if (prefix != 'ad') {
    return null;
  }
  final match = _audioDecoderFailure.firstMatch(text);
  final codec = match?.group(1)?.trim().toLowerCase();
  return codec == null || codec.isEmpty ? null : codec;
}

final _audioDecoderFailure = RegExp(r"Failed to initialize a decoder for codec '([^']+)'");

/// A media_kit player with the options of the app, see [PlaybackEngine]
class DesktopPlayer implements PlaybackEngine {
  DesktopPlayer._(this.kind, this._player, this.videoController);

  /// Makes a player of [kind]: the libmpv instance, and for [PlayerKind.playback] and [PlayerKind.live] its texture.
  /// The Meta Quest build's players (android_mpv.dart) give their own [hwdec] and measure nothing ([measureDecoding]):
  /// the computers keep the defaults.
  static Future<DesktopPlayer> create(
    PlayerKind kind, {
    String hwdec = DesktopPlayerOptions.hwdec,
    bool measureDecoding = true,
  }) async {
    // Read by media_kit_video of media_kit_360 when it sizes each texture (its IMMUCH360-NOTE.md, patch 3)
    VideoController.maxOutputHeight ??= DesktopPlayerOptions.maxRenderHeight;
    final player = Player(
      configuration: PlayerConfiguration(
        title: 'Immuch360',
        muted: kind != PlayerKind.playback,
        // Warnings and errors only: the verbose levels print the request headers and every URL opened
        logLevel: MPVLogLevel.warn,
        bufferSize: kind == PlayerKind.live ? DesktopPlayerOptions.liveMaxBytes : DesktopPlayerOptions.localMaxBytes,
        protocolWhitelist: DesktopPlayerOptions.protocolsFor(kind),
      ),
    );
    final controller = kind != PlayerKind.thumbnail
        ? VideoController(player, configuration: VideoControllerConfiguration(hwdec: hwdec))
        : null;
    if (controller != null) {
      // The controller makes its texture after the next frame, and every call on the player waits for it: a page
      // that shows nothing moving would draw no frame, and its video would wait for the next one
      SchedulerBinding.instance.scheduleFrame();
    }
    final desktopPlayer = DesktopPlayer._(kind, player, controller);
    await desktopPlayer._setUp();
    if (kind == PlayerKind.playback && measureDecoding) {
      // What this computer keeps up with, for the next questions about the same kind of video (decoder_measure.dart)
      desktopPlayer._removers.add(watchDecoding(desktopPlayer, desktopPlayer.mpvProperty));
    }
    return desktopPlayer;
  }

  /// A player of [kind] over [platform] instead of libmpv, without texture: for the tests, which check what
  /// DesktopPlayer asks of media_kit and of mpv
  @visibleForTesting
  static Future<DesktopPlayer> withPlatform(PlayerKind kind, PlatformPlayer platform) async {
    final desktopPlayer = DesktopPlayer._(kind, Player(platformPlayer: platform), null);
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
  final _buffered = ValueNotifier(Duration.zero);
  final _completed = ValueNotifier(false);
  final _textureLost = ValueNotifier(false);
  final _videoSize = ValueNotifier<VideoFrameSize?>(null);
  final _hasVideo = ValueNotifier<bool?>(null);
  final _hwdec = ValueNotifier<String?>(null);
  final _audioTracks = ValueNotifier<List<DesktopAudioTrack>>(const []);
  final _audioTrack = ValueNotifier<String?>(null);
  final _subtitleTracks = ValueNotifier<List<DesktopSubtitleTrack>>(const []);
  final _subtitleTrack = ValueNotifier<String?>(null);

  /// The subtitle tracks of the file as media_kit lists them last, and what it leaves out of them, read from mpv's
  /// track-list: the forced flag and the side file of each (see [_readSubtitleFlags])
  List<SubtitleTrack> _fileSubtitles = const [];
  Map<String, ({bool forced, String? file})> _subtitleFlags = const {};

  /// The side files added since the open, by the id mpv gave their track
  final _externalSubtitles = <String, String>{};

  /// Bumped by each listing of the tracks and each open, so that a read of mpv's track-list that ends late is dropped
  int _subtitleListing = 0;
  final _events = StreamController<PlayerEvent>.broadcast();
  final _audioDecoderFailures = StreamController<String>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _removers = <void Function()>[];
  bool _disposed = false;

  /// FFmpeg's last error since the open, redacted: for a live stream, the reason of a failure ("method DESCRIBE
  /// failed: 401 Unauthorized"), which mpv's own error code does not tell
  String? _openError;

  /// The options the last open set for its resource (desktopResourceOptions), taken back at the next open
  Set<String> _resourceKeys = const {};

  /// Where the file of the last open starts, null for its beginning
  Duration? _openStart;

  @override
  ValueListenable<Duration> get position => _position;
  @override
  ValueListenable<Duration> get duration => _duration;
  @override
  ValueListenable<bool> get playing => _playing;
  @override
  ValueListenable<bool> get buffering => _buffering;

  @override
  ValueListenable<Duration> get buffered => _buffered;
  @override
  ValueListenable<bool> get completed => _completed;
  @override
  ValueListenable<bool> get textureLost => _textureLost;
  @override
  ValueListenable<VideoFrameSize?> get videoSize => _videoSize;
  @override
  ValueListenable<bool?> get hasVideo => _hasVideo;
  @override
  ValueListenable<String?> get hwdec => _hwdec;
  @override
  ValueListenable<List<DesktopAudioTrack>> get audioTracks => _audioTracks;
  @override
  ValueListenable<String?> get audioTrack => _audioTrack;
  @override
  ValueListenable<List<DesktopSubtitleTrack>> get subtitleTracks => _subtitleTracks;
  @override
  ValueListenable<String?> get subtitleTrack => _subtitleTrack;
  @override
  Stream<PlayerEvent> get events => _events.stream;
  @override
  Stream<String> get audioDecoderFailures => _audioDecoderFailures.stream;

  Future<void> _setUp() async {
    final stream = _player.stream;
    _subscriptions.addAll([
      stream.position.listen((value) => _position.value = value),
      stream.duration.listen((value) => _duration.value = value),
      stream.playing.listen((value) => _playing.value = value),
      stream.buffering.listen((value) => _buffering.value = value),
      stream.buffer.listen((value) => _buffered.value = value),
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
        _fileSubtitles = [
          for (final track in tracks.subtitle)
            if (!_isPseudoTrack(track.id)) track,
        ];
        _publishSubtitles();
        if (_fileSubtitles.isNotEmpty) {
          unawaited(_readSubtitleFlags());
        }
      }),
      stream.track.listen((track) => _audioTrack.value = _isPseudoTrack(track.audio.id) ? null : track.audio.id),
      stream.log.listen((log) {
        logPlayerLine(log.level, log.prefix, log.text);
        final failedCodec = audioDecoderFailureOf(log.prefix, log.text);
        if (failedCodec != null && !_disposed && !_audioDecoderFailures.isClosed) {
          _audioDecoderFailures.add(failedCodec);
        }
        // Why a camera's stream did not open, which a decoder this computer lacks never is
        if (kind == PlayerKind.live &&
            (log.level == 'error' || log.level == 'fatal') &&
            log.prefix.startsWith('ffmpeg') &&
            !isDecoderProbeLine(log.prefix, log.text)) {
          _openError = redactPlayerText(log.text);
        }
      }),
    ]);
    // media_kit_video of media_kit_360 gives the texture id 0 when its graphics device was lost (its
    // IMMUCH360-NOTE.md, patch 4); a texture id is never 0 otherwise on Windows
    final controller = videoController;
    if (controller != null && CurrentPlatform.isWindows) {
      void onTexture() => _textureLost.value = controller.id.value == 0;
      controller.id.addListener(onTexture);
      _removers.add(() => controller.id.removeListener(onTexture));
    }
    // Where the file opened starts: set as mpv loads it (on_load, before its demuxer reads anything), as media_kit
    // does for a Media's start; media_kit's on_unload sets it back to none once the file is closed
    _native.onLoadHooks.add(() async {
      final start = _openStart;
      if (start != null) {
        await _set('start', (start.inMilliseconds / 1000).toStringAsFixed(3));
      }
    });
    await _native.observeEvent(mpv.mpv_event_id.MPV_EVENT_FILE_LOADED, (_) async {
      // The decoder of the previous file says nothing of this one
      _hwdec.value = null;
      _emit(const PlayerEvent(PlayerEventKind.loaded));
    });
    if (kind != PlayerKind.thumbnail) {
      // mpv tells it once the decoder is open, and again when it falls back to another one; without a value (no file)
      // the listener is not called
      await _native.observeProperty('hwdec-current', (value) async {
        _hwdec.value = value.trim().isEmpty ? null : value.trim();
      });
    }
    if (kind == PlayerKind.playback) {
      // The subtitle track mpv shows, whoever chose it: mpv on its own at the open, the menu, a side file added.
      // media_kit's own track state keeps what was asked last, the address for a side file.
      await _native.observeProperty('sid', (value) async {
        final id = value.trim();
        _subtitleTrack.value = id.isEmpty || _isPseudoTrack(id) ? null : id;
      });
    }
    await _native.observeEvent(mpv.mpv_event_id.MPV_EVENT_PLAYBACK_RESTART, (_) async {
      _emit(const PlayerEvent(PlayerEventKind.restarted));
    });
    await _native.observeEvent(mpv.mpv_event_id.MPV_EVENT_END_FILE, (event) async {
      final endFile = event.ref.data.cast<mpv.mpv_event_end_file>().ref;
      if (endFile.reason == mpv.mpv_end_file_reason.MPV_END_FILE_REASON_ERROR) {
        _emit(PlayerEvent(PlayerEventKind.failed, _openError ?? _errorText(endFile.error)));
      }
    });
    for (final MapEntry(:key, :value) in DesktopPlayerOptions.common(kind).entries) {
      await _set(key, value);
    }
  }

  static bool _isPseudoTrack(String id) => id == 'auto' || id == 'no';

  /// Tells the subtitle tracks of the file as they are known now, when they changed
  void _publishSubtitles() {
    final tracks = [
      for (final track in _fileSubtitles)
        DesktopSubtitleTrack(
          id: track.id,
          title: track.title,
          language: track.language,
          codec: track.codec,
          isDefault: track.isDefault,
          isForced: _subtitleFlags[track.id]?.forced,
          external: _externalSubtitles[track.id] ?? _subtitleFlags[track.id]?.file,
        ),
    ];
    if (!listEquals(tracks, _subtitleTracks.value)) {
      _subtitleTracks.value = tracks;
    }
  }

  /// Reads the forced flag and the side file of each subtitle track from mpv's track-list, which media_kit's tracks
  /// do not carry; a libmpv that does not give it leaves the tracks as media_kit lists them
  Future<void> _readSubtitleFlags() async {
    final listing = ++_subtitleListing;
    final String trackList;
    try {
      trackList = await _native.getProperty('track-list');
    } catch (error) {
      _log.fine('No track list from mpv: ${redactPlayerText('$error')}');
      return;
    }
    if (_disposed || listing != _subtitleListing) {
      return;
    }
    _subtitleFlags = subtitleTrackFlags(trackList);
    _publishSubtitles();
  }

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

  /// mpv's property [name] as text, empty when mpv has none: what the decoder measure reads (hwdec-current, the drop
  /// counters), and the troubleshooting page
  Future<String> mpvProperty(String name) => _native.getProperty(name);

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
    _openError = null;
    _videoSize.value = null;
    _hasVideo.value = null;
    _audioTracks.value = const [];
    _audioTrack.value = null;
    _clearSubtitles();
    final options = DesktopPlayerOptions.forOpen(kind, streamed: streamed);
    for (final MapEntry(:key, :value) in options.entries) {
      await _set(key, value);
    }
    // Those of the resource itself (the y4m of an AV2 companion), those of the previous one it does not set taken back
    final extra = desktopResourceOptions[resource] ?? const <String, String>{};
    // A key every player sets at its creation goes back to that value (access-references, which the films a Plex
    // server converts open with, android_mpv.dart), any other to mpv's default
    final common = DesktopPlayerOptions.common(kind);
    for (final key in _resourceKeys) {
      if (!extra.containsKey(key) && !options.containsKey(key)) {
        await _set(key, common[key] ?? '');
      }
    }
    for (final MapEntry(:key, :value) in extra.entries) {
      await _set(key, value);
    }
    _resourceKeys = extra.keys.toSet();
    _openStart = kind != PlayerKind.live && start > Duration.zero ? start : null;
    // Not media_kit's open, which writes the address to a list file in the temporary folder for five seconds (see the
    // top of this file): a bridge URL holds its token, a live address the camera account, and both stay in memory.
    // mpv gets the address itself, as the only entry of its playlist. media_kit's stop first resets its own state, as
    // its open does; the file then loads paused, as its open(play: false) leaves it.
    await _player.stop();
    await _set('pause', 'yes');
    await _native.command(['loadfile', mpvAddress(resource), 'replace']);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    _openStart = null;
    await _player.stop();
    _videoSize.value = null;
    _hasVideo.value = null;
    _audioTracks.value = const [];
    _audioTrack.value = null;
    _clearSubtitles();
  }

  /// The subtitles of the file that closes go with it, the side files added to it too (mpv drops them at the next
  /// loadfile)
  void _clearSubtitles() {
    _subtitleListing++;
    _fileSubtitles = const [];
    _subtitleFlags = const {};
    _externalSubtitles.clear();
    _subtitleTracks.value = const [];
    _subtitleTrack.value = null;
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  /// Seeks to the frame shown at [position] exactly, decoding from the key frame before it whatever mpv's hr-seek
  /// option says: the frames of a splat scene (lib/desktop/ai/splat/mpv_frame_source.dart). mpv tells the frame is
  /// there by its playback-restart ([PlayerEventKind.restarted]).
  Future<void> seekExact(Duration position) =>
      _native.command(['seek', (position.inMicroseconds / 1e6).toStringAsFixed(6), 'absolute+exact']);

  /// Shows the next frame and pauses on it, decoding that frame only: the frames of a splat scene, a few apart. mpv
  /// tells the frame is there by its position ([position]); no playback-restart comes.
  Future<void> stepFrame() => _native.command(['frame-step']);

  /// Whether mpv shows each frame as soon as it is decoded rather than at its time ([untimed]): a frame step then
  /// takes the time of one decoding, 4 to 5 ms for a 1080p VP9 frame instead of 35 ms (measured on the lighthouse
  /// video of the splat scenes, 2026-11-01). Only on a player of its own, never on one of the pool.
  Future<void> setUntimed(bool untimed) => _set('untimed', untimed ? 'yes' : 'no');

  /// The filters of mpv each decoded frame goes through ([filters], mpv's vf; empty for none): the frames of a splat
  /// scene of an 8K video scaled down as they are decoded (lib/desktop/ai/splat/mpv_frame_source.dart). Only on a
  /// player of its own, never on one of the pool; a filter this libmpv refuses is left out, said in the log.
  Future<void> setVideoFilters(String filters) => _set('vf', filters);

  /// The address of the mpv handle of this player, for [withMpvScreenshot] in another isolate
  Future<int> get mpvHandle => _player.handle;

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Future<void> setResumeWait(Duration wait) =>
      _set('cache-pause-wait', (wait.inMilliseconds / 1000).toStringAsFixed(1));

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
  Future<void> setSubtitleTrack(String? id) async {
    if (id == null) {
      await _player.setSubtitleTrack(SubtitleTrack.no());
      return;
    }
    final track = _player.state.tracks.subtitle.where((track) => track.id == id).firstOrNull;
    if (track != null) {
      await _player.setSubtitleTrack(track);
    } else {
      // A side file added a moment ago, which media_kit does not list yet: mpv has it
      await _set('sid', id);
    }
  }

  @override
  Future<void> addExternalSubtitle(String uri, {String? title, String? language}) async {
    // mpv's sub-add with its select flag: the file is read, becomes a track and is shown
    await _player.setSubtitleTrack(SubtitleTrack.uri(uri, title: title, language: language));
    // The track it became is the one shown now, whatever order mpv's track-list arrives in
    final String id;
    try {
      id = (await _native.getProperty('sid')).trim();
    } catch (error) {
      _log.fine('No subtitle track from mpv: ${redactPlayerText('$error')}');
      return;
    }
    if (id.isEmpty || _isPseudoTrack(id)) {
      _log.warning('The side file of subtitles could not be read');
      return;
    }
    _externalSubtitles[id] = uri;
    _subtitleTrack.value = id;
    _publishSubtitles();
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
    await _audioDecoderFailures.close();
    await _player.dispose();
  }

  @override
  void silence() {
    // What media_kit's dispose does before it lets go of its callback (Initializer.dispose), which a dispose waiting
    // for libmpv never reaches: with no callback, libmpv wakes nothing of Dart
    try {
      final native = _native;
      if (native.ctx != nullptr) {
        native.mpv.mpv_set_wakeup_callback(native.ctx, nullptr, nullptr);
      }
    } catch (error) {
      _log.fine('Could not silence a player: $error');
    }
  }
}

/// What media_kit leaves out of the subtitle tracks, by mpv's track id: the forced flag and, for a side file added to
/// the video, its address; from [trackList], mpv's track-list as text (JSON). Nothing for a text that does not read.
@visibleForTesting
Map<String, ({bool forced, String? file})> subtitleTrackFlags(String trackList) {
  final Object? tracks;
  try {
    tracks = jsonDecode(trackList);
  } on FormatException {
    return const {};
  }
  if (tracks is! List) {
    return const {};
  }
  return {
    for (final track in tracks)
      if (track is Map && track['type'] == 'sub' && track['id'] is int)
        '${track['id']}': (
          forced: track['forced'] == true,
          file: track['external'] == true && track['external-filename'] is String
              ? track['external-filename'] as String
              : null,
        ),
  };
}

/// What mpv's loadfile is given for [resource]: a URL as it is (a bridge URL, a camera's RTSP address); a path of
/// this computer as media_kit gave it when its open still went through a list file (its _sanitizeUri), which on
/// Windows ([windows], this computer's system by default) is the normalized path behind the \\?\ prefix of long
/// paths, a UNC path being left without it
@visibleForTesting
String mpvAddress(String resource, {bool? windows}) {
  if (resource.contains('://') || !(windows ?? Platform.isWindows)) {
    return resource;
  }
  const longPathPrefix = r'\\?\';
  if (resource.startsWith(longPathPrefix)) {
    return resource;
  }
  final path = p.windows.normalize(resource.replaceAll('/', r'\'));
  return RegExp(r'^[A-Za-z]:\\').hasMatch(path) ? '$longPathPrefix$path' : path;
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
Uint8List? _grabFrame(_GrabRequest request) => withMpvScreenshot(request.handle, request.library, (frame) {
  final target = frameSizeIn(frame.width, frame.height, (
    width: request.width,
    height: request.height,
    cover: request.cover,
  ));
  final rgba = scaleBgr0ToRgba(
    frame.bgr0,
    sourceWidth: frame.width,
    sourceHeight: frame.height,
    stride: frame.stride,
    width: target.width,
    height: target.height,
  );
  final image = img.Image.fromBytes(width: target.width, height: target.height, bytes: rgba.buffer, numChannels: 4);
  // The quality and the colour sampling of the photos' thumbnails
  return img.encodeJpg(image, quality: thumbnailJpegQuality, chroma: img.JpegChroma.yuv420);
});

/// The path of the libmpv the players use, which [withMpvScreenshot] opens again in its isolate
String get mpvLibraryPath => NativeLibrary.path;

/// A frame as mpv's screenshot-raw gives it: [width] x [height] pixels, rows of [stride] bytes, 4 bytes a pixel in the
/// order blue, green, red, then a byte to leave aside. [bgr0] holds mpv's own memory: it is only valid during the call
/// of [withMpvScreenshot] that gives it.
typedef MpvRawFrame = ({int width, int height, int stride, Uint8List bgr0});

/// [use] of mpv's "screenshot-raw" of the frame on screen of the player whose handle is at [handle] ([library] being
/// the libmpv it was made with), in the order of the video once turned (a video with a rotation is turned by mpv
/// before its output, the null one of the players without a texture); null when there is no frame yet. Any isolate:
/// the thumbnails and the frames of a splat scene call it in one of their own.
T? withMpvScreenshot<T>(int handle, String library, T Function(MpvRawFrame frame) use) {
  final lib = mpv.MPV(DynamicLibrary.open(library));
  final ctx = Pointer<mpv.mpv_handle>.fromAddress(handle);
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
    return use((width: width, height: height, stride: stride, bgr0: data.asTypedList(size)));
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
