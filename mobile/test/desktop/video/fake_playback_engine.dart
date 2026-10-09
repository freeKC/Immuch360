// A player without libmpv for the tests of the adapter, the pool and the frame grabber: it records what it was asked
// and lets the test play libmpv's part (a frame shown, the duration known, the end reached, a failure).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:media_kit_video/media_kit_video.dart';

class FakePlaybackEngine implements PlaybackEngine {
  FakePlaybackEngine(this.kind, this.number);

  @override
  final PlayerKind kind;

  /// The order in which the pool made it, to tell the players apart
  final int number;

  @override
  VideoController? get videoController => null;

  @override
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  @override
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);
  @override
  final ValueNotifier<bool> playing = ValueNotifier(false);
  @override
  final ValueNotifier<bool> buffering = ValueNotifier(false);
  @override
  final ValueNotifier<bool> completed = ValueNotifier(false);
  @override
  final ValueNotifier<bool> textureLost = ValueNotifier(false);
  @override
  final ValueNotifier<VideoFrameSize?> videoSize = ValueNotifier(null);
  @override
  final ValueNotifier<bool?> hasVideo = ValueNotifier(null);
  @override
  final ValueNotifier<List<DesktopAudioTrack>> audioTracks = ValueNotifier(const []);
  @override
  final ValueNotifier<String?> audioTrack = ValueNotifier(null);

  final _events = StreamController<PlayerEvent>.broadcast(sync: true);

  @override
  Stream<PlayerEvent> get events => _events.stream;

  /// Every call, in order: `open /videos/a.mp4 at 0 streamed`, `play`, `seek 1500`, ...
  final calls = <String>[];

  String? resource;
  double rate = 1;
  double volume = 1;
  bool loop = false;
  bool disposed = false;

  /// What [grabFrame] answers, and the boxes it was asked for
  Uint8List? frame;
  final boxes = <FrameBox>[];

  /// Whether [open] shows the first frame by itself, with this duration and size, as libmpv does for a good file
  Duration? autoLoad;
  VideoFrameSize? autoSize = (width: 1920, height: 1080);

  /// Whether a seek shows its frame by itself
  bool autoRestartOnSeek = true;

  /// While set, [setVolume] waits for it: the test lands a dispose or a stop in the middle of an open
  Completer<void>? holdVolume;

  void emit(PlayerEventKind kind, [String? message]) => _events.add(PlayerEvent(kind, message));

  /// libmpv's part of an open: the file is loaded, its duration and size are known, a frame is shown
  void load(Duration length, {VideoFrameSize? size = (width: 1920, height: 1080)}) {
    emit(PlayerEventKind.loaded);
    duration.value = length;
    videoSize.value = size;
    hasVideo.value = size != null;
    emit(PlayerEventKind.restarted);
  }

  @override
  Future<void> open(String resource, {Duration start = Duration.zero, bool streamed = false}) async {
    calls.add('open $resource at ${start.inMilliseconds}${streamed ? ' streamed' : ''}');
    this.resource = resource;
    completed.value = false;
    position.value = start;
    videoSize.value = null;
    hasVideo.value = null;
    final length = autoLoad;
    if (length != null) {
      scheduleMicrotask(() => load(length, size: autoSize));
    }
  }

  @override
  Future<void> play() async {
    calls.add('play');
    playing.value = true;
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    playing.value = false;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    resource = null;
    playing.value = false;
    position.value = Duration.zero;
    duration.value = Duration.zero;
    videoSize.value = null;
    hasVideo.value = null;
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek ${position.inMilliseconds}');
    this.position.value = position;
    if (autoRestartOnSeek) {
      scheduleMicrotask(() => emit(PlayerEventKind.restarted));
    }
  }

  @override
  Future<void> setRate(double rate) async => this.rate = rate;

  @override
  Future<void> setVolume(double volume) async {
    await holdVolume?.future;
    this.volume = volume;
  }

  @override
  Future<void> setLoop(bool loop) async => this.loop = loop;

  @override
  Future<void> setAudioTrack(String id) async {
    calls.add('audio $id');
    audioTrack.value = id;
  }

  @override
  Future<Uint8List?> grabFrame(FrameBox box) async {
    boxes.add(box);
    return frame;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }
}

/// A pool of fake players, which keeps every player it made
class FakePlayers {
  FakePlayers({Map<PlayerKind, int>? maxPlayers, int maxIdle = 1, this.onCreate}) {
    pool = PlayerPool(
      create: (kind) async {
        final engine = FakePlaybackEngine(kind, made.length + 1);
        onCreate?.call(engine);
        made.add(engine);
        return engine;
      },
      maxPlayers: maxPlayers,
      maxIdle: maxIdle,
    );
  }

  late final PlayerPool pool;
  final made = <FakePlaybackEngine>[];
  final void Function(FakePlaybackEngine engine)? onCreate;
}
