// Which renderer draws the 360° player of the computers, and at which tier (design 2.3 and 2.8, decision DP1 of
// 2026-10-09, docs 20-desktop-dp1.md section 4.3):
// - renderer C (render/plugin_renderer.dart) first, at the start tier of its GPU (full on a dedicated one, 2880 on an
//   integrated one), then, once the video's first frame tells what kind of video it is, at the tier the renderer
//   probe kept for that kind of video on this GPU and this version of the app;
// - a tier down each time the probe says the current one does not keep up (render/renderer_probe.dart);
// - the flat player, with a message, when C cannot start (no OpenGL ES 3.0, no shared texture) or does not keep up
//   even at its lowest tier.
//
// What the probe kept is per kind of video (codec, size, frame rate and decoding path, see sphereVideoClass), since
// the cost of a frame depends on the video as much as on the GPU: a 5.7K H.264 video the processor decodes says
// nothing of a 4K HEVC one the GPU decodes without copy. A video that played flat is never shown flat from memory:
// the next one of its kind starts at the lowest tier and is measured again, so that a busy moment does not turn the
// 360° view off for good. Picking Automatic in the settings forgets every measure.
// Renderer B (a Flutter shader around the texture) is not in the chain yet: its fragment shader would be an asset of
// the phone builds too (flutter: shaders: has no per platform list), and the phones must not change. Renderer A (an
// mpv hook) is not built at all: DP1 measured it rebuilding mpv's passes at each view change.
//
// The user can force a renderer in Settings, Advanced, with the troubleshooting on: Automatic, the plugin at one of
// its tiers, or flat. The choice and what the probe kept live in desktop_video_renderer.json in the app's support
// folder, outside the main database, whose schema stays the phones'.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('SphereRenderer');

/// The renderer choice of the troubleshooting settings
enum SphereRendererChoice {
  automatic,
  pluginFull,
  plugin4096,
  plugin2880,
  flat;

  /// The tier the plugin is forced to, null for [automatic] and [flat]
  PluginTier? get forcedTier => switch (this) {
    SphereRendererChoice.pluginFull => PluginTier.full,
    SphereRendererChoice.plugin4096 => PluginTier.w4096,
    SphereRendererChoice.plugin2880 => PluginTier.w2880,
    _ => null,
  };
}

/// Why a 360° video plays flat
enum FlatReason {
  /// The user chose it in the troubleshooting settings
  chosen,

  /// No renderer exists on this computer: Linux and macOS until phase 4
  unsupported,

  /// The plugin refused (no OpenGL ES 3.0, software rendering, no texture yet)
  refused,

  /// The probe measured that even the lowest tier does not keep up with the video
  tooSlow,
}

/// What draws a 360° player: renderer C at [tier], or the flat player for [flatReason]
@immutable
class SphereRendering {
  const SphereRendering.plugin(PluginTier this.tier) : flatReason = null;

  const SphereRendering.flat(FlatReason this.flatReason) : tier = null;

  final PluginTier? tier;
  final FlatReason? flatReason;

  bool get isFlat => flatReason != null;

  @override
  bool operator ==(Object other) => other is SphereRendering && other.tier == tier && other.flatReason == flatReason;

  @override
  int get hashCode => Object.hash(tier, flatReason);

  @override
  String toString() => isFlat ? 'flat (${flatReason!.name})' : 'plugin ${tier!.name}';
}

/// The kind of video a measure of the probe holds for: the codec as mpv names it, the size, the frame rate rounded,
/// and the decoding path (hwdec-current: "software" for "no", "copy" for a copy back such as "d3d11va-copy",
/// "hardware" for the rest). Null when the size is not known.
String? sphereVideoClass({
  required String? codec,
  required int? width,
  required int? height,
  required double? framesPerSecond,
  required String? hwdec,
}) {
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  final path = switch (hwdec?.trim() ?? '') {
    '' => 'unknown',
    'no' => 'software',
    final name when name.endsWith('-copy') => 'copy',
    _ => 'hardware',
  };
  final rate = framesPerSecond == null || framesPerSecond <= 0 ? '?' : '${framesPerSecond.round()}';
  final name = codec?.trim() ?? '';
  return '${name.isEmpty ? '?' : name} ${width}x$height $rate fps $path';
}

