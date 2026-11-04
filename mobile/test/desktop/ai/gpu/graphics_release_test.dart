// What the app lets go of the graphics card before a job of the AI features on it (issue #13): the players of videos
// that do not play and the pictures of the image cache, with the count of each, the pictures on screen left to their
// widgets; only closed players are worth a wait for their memory; nothing without a pool, and a pool that fails lets
// the pictures go all the same.

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/gpu/graphics_release.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';

import '../../video/fake_playback_engine.dart';

/// A picture of [width] x [height] put in [cache] under [key], as a decoded image of the app
Future<void> _cached(ImageCache cache, Object key, int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint());
  final image = await recorder.endRecording().toImage(width, height);
  final completer = OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image)));
  cache.putIfAbsent(key, () => completer);
  // The cache sizes an image once it is loaded and its listener gone
  final listener = ImageStreamListener((_, _) {});
  completer.addListener(listener);
  await Future<void>.delayed(Duration.zero);
  completer.removeListener(listener);
}

class _FailingPool extends PlayerPool {
  _FailingPool() : super(create: (kind) async => throw StateError('no player'));

  @override
  Future<int> releaseForGraphicsJob() async => throw StateError('the pool failed');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the paused players and the cached pictures go, counted', () async {
    final players = FakePlayers();
    final paused = players.pool.lease(PlayerKind.playback, label: 'paused');
    await paused.acquire();
    final cache = ImageCache();
    await _cached(cache, 'grid', 64, 32);
    expect(cache.currentSizeBytes, 64 * 32 * 4);

    final released = await releaseAppGraphics(pool: players.pool, images: cache);

    expect(released.players, 1);
    expect(released.pictureBytes, 64 * 32 * 4);
    expect(released.settles, isTrue);
    expect(cache.currentSizeBytes, 0);
    expect(cache.currentSize, 0);
    expect(players.made.single.disposed, isTrue);
    expect('$released', '1 video players closed, 8192 bytes of pictures dropped');
  });

  test('nothing held: nothing let go, nothing to wait for', () async {
    final released = await releaseAppGraphics(pool: FakePlayers().pool, images: ImageCache());
    expect(released.settles, isFalse);
    expect((await releaseAppGraphics()).settles, isFalse);
    expect(GraphicsRelease.nothing.settles, isFalse);
  });

  test('the pictures on screen stay live: only the cache lets go, and pictures alone are no reason to wait', () async {
    final cache = ImageCache();
    await _cached(cache, 'grid', 16, 16);
    // A 360° photo on screen: its widget still listens to it
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 32, 32), Paint());
    final image = await recorder.endRecording().toImage(32, 32);
    final shown = OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image)));
    cache.putIfAbsent('sphere', () => shown);
    shown.addListener(ImageStreamListener((_, _) {}));
    await Future<void>.delayed(Duration.zero);
    expect(cache.liveImageCount, 1);

    final released = await releaseAppGraphics(pool: FakePlayers().pool, images: cache);

    expect(released.pictureBytes, greaterThan(0));
    expect(cache.currentSize, 0, reason: 'the cache let go of its entries');
    expect(cache.liveImageCount, 1, reason: 'clearLiveImages would only make the picture on screen decode again');
    expect(released.settles, isFalse);
    expect(const GraphicsRelease(pictureBytes: 128 << 20).settles, isFalse);
    expect(const GraphicsRelease(players: 1).settles, isTrue);
  });

  test('a pool that fails: the pictures go all the same', () async {
    final cache = ImageCache();
    await _cached(cache, 'grid', 8, 8);

    final released = await releaseAppGraphics(pool: _FailingPool(), images: cache);

    expect(released.players, 0);
    expect(released.pictureBytes, 8 * 8 * 4);
    expect(cache.currentSizeBytes, 0);
  });
}
