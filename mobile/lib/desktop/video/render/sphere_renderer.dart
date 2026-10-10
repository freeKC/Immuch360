// Which renderer draws the 360° player of the computers, and at which tier (design 2.3 and 2.8, decision DP1 of
// 2026-10-09, docs 20-desktop-dp1.md section 4.3):
// - renderer C (render/plugin_renderer.dart) first, at the tier the renderer probe kept for this computer and this
//   version of the app, else at the start tier of its GPU (full on a dedicated one, 2880 on an integrated one);
// - a tier down each time the probe says the current one does not keep up (render/renderer_probe.dart);
// - the flat player, with a message, when C cannot start (no OpenGL ES 3.0, no shared texture) or does not keep up
//   even at its lowest tier.
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

/// What the renderer probe kept for this computer: the tier that kept up (null: flat, nothing kept up) with the GPU
/// and the version of the app it was measured with
@immutable
class RememberedRendering {
  const RememberedRendering({
    required this.appVersion,
    required this.glRenderer,
    required this.tier,
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
      reason: json['reason'] as String?,
      framesPerSecond: (json['framesPerSecond'] as num?)?.toDouble(),
      targetFramesPerSecond: (json['targetFramesPerSecond'] as num?)?.toDouble(),
      hwdec: json['hwdec'] as String?,
    );
  }

  final String appVersion;
  final String glRenderer;

  /// Null: the probe found that no tier keeps up, the videos play flat
  final PluginTier? tier;

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
    'reason': reason,
    'framesPerSecond': framesPerSecond,
    'targetFramesPerSecond': targetFramesPerSecond,
    'hwdec': hwdec,
  };

  /// Whether this applies to [glRenderer] in [appVersion]: another GPU or another version is measured again
  bool appliesTo({required String appVersion, required String? glRenderer}) =>
      this.appVersion == appVersion && this.glRenderer == glRenderer;
}

/// The renderer settings of this computer, see the top of this file
@immutable
class SphereRendererSettings {
  const SphereRendererSettings({this.choice = SphereRendererChoice.automatic, this.remembered});

  final SphereRendererChoice choice;
  final RememberedRendering? remembered;

  SphereRendererSettings copyWith({SphereRendererChoice? choice, RememberedRendering? remembered}) =>
      SphereRendererSettings(choice: choice ?? this.choice, remembered: remembered ?? this.remembered);
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

  /// Keeps the choice of the troubleshooting settings; what the probe kept stays
  static Future<void> saveChoice(SphereRendererChoice choice) async => _save((await load()).copyWith(choice: choice));

  /// Keeps what the probe measured
  static Future<void> remember(RememberedRendering remembered) async =>
      _save((await load()).copyWith(remembered: remembered));

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
      return SphereRendererSettings(
        choice:
            SphereRendererChoice.values.where((choice) => choice.name == choiceName).firstOrNull ??
            SphereRendererChoice.automatic,
        remembered: RememberedRendering.fromJson(json['remembered']),
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
        jsonEncode({'choice': settings.choice.name, 'remembered': settings.remembered?.toJson()}),
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

/// The rendering once the plugin attached on [glRenderer] at [startTier] (its GPU's start tier): what the probe kept
/// for this GPU and this version of the app, else [startTier]. A forced tier stays as it is.
SphereRendering tierAfterAttach(
  SphereRendererSettings settings, {
  required PluginTier startTier,
  required String? glRenderer,
  required String appVersion,
}) {
  final forced = settings.choice.forcedTier;
  if (forced != null) {
    return SphereRendering.plugin(forced);
  }
  final remembered = settings.remembered;
  if (remembered != null && remembered.appliesTo(appVersion: appVersion, glRenderer: glRenderer)) {
    final tier = remembered.tier;
    return tier == null ? const SphereRendering.flat(FlatReason.tooSlow) : SphereRendering.plugin(tier);
  }
  return SphereRendering.plugin(startTier);
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