/// What the renderer probe kept for one kind of video on this computer: the tier that kept up (null: the video
/// played flat, nothing kept up) with the GPU, the version of the app and the kind of video it was measured with
@immutable
class RememberedRendering {
  const RememberedRendering({
    required this.appVersion,
    required this.glRenderer,
    required this.tier,
    this.videoClass,
    this.reason,
    this.framesPerSecond,
    this.targetFramesPerSecond,
    this.hwdec,
  });

  static RememberedRendering? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final appVersion = json['appVersion'];
    final glRenderer = json['glRenderer'];
    if (appVersion is! String || glRenderer is! String) {
      return null;
    }
    final tierName = json['tier'];
    return RememberedRendering(
      appVersion: appVersion,
      glRenderer: glRenderer,
      tier: PluginTier.values.where((tier) => tier.name == tierName).firstOrNull,
      videoClass: json['videoClass'] as String?,
      reason: json['reason'] as String?,
      framesPerSecond: (json['framesPerSecond'] as num?)?.toDouble(),
      targetFramesPerSecond: (json['targetFramesPerSecond'] as num?)?.toDouble(),
      hwdec: json['hwdec'] as String?,
    );
  }

  final String appVersion;
  final String glRenderer;

  /// Null: the probe found that no tier kept up with this video, which played flat. Never applied as flat to the
  /// next video (see the top of this file).
  final PluginTier? tier;

  /// The kind of video it was measured on (sphereVideoClass); null for a measure that applies to no video
  final String? videoClass;

  /// Why the probe went down a tier, for the troubleshooting page
  final String? reason;
  final double? framesPerSecond;
  final double? targetFramesPerSecond;

  /// mpv's hwdec-current while measured: "d3d11va" (no copy), "d3d11va-copy", "nvdec", or "no" for software
  final String? hwdec;

  Map<String, Object?> toJson() => {
    'appVersion': appVersion,
    'glRenderer': glRenderer,
    'tier': tier?.name,
    'videoClass': videoClass,
    'reason': reason,
    'framesPerSecond': framesPerSecond,
    'targetFramesPerSecond': targetFramesPerSecond,
    'hwdec': hwdec,
  };

  /// Whether this applies to a video of [videoClass] drawn by [glRenderer] in [appVersion]: another kind of video,
  /// another GPU or another version is measured again
  bool appliesTo({required String appVersion, required String? glRenderer, required String? videoClass}) =>
      this.videoClass != null &&
      this.videoClass == videoClass &&
      this.appVersion == appVersion &&
      this.glRenderer == glRenderer;

  /// Whether this and [other] hold for the same kind of video on the same GPU and version
  bool sameKindAs(RememberedRendering other) =>
      other.videoClass == videoClass && other.appVersion == appVersion && other.glRenderer == glRenderer;
}

/// The renderer settings of this computer, see the top of this file
@immutable
class SphereRendererSettings {
  const SphereRendererSettings({this.choice = SphereRendererChoice.automatic, this.measured = const []});

  /// The most kinds of video kept: the oldest goes first
  static const maxMeasured = 32;

  final SphereRendererChoice choice;

  /// What the probe kept, one entry per kind of video, GPU and version of the app, the newest last
  final List<RememberedRendering> measured;

  /// What the probe measured last, for the troubleshooting page
  RememberedRendering? get remembered => measured.lastOrNull;

  /// What the probe kept for a video of [videoClass] drawn by [glRenderer] in [appVersion], null when it was not
  /// measured
  RememberedRendering? rememberedFor({
    required String appVersion,
    required String? glRenderer,
    required String? videoClass,
  }) => measured.lastWhereOrNull(
    (entry) => entry.appliesTo(appVersion: appVersion, glRenderer: glRenderer, videoClass: videoClass),
  );

  /// [choice], every measure forgotten when it is Automatic: the user asks the probe to measure again
  SphereRendererSettings withChoice(SphereRendererChoice choice) =>
      SphereRendererSettings(choice: choice, measured: choice == SphereRendererChoice.automatic ? const [] : measured);

  /// [entry] kept in place of an older one of the same kind; the measures of other versions of the app go, as they
  /// never apply again
  SphereRendererSettings remembering(RememberedRendering entry) {
    final kept = [
      for (final other in measured)
        if (other.appVersion == entry.appVersion && !other.sameKindAs(entry)) other,
      entry,
    ];
    return SphereRendererSettings(
      choice: choice,
      measured: List.unmodifiable(kept.length > maxMeasured ? kept.sublist(kept.length - maxMeasured) : kept),
    );
  }
}

