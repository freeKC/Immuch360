// What the Spatial 2.5D player of the computers keeps from one video to the next: what moves the viewpoint (the head
// through the webcam, the mouse, or the slider and the arrow keys alone), the head sensitivity, the webcam picked in its
// menu, whether the head's direction is reversed (a webcam whose own software mirrors its pictures), and whether the
// user agreed to the webcam: Windows asks nothing before a desktop app opens it, so the page says what it is for and
// asks once, before the first time. A small JSON file next to the app's other desktop settings (desktop_spatial.json in the application
// support folder), as the 360° renderer keeps its choice (sphere_renderer.dart). Nothing of the camera's pictures is
// ever written: only these choices.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('SpatialSettings');

/// What moves the viewpoint of the Spatial player
enum SpatialViewpointSource {
  /// The head, followed through the webcam (the phones' way)
  head,

  /// The mouse over the picture, for a computer without a webcam or a person who prefers it
  mouse,

  /// The slider and the arrow keys only
  manual,
}

/// The choices of the Spatial player, see the top of this file
@immutable
class DesktopSpatialSettings {
  const DesktopSpatialSettings({
    this.source = SpatialViewpointSource.head,
    this.sensitivity = HeadViewpoint.desktopSensitivity,
    this.cameraId,
    this.cameraAgreed = false,
    this.reverseHead = false,
  });

  final SpatialViewpointSource source;

  /// The head sensitivity, [HeadViewpoint.minSensitivity] to [HeadViewpoint.maxSensitivity]; the desktop starts at
  /// [HeadViewpoint.desktopSensitivity], the user sitting further from the screen than from a phone
  final double sensitivity;

  /// The symbolic link of the webcam picked in the menu, null for the default one (never an infrared camera)
  final String? cameraId;

  /// The user chose the webcam: "Use the webcam" on the card of the first time, or head tracking in the menu. Until
  /// then the page asks before it opens the webcam.
  final bool cameraAgreed;

  /// The head's direction reversed (troubleshooting, for a webcam that mirrors its own pictures)
  final bool reverseHead;

  DesktopSpatialSettings copyWith({
    SpatialViewpointSource? source,
    double? sensitivity,
    String? cameraId,
    bool? cameraAgreed,
    bool? reverseHead,
  }) => DesktopSpatialSettings(
    source: source ?? this.source,
    sensitivity: sensitivity ?? this.sensitivity,
    cameraId: cameraId ?? this.cameraId,
    cameraAgreed: cameraAgreed ?? this.cameraAgreed,
    reverseHead: reverseHead ?? this.reverseHead,
  );

  Map<String, Object?> toJson() => {
    'source': source.name,
    'sensitivity': sensitivity,
    'camera': ?cameraId,
    'cameraAgreed': cameraAgreed,
    'reverseHead': reverseHead,
  };

  /// The settings of [json]; anything missing or out of range takes its default
  factory DesktopSpatialSettings.fromJson(Object? json) {
    if (json is! Map) {
      return const DesktopSpatialSettings();
    }
    final source = SpatialViewpointSource.values.where((value) => value.name == json['source']).firstOrNull;
    final sensitivity = json['sensitivity'];
    final camera = json['camera'];
    return DesktopSpatialSettings(
      source: source ?? SpatialViewpointSource.head,
      sensitivity: sensitivity is num && sensitivity.isFinite
          ? sensitivity.toDouble().clamp(HeadViewpoint.minSensitivity, HeadViewpoint.maxSensitivity)
          : HeadViewpoint.desktopSensitivity,
      cameraId: camera is String && camera.isNotEmpty ? camera : null,
      cameraAgreed: json['cameraAgreed'] == true,
      reverseHead: json['reverseHead'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DesktopSpatialSettings &&
      other.source == source &&
      other.sensitivity == sensitivity &&
      other.cameraId == cameraId &&
      other.cameraAgreed == cameraAgreed &&
      other.reverseHead == reverseHead;

  @override
  int get hashCode => Object.hash(source, sensitivity, cameraId, cameraAgreed, reverseHead);

  @override
  String toString() =>
      'DesktopSpatialSettings(${source.name}, sensitivity $sensitivity, camera ${cameraId ?? 'default'}'
      '${cameraAgreed ? ', webcam agreed' : ''}${reverseHead ? ', head reversed' : ''})';
}

/// Where [DesktopSpatialSettings] are kept, see the top of this file
abstract final class DesktopSpatialSettingsStore {
  static const fileName = 'desktop_spatial.json';

  /// Where the file lives; a temporary folder in the tests
  @visibleForTesting
  static Future<Directory> Function() folder = getApplicationSupportDirectory;

  static Future<DesktopSpatialSettings>? _loaded;

  /// The settings, read once then kept
  static Future<DesktopSpatialSettings> load() => _loaded ??= _read();

  @visibleForTesting
  static void forget() => _loaded = null;

  static Future<DesktopSpatialSettings> _read() async {
    try {
      final file = File(p.join((await folder()).path, fileName));
      if (!file.existsSync()) {
        return const DesktopSpatialSettings();
      }
      return DesktopSpatialSettings.fromJson(jsonDecode(await file.readAsString()));
    } catch (error) {
      // A damaged file gives the defaults rather than an error at each Spatial video
      _log.warning('The Spatial settings could not be read, defaults instead: $error');
      return const DesktopSpatialSettings();
    }
  }

  /// Keeps [settings] for this session at once, and on the disk in the background
  static Future<void> save(DesktopSpatialSettings settings) async {
    _loaded = Future.value(settings);
    try {
      final file = File(p.join((await folder()).path, fileName));
      await file.parent.create(recursive: true);
      // Written beside, then renamed over: a crash in the middle leaves the previous settings, not half a file
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(settings.toJson()), flush: true);
      await temporary.rename(file.path);
    } catch (error) {
      _log.warning('The Spatial settings are kept for this session only: $error');
    }
  }
}
