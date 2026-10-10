// The GPU in use and what its hardware video decoder takes (design 2.7), read through the immuch_desktop_video plugin
// on Windows: the Direct3D 11 decoder profiles of the default adapter, which is the GPU the app's video renders and
// decodes on (Windows picks it from the per app graphics preference when the process starts, so it does not change
// while the app runs and one probe per run is enough). Linux and macOS have no probe yet (plan 20, phase 4): no GPU is
// known there, and the decoder answers follow the static rule of DesktopVideoDecoderApi.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immuch_desktop_video/immuch_desktop_video.dart';
import 'package:logging/logging.dart';

final _log = Logger('DesktopGpuDecoders');

/// A call of the plugin: the decoders of the GPU in use, with the sizes of [sizes] checked for the profiles of
/// [profiles] (GUIDs, all when null), and the frame rates when [rates]
typedef DecoderProber =
    Future<D3D11DecoderProbe> Function({Iterable<String>? profiles, Iterable<(int, int)> sizes, bool rates});

abstract final class DesktopGpuDecoders {
  /// The plugin's probe on Windows, none elsewhere; the tests give their own
  @visibleForTesting
  static DecoderProber? prober = CurrentPlatform.isWindows ? _probeWindows : null;

  /// Longest wait for a probe: a driver that does not answer leaves the static rule in place
  static const timeout = Duration(seconds: 10);

  static Future<D3D11DecoderProbe?>? _decoders;
  static final _checks = <String, Future<bool?>>{};

  static Future<D3D11DecoderProbe> _probeWindows({
    Iterable<String>? profiles,
    Iterable<(int, int)> sizes = const [],
    bool rates = false,
  }) => D3D11Decoders.probe(profiles: profiles, sizes: sizes, rates: rates);

  /// The profiles whose sizes are worth asking the driver about: those the app knows (the rest are image codecs and
  /// the partial acceleration modes of the first DXVA decoders)
  static Iterable<String> get _knownProfiles => d3d11Profiles.map((profile) => profile.guid);

  /// The decoders of the GPU in use, with the sizes of [ladderSizes] checked and the frame rate at the largest, for
  /// the decoders page and the answers; null where there is no probe, or when it failed. Read once per run.
  static Future<D3D11DecoderProbe?> decoders() => _decoders ??= _read();

  /// The GPU in use, null where it is not known
  static Future<GpuAdapter?> adapter() async => (await decoders())?.adapter;

  static Future<D3D11DecoderProbe?> _read() async {
    final probe = prober;
    if (probe == null) {
      return null;
    }
    try {
      final found = await probe(profiles: _knownProfiles, sizes: ladderSizes, rates: true).timeout(timeout);
      final known = found.profiles.where((profile) => d3d11ProfileInfo(profile.guid) != null).length;
      _log.info(
        'GPU in use: ${found.adapter}, ${found.profiles.length} decoder profiles ($known known), '
        'Direct3D 12 rates ${found.d3d12 ? 'asked' : 'not available'}${found.error == null ? '' : ', ${found.error}'}',
      );
      return found;
    } catch (error) {
      _log.warning('The decoders of the GPU could not be read, the static rule answers: $error');
      return null;
    }
  }

  /// Whether the profile [guid] of the GPU in use takes a frame of [width] x [height] (a coded size, see codedSize):
  /// from the probe when that size was in its ladder, else asked once and kept. Null when nothing could tell.
  static Future<bool?> accepts(String guid, int width, int height) async {
    final decoders = await DesktopGpuDecoders.decoders();
    final profile = decoders?.profile(guid);
    if (profile == null) {
      return decoders == null ? null : false;
    }
    final known = profile.accepts(width, height);
    if (known != null) {
      return known;
    }
    return _checks['$guid ${width}x$height'] ??= _check(guid, width, height);
  }

  static Future<bool?> _check(String guid, int width, int height) async {
    final probe = prober;
    if (probe == null) {
      return null;
    }
    try {
      final found = await probe(profiles: [guid], sizes: [(width, height)]).timeout(timeout);
      return found.profile(guid)?.accepts(width, height);
    } catch (error) {
      _log.info('Could not ask the GPU about $guid at ${width}x$height: $error');
      return null;
    }
  }

  /// Forgets what was read, for the tests
  @visibleForTesting
  static void forget() {
    _decoders = null;
    _checks.clear();
  }
}
