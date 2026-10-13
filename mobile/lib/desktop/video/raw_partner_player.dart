// The second player of a raw 360° file whose lenses are in two streams, played by two players (RawMode.paired in
// raw_two_streams.dart): the 360° page's player decodes stream 0 with the sound, this one stream 1 alone, each with
// its own decoder and without a copy, and renderer C draws the view from both (the media_kit_video plugin's
// IMMUCH360-NOTE.md, patch 7).
//
// This player follows the page's player: it plays and pauses with it and goes where it goes after a seek. The plugin
// does the rest: it draws each pair of frames of the same time together, and moves this player's speed a little
// above or below the page's player until its frames come with that player's. Anything that goes wrong here (the
// open, the decoding, renderer C, the pool taking the player for another page) is told through [failure], once, and
// the page takes the next step of its chain.

import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:logging/logging.dart';

final _log = Logger('RawPartnerPlayer');

/// See the top of this file
class RawPartnerPlayer {
  RawPartnerPlayer({required PlayerPool pool, required this._setMpv, required this._pluginFor}) {
    _lease = pool.lease(PlayerKind.playback, label: '360 video, second stream', onSuspend: _onSuspend);
  }

  late final PlayerLease _lease;
  final Future<void> Function(PlaybackEngine engine, String name, String value) _setMpv;
  final PluginRenderer? Function(PlaybackEngine engine) _pluginFor;

  PlaybackEngine? _engine;
  PluginRenderer? _renderer;
  void Function()? _unfollow;
  bool _released = false;

  /// Why this player stopped serving its pair, once it did: the page takes the next step of its chain
  final failure = ValueNotifier<String?>(null);

  /// The player, once [start] got one
  PlaybackEngine? get engine => _engine;

  /// Renderer C of this player, attached as the second player of the pair, once [start] answered
  PluginRenderer? get renderer => _renderer;

  /// Opens [resource] (a path of this computer or a media bridge URL) with mpv's video track [videoTrack] alone and no
  /// sound, paused at [start], draws it through renderer C as the second player of a pair at [tier], then follows
  /// [primary]. Null once ready, else why not.
  Future<String?> start({
    required PlaybackEngine primary,
    required String resource,
    required int videoTrack,
    required Duration start,
    required PluginTier tier,
  }) async {
    if (_released) {
      return 'released';
    }
    final PlaybackEngine engine;
    try {
      // Never the player of the pair's first stream, which may still be opening, and so not playing
      engine = await _lease.acquire(sparing: primary);
    } catch (error) {
      return 'no second player: $error';
    }
    if (_released || !identical(_lease.engine, engine)) {
      return 'the second player was taken';
    }
    _engine = engine;
    try {
      await _lease.guard(() async {
        // The other stream alone, decoded by the GPU without a copy where it can, no sound and no subtitles
        await _setMpv(engine, 'lavfi-complex', '');
        await _setMpv(engine, 'external-files', '');
        await _setMpv(engine, 'hwdec', DesktopPlayerOptions.hwdec);
        await _setMpv(engine, 'vid', '$videoTrack');
        await _setMpv(engine, 'aid', 'no');
        await _setMpv(engine, 'sid', 'no');
        await _setMpv(engine, 'speed', '1');
      });
    } catch (error) {
      return 'mpv refused the options of the second player: ${redactPlayerText('$error')}';
    }
    final renderer = _pluginFor(engine);
    if (renderer == null) {
      return 'the second player has no texture';
    }
    final attached = await renderer.attach(
      projection: const PluginProjection.secondary(),
      outputSize: const Size(2, 2),
      tier: tier,
    );
    if (!attached.ok) {
      return 'renderer C refused the second player: ${attached.reason}';
    }
    _renderer = renderer;
    if (_released) {
      return 'released';
    }
    final failed = engine.events.listen((event) {
      if (event.kind == PlayerEventKind.failed) {
        _fail('the second stream failed: ${event.message ?? 'no reason given'}');
      }
    });
    try {
      await _lease.guard(() => engine.open(resource, start: start, streamed: resource.startsWith('http')));
    } catch (error) {
      await failed.cancel();
      return 'the second stream did not open: ${redactPlayerText('$error')}';
    }
    _follow(primary, engine, failed);
    return null;
  }

  // Plays and pauses with [primary], and goes where it goes after a seek
  void _follow(PlaybackEngine primary, PlaybackEngine engine, StreamSubscription<PlayerEvent> failed) {
    void onPlaying() {
      if (_released || !identical(_engine, engine)) {
        return;
      }
      unawaited(primary.playing.value ? engine.play() : engine.pause());
    }

    final restarted = primary.events.listen((event) {
      if (event.kind == PlayerEventKind.restarted && !_released && identical(_engine, engine)) {
        unawaited(engine.seek(primary.position.value));
      }
    });
    primary.playing.addListener(onPlaying);
    _unfollow = () {
      primary.playing.removeListener(onPlaying);
      unawaited(restarted.cancel());
      unawaited(failed.cancel());
    };
    onPlaying();
  }

  void _fail(String reason) {
    if (failure.value != null || _released) {
      return;
    }
    _log.info('Second player: $reason');
    failure.value = reason;
  }

  // The pool gives this player to another page: the pair cannot go on, and the player leaves as the pool gave it
  // (renderer C off, every stream and the sound back, speed 1), since the pool resets none of those; it stops it next
  Future<void> _onSuspend() async {
    final engine = _engine;
    final renderer = _renderer;
    _engine = null;
    _renderer = null;
    _unfollow?.call();
    _unfollow = null;
    _fail('the pool took the second player');
    try {
      await renderer?.dispose();
      if (engine != null) {
        await _giveBack(engine);
      }
    } catch (error) {
      _log.fine('The second player went to another page as it was: $error');
    }
  }

  // The options [start] changed, back to the pool's
  Future<void> _giveBack(PlaybackEngine engine) async {
    await _setMpv(engine, 'vid', 'auto');
    await _setMpv(engine, 'aid', 'auto');
    await _setMpv(engine, 'sid', 'auto');
    await _setMpv(engine, 'speed', '1');
  }

  /// Ends the pair and gives the player back to the pool, as the pool gave it (renderer C off, every stream and the
  /// sound back, speed 1)
  Future<void> release() async {
    if (_released) {
      return;
    }
    _released = true;
    _unfollow?.call();
    _unfollow = null;
    final engine = _engine;
    _engine = null;
    final renderer = _renderer;
    _renderer = null;
    try {
      await renderer?.dispose();
      if (engine != null && identical(_lease.engine, engine)) {
        await _lease.guard(() async {
          await engine.stop();
          await _giveBack(engine);
        });
      }
    } catch (error) {
      _log.fine('The second player was given back as it was: $error');
    }
    await _lease.release();
    failure.dispose();
  }
}
