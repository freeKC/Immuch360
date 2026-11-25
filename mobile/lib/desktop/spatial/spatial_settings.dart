// What the Spatial 2.5D views of the computers keep from one picture to the next: what moves the view (the head through
// the webcam, the mouse, the automatic sway, or the keys alone), whether the webcam may be used for head tracking at
// all, whether the user said yes on the card that explains it, the webcam picked in its menu, whether the head's
// direction is reversed (a webcam whose own software mirrors its pictures) and the sensitivity. They are settings of
// the app (ViewerConfig.spatialInput and the fields after it), so that a backup of the settings carries them. Nothing
// of the camera's pictures is ever written: only these choices.

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';

/// The choices of the Spatial 2.5D views, see the top of this file
@immutable
class DesktopSpatialSettings {
  const DesktopSpatialSettings({
    this.input,
    this.webcam = true,
    this.consent = false,
    this.cameraId,
    this.reverseHead = false,
    this.sensitivity = HeadViewpoint.desktopSensitivity,
  });

  /// The settings of the app's viewer configuration
  factory DesktopSpatialSettings.fromViewer(ViewerConfig viewer) => DesktopSpatialSettings(
    input: inputOf(viewer.spatialInput),
    webcam: viewer.spatialWebcam,
    consent: viewer.spatialWebcamConsent,
    cameraId: viewer.spatialCamera == null || viewer.spatialCamera!.isEmpty ? null : viewer.spatialCamera,
    reverseHead: viewer.spatialReverseHead,
    sensitivity: (viewer.spatialSensitivity / 10).clamp(HeadViewpoint.minSensitivity, HeadViewpoint.maxSensitivity),
  );

  /// What moves the view, null until the user picks one: the head when a webcam may be used, else the mouse
  final ViewerInput? input;

  /// "Use the webcam for head tracking": off, the webcam never opens and the head input falls back to the mouse
  final bool webcam;

  /// The user said yes on the card that explains the webcam; until then the webcam does not open
  final bool consent;

  /// The webcam picked in the menu, null for the default one (never an infrared camera)
  final String? cameraId;

  final bool reverseHead;

  /// [HeadViewpoint.minSensitivity] to [HeadViewpoint.maxSensitivity]
  final double sensitivity;

  /// The input the view starts with: the one picked, else the head when the webcam may be used, else the mouse
  ViewerInput get startInput => input ?? (webcam ? ViewerInput.head : ViewerInput.mouse);

  /// The stored name of an input
  static String nameOf(ViewerInput input) => input.name;

  /// The input of a stored name, null for none or an unknown one
  static ViewerInput? inputOf(String? name) => ViewerInput.values.where((input) => input.name == name).firstOrNull;

  DesktopSpatialSettings copyWith({
    ViewerInput? input,
    bool? webcam,
    bool? consent,
    String? cameraId,
    bool clearCamera = false,
    bool? reverseHead,
    double? sensitivity,
  }) => DesktopSpatialSettings(
    input: input ?? this.input,
    webcam: webcam ?? this.webcam,
    consent: consent ?? this.consent,
    cameraId: clearCamera ? null : cameraId ?? this.cameraId,
    reverseHead: reverseHead ?? this.reverseHead,
    sensitivity: (sensitivity ?? this.sensitivity).clamp(HeadViewpoint.minSensitivity, HeadViewpoint.maxSensitivity),
  );

  @override
  bool operator ==(Object other) =>
      other is DesktopSpatialSettings &&
      other.input == input &&
      other.webcam == webcam &&
      other.consent == consent &&
      other.cameraId == cameraId &&
      other.reverseHead == reverseHead &&
      other.sensitivity == sensitivity;

  @override
  int get hashCode => Object.hash(input, webcam, consent, cameraId, reverseHead, sensitivity);

  @override
  String toString() =>
      'DesktopSpatialSettings(${input?.name ?? 'default'}, webcam ${webcam ? 'allowed' : 'off'}'
      '${consent ? ', agreed' : ''}, camera ${cameraId ?? 'default'}${reverseHead ? ', head reversed' : ''}, '
      'sensitivity $sensitivity)';
}

/// Reads and writes the settings: the app's settings repository, a field in the tests
abstract class DesktopSpatialSettingsStore {
  DesktopSpatialSettings read();

  Future<void> write(DesktopSpatialSettings settings);
}

/// [DesktopSpatialSettingsStore] over the app's settings
class AppSpatialSettingsStore implements DesktopSpatialSettingsStore {
  const AppSpatialSettingsStore();

  @override
  DesktopSpatialSettings read() => DesktopSpatialSettings.fromViewer(SettingsRepository.instance.appConfig.viewer);

  @override
  Future<void> write(DesktopSpatialSettings settings) async {
    final repository = SettingsRepository.instance;
    final input = settings.input;
    await repository.write(.viewerSpatialInput, input == null ? null : DesktopSpatialSettings.nameOf(input));
    await repository.write(.viewerSpatialWebcam, settings.webcam);
    await repository.write(.viewerSpatialWebcamConsent, settings.consent);
    await repository.write(.viewerSpatialCamera, settings.cameraId);
    await repository.write(.viewerSpatialReverseHead, settings.reverseHead);
    await repository.write(.viewerSpatialSensitivity, (settings.sensitivity * 10).round());
  }
}
