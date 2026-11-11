// The GPU in use and what its hardware video decoder takes (design 2.7), read through the immuch_desktop_video plugin
// on Windows: the Direct3D 11 decoder profiles of the default adapter, which is the GPU the app's video renders and
// decodes on (Windows picks it from the per app graphics preference when the process starts, so it does not change
// while the app runs and one probe per run is enough). Linux and macOS have no probe yet (plan 20, phase 4): no GPU is
// known there, and the decoder answers follow the static rule of DesktopVideoDecoderApi.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/video/video_gpu.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immuch_desktop_video/immuch_desktop_video.dart';
import 'package:logging/logging.dart';
import 'package:media_kit_video/sphere.dart';

final _log = Logger('DesktopGpuDecoders');

/// A call of the plugin: the decoders of the GPU in use, with the sizes of [sizes] checked for the profiles of
/// [profiles] (GUIDs, all when null), and the frame rates when [rates]
typedef DecoderProber =
    Future<D3D11DecoderProbe> Function({Iterable<String>? profiles, Iterable<(int, int)> sizes, bool rates});

/// A call of the plugin: the GPUs of the computer, and the ones Windows gives the high performance and the minimum
/// power preference (GpuList)
typedef GpuLister = Future<GpuList> Function();

abstract final class DesktopGpuDecoders {
  /// The plugin's probe on Windows, none elsewhere; the tests give their own
  @visibleForTesting
  static DecoderProber? prober = CurrentPlatform.isWindows ? _probeWindows : null;

  /// The plugin's list of the GPUs on Windows, none elsewhere; the tests give their own
  @visibleForTesting
  static GpuLister? lister = CurrentPlatform.isWindows ? _listWindows : null;

  /// Longest wait for a probe: a driver that does not answer leaves the static rule in place
  static const timeout = Duration(seconds: 10);

  static Future<D3D11DecoderProbe?>? _decoders;
  static Future<GpuList?>? _gpus;
  static final _checks = <String, Future<bool?>>{};

  // Whether a failed probe was asked again: once per run
  static bool _retried = false;

  // Whether a failed list of the GPUs was asked again: once per run
  static bool _listRetried = false;

  static Future<D3D11DecoderProbe> _probeWindows({
    Iterable<String>? profiles,
    Iterable<(int, int)> sizes = const [],
    bool rates = false,
  }) => D3D11Decoders.probe(profiles: profiles, sizes: sizes, rates: rates);

  static Future<GpuList> _listWindows() => D3D11Decoders.gpus();

  /// The profiles whose sizes are worth asking the driver about: those the app knows (the rest are image codecs and
  /// the partial acceleration modes of the first DXVA decoders)
  static Iterable<String> get _knownProfiles => d3d11Profiles.map((profile) => profile.guid);

  /// The decoders of the GPU in use, with the sizes of [ladderSizes] checked and the frame rate at the largest, for
  /// the decoders page and the answers; null where there is no probe, or when it failed. Read once per run.
  static Future<D3D11DecoderProbe?> decoders() => _decoders ??= _read();

  /// The GPU in use, null where it is not known
  static Future<GpuAdapter?> adapter() async => (await decoders())?.adapter;

  /// The GPU in use as renderer C (package:media_kit_video/sphere.dart) takes it for its start tier, null where it is
  /// not known: the package reads no GPU of its own
  static Future<PluginGpu?> pluginAdapter() async => (await adapter())?.toPlugin();

  /// The GPUs of the computer and the ones Windows prefers, null where nothing lists them or the list failed. Read once
  /// per run, without any device made on the GPUs, and once more after a failure; the first read logs them with the one
  /// in use.
  static Future<GpuList?> gpus() => _gpus ??= _list();

  /// What a choice of the card for a video needs (video_gpu.dart): the GPU in use and the GPUs of the computer
  static Future<VideoMachine> machine() async => (inUse: await adapter(), gpus: await gpus());

  static Future<GpuList?> _list() async {
    final list = lister;
    if (list == null) {
      return null;
    }
    try {
      final found = await list().timeout(timeout);
      final inUse = await adapter();
      String described(GpuAdapter gpu) {
        final roles = [
          if (gpu.luid.isNotEmpty && gpu.luid == found.highPerformance) 'high performance',
          if (gpu.luid.isNotEmpty && gpu.luid == found.minimumPower) 'power saving',
          if (gpu.software) 'software',
          if (inUse != null && sameGpu(gpu, inUse)) 'in use',
        ];
        return roles.isEmpty ? gpu.name : '${gpu.name} (${roles.join(', ')})';
      }

      _log.info(
        'Graphics cards: ${found.adapters.map(described).join('; ')}${found.error == null ? '' : ', ${found.error}'}',
      );
      return found;
    } catch (error) {
      _log.info('The graphics cards could not be listed: $error');
      // As the probe below: the first start of a new build may time out while the antivirus scans it, which left the
      // Video decoding line without its advice for that whole run
      if (!_listRetried) {
        _listRetried = true;
        _gpus = null;
      }
      return null;
    }
  }

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
      // The probe of the start can fail while a new build is still scanned by the antivirus (seen at the first start
      // of CI builds, before the log was ready): the next question asks the GPU once more
      if (!_retried) {
        _retried = true;
        _decoders = null;
      }
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
    _gpus = null;
    _retried = false;
    _listRetried = false;
    _checks.clear();
  }
}

/// The GPU of DXGI as renderer C of media_kit_video takes it: its name, its device id and its kind
extension GpuAdapterPlugin on GpuAdapter {
  PluginGpu toPlugin() => PluginGpu(name: name, deviceId: deviceId, integrated: integrated, software: software);
}
