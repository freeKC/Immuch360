// Fakes of the watch progress tests: a native player the test drives, and the rows of the database in memory

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/watch_progress.dart';
import 'package:immich_mobile/infrastructure/repositories/watch_progress.repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:native_video_player/native_video_player.dart';

class _MockPlaybackInfo extends Mock implements PlaybackInfo {}

class _MockVideoInfo extends Mock implements VideoInfo {}

/// The native player of the viewer, driven by the test: it lands a seek at once, plays and pauses as asked, and tells
/// the viewer as Media3 does (status and position notifiers, a ready after loading)
class FakeNativePlayer extends Fake implements NativeVideoPlayerController {
  FakeNativePlayer({required this.durationMs});

  final int durationMs;
  int positionMs = 0;
  PlaybackStatus status = PlaybackStatus.paused;
  final calls = <String>[];
  VideoSource? _source;

  @override
  final onPlaybackReady = ChangeNotifier();
  @override
  final onPlaybackStatusChanged = ValueNotifier<PlaybackStatus>(PlaybackStatus.stopped);
  @override
  final onPlaybackPositionChanged = ValueNotifier<int>(0);
  @override
  final onPlaybackEnded = ChangeNotifier();
  @override
  final onError = ValueNotifier<String?>(null);
  @override
  final onTracksChanged = ChangeNotifier();

  @override
  VideoSource? get videoSource => _source;

  @override
  PlaybackInfo? get playbackInfo {
    final info = _MockPlaybackInfo();
    when(() => info.position).thenReturn(positionMs);
    when(() => info.status).thenReturn(status);
    return info;
  }

  @override
  VideoInfo? get videoInfo {
    final info = _MockVideoInfo();
    when(() => info.duration).thenReturn(durationMs);
    when(() => info.width).thenReturn(1920);
    when(() => info.height).thenReturn(1080);
    return info;
  }

  @override
  Future<void> loadVideoSource(VideoSource videoSource) async {
    calls.add('load');
    _source = videoSource;
  }

  /// The player is ready, at its start
  void ready() => onPlaybackReady.notifyListeners();

  /// The player is at [ms]
  void moveTo(int ms) {
    positionMs = ms;
    onPlaybackPositionChanged.value = ms;
  }

  @override
  Future<void> seekTo(int milliseconds) async {
    calls.add('seek $milliseconds');
    positionMs = milliseconds;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    status = PlaybackStatus.playing;
    // Reported after the call, as the platform does
    scheduleMicrotask(() => onPlaybackStatusChanged.value = status);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    status = PlaybackStatus.paused;
    // Reported after the call, as the platform does
    scheduleMicrotask(() => onPlaybackStatusChanged.value = status);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    status = PlaybackStatus.stopped;
    // Reported after the call, as the platform does
    scheduleMicrotask(() => onPlaybackStatusChanged.value = status);
  }

  @override
  Future<bool> isPlaying() async => status == PlaybackStatus.playing;

  @override
  Future<void> setLoop(bool loop) async => calls.add('loop $loop');

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<List<NativeVideoTrack>> getTracks({String? locale}) async => const [];
}

/// The rows of the watch progress, in memory, as the database would keep them
class MemoryWatchRows implements WatchProgressRepository {
  MemoryWatchRows(List<WatchProgress> rows) : saved = {for (final row in rows) row.key: row};

  final Map<String, WatchProgress> saved;
  var writes = 0;

  @override
  Future<List<WatchProgress>> load({int maxRows = watchProgressMaxRows}) async => saved.values.toList();

  @override
  Future<void> upsert(WatchProgress row) async {
    writes++;
    saved[row.key] = row;
  }

  @override
  Future<void> delete(String key) async {
    writes++;
    saved.remove(key);
  }

  @override
  Future<void> close() async {}
}
