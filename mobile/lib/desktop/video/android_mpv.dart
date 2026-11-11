// libmpv on Android, in the Meta Quest build only for release 46 (FreeKC, 11 November 2026: the Quest first, phones and
// TVs after the size of their packages is weighed). The native side is in the quest flavour of the Android app
// (src/quest: media_kit_video's texture output and the helper of media_kit_libs_android_video, MIT, and the libmpv of
// media-kit's libmpv-android-video-build, LGPL, a dynamic library): the phone flavour has none of it, and its channel
// does not answer there, so this says no.
//
// The players are those of the computers (DesktopPlayer, PlayerPool, MediaKitVideoPlayerController of lib/desktop/
// video), with their own options: hwdec mediacodec-copy, the device's hardware decoder whose frames mpv copies back
// and draws on the Flutter texture (vo gpu, which media_kit_video sets on Android). mpv decodes in software, with
// FFmpeg, what the hardware refuses, stream by stream: a DTS track, a DivX 3 video. mediacodec without copy needs
// vo mediacodec_embed, a surface of its own that the Flutter texture of media_kit does not give: not used.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';

final _log = Logger('AndroidMpv');

abstract final class AndroidMpv {
  /// Answered by the quest flavour only (MpvPlayers.kt): whether libmpv loaded
  static const channel = MethodChannel('immuch360/mpv');

  /// Hardware video decoding kept, the frames copied to the texture (see the top of this file)
  static const hwdec = 'mediacodec-copy';

  static Future<bool>? _ready;
  static PlayerPool? _pool;

  /// Whether this build plays with libmpv: asked once, then MediaKit set up
  static Future<bool> ready() => _ready ??= _start();

  static Future<bool> _start() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      final loaded = await channel.invokeMethod<bool>('available') ?? false;
      if (!loaded) {
        _log.info('libmpv is in this build but did not load');
        return false;
      }
      MediaKit.ensureInitialized();
      _log.info('libmpv is ready');
      return true;
    } on MissingPluginException {
      // The phone flavour: no libmpv in this build
      return false;
    } catch (error) {
      _log.warning('libmpv could not be set up: $error');
      return false;
    }
  }

  /// The players of the network page on the Quest: one that plays at a time, one kept idle for the next film
  static PlayerPool get pool => _pool ??= PlayerPool(
    create: (kind) => DesktopPlayer.create(kind, hwdec: hwdec, measureDecoding: false),
    maxPlayers: const {PlayerKind.playback: 1, PlayerKind.thumbnail: 0, PlayerKind.live: 0},
  );
}

/// Whether this build plays films with libmpv (the Meta Quest build of release 46)
final androidMpvAvailableProvider = FutureProvider<bool>((ref) => AndroidMpv.ready());