/// Reads and writes [SphereRendererSettings] in desktop_video_renderer.json, see the top of this file
abstract final class SphereRendererStore {
  static const fileName = 'desktop_video_renderer.json';

  /// Where the file lives; a temporary folder in the tests
  @visibleForTesting
  static Future<Directory> Function() folder = getApplicationSupportDirectory;

  static Future<SphereRendererSettings>? _loaded;

  /// The settings, read once then kept
  static Future<SphereRendererSettings> load() => _loaded ??= _read();

  /// Keeps the choice of the troubleshooting settings; what the probe kept stays, except for Automatic, which
  /// measures again
  static Future<void> saveChoice(SphereRendererChoice choice) async => _save((await load()).withChoice(choice));

  /// Keeps what the probe measured for one kind of video
  static Future<void> remember(RememberedRendering remembered) async => _save((await load()).remembering(remembered));

  @visibleForTesting
  static void forget() => _loaded = null;

  static Future<SphereRendererSettings> _read() async {
    try {
      final file = File(p.join((await folder()).path, fileName));
      if (!file.existsSync()) {
        return const SphereRendererSettings();
      }
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) {
        return const SphereRendererSettings();
      }
      final choiceName = json['choice'];
      final measured = json['measured'];
      return SphereRendererSettings(
        choice:
            SphereRendererChoice.values.where((choice) => choice.name == choiceName).firstOrNull ??
            SphereRendererChoice.automatic,
        // The single measure of the first test builds ("remembered") held for every video: left out, measured again
        measured: List.unmodifiable([
          if (measured is List)
            for (final entry in measured) ?RememberedRendering.fromJson(entry),
        ]),
      );
    } catch (error) {
      // A damaged file is Automatic, measured again, rather than an error at each 360° video
      _log.warning('The 360° renderer settings could not be read, automatic choice instead: $error');
      return const SphereRendererSettings();
    }
  }

  static Future<void> _save(SphereRendererSettings settings) async {
    _loaded = Future.value(settings);
    try {
      final file = File(p.join((await folder()).path, fileName));
      await file.parent.create(recursive: true);
      // Written beside, then renamed over: a crash in the middle leaves the previous settings, not half a file
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'choice': settings.choice.name,
          'measured': [for (final entry in settings.measured) entry.toJson()],
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    } catch (error) {
      _log.warning('The 360° renderer settings are kept for this session only: $error');
    }
  }
}

/// The first rendering of a 360° player, before the plugin is asked: flat when the user chose it or nothing exists
/// here, else the plugin at the forced tier, or null for the plugin at the tier [tierAfterAttach] decides once the GPU
/// is known
SphereRendering? firstRendering(SphereRendererSettings settings, {required bool pluginSupported}) {
  if (settings.choice == SphereRendererChoice.flat) {
    return const SphereRendering.flat(FlatReason.chosen);
  }
  if (!pluginSupported) {
    return const SphereRendering.flat(FlatReason.unsupported);
  }
  final forced = settings.choice.forcedTier;
  return forced == null ? null : SphereRendering.plugin(forced);
}

/// The tier for a video of [videoClass] once its first frame tells what it is, the plugin attached on [glRenderer] at
/// [startTier] (its GPU's start tier): a forced tier as it is; else what the probe kept for that kind of video on this
/// GPU and this version of the app, the lowest tier for one that played flat (measured again, see the top of this
/// file); else [startTier].
PluginTier tierForVideo(
  SphereRendererSettings settings, {
  required PluginTier startTier,
  required String? glRenderer,
  required String appVersion,
  required String? videoClass,
}) {
  final forced = settings.choice.forcedTier;
  if (forced != null) {
    return forced;
  }
  final remembered = settings.rememberedFor(appVersion: appVersion, glRenderer: glRenderer, videoClass: videoClass);
  if (remembered == null) {
    return startTier;
  }
  return remembered.tier ?? PluginTier.values.lastWhere((tier) => tier.lower == null);
}

/// Where the probe goes when [current] does not keep up: the next tier down, flat below the lowest. A forced tier
/// never moves: the user asked for it, to compare.
SphereRendering stepDown(SphereRendering current, SphereRendererChoice choice) {
  final tier = current.tier;
  if (tier == null || choice.forcedTier != null) {
    return current;
  }
  final lower = tier.lower;
  return lower == null ? const SphereRendering.flat(FlatReason.tooSlow) : SphereRendering.plugin(lower);
}
