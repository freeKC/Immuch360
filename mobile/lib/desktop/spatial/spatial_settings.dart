// What the head tracking of the Spatial 2.5D views keeps from one picture to the next: whether the webcam may be used at
// all, whether the user said yes on the card that explains it, and the webcam picked in its menu. They are settings of
// the app (ViewerConfig.spatialWebcam and the fields after it), so that a backup of the settings carries them. What
// moves the view, the sensitivity and the reversed direction are the view's settings, the same for every source
// (viewer_position.dart). Nothing of the camera's pictures is ever written: only these choices.

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';

/// The choices of the head tracking, see the top of this file
@immutable
class DesktopSpatialSettings {
  const DesktopSpatialSettings({this.webcam = true, this.consent = false, this.cameraId});

  /// The settings of the app's viewer configuration
  factory DesktopSpatialSettings.fromViewer(ViewerConfig viewer) => DesktopSpatialSettings(
    webcam: viewer.spatialWebcam,
    consent: viewer.spatialWebcamConsent,
    cameraId: viewer.spatialCamera == null || viewer.spatialCamera!.isEmpty ? null : viewer.spatialCamera,
  );

  /// "Use the webcam for head tracking": off, the webcam never opens and the view follows the mouse
  final bool webcam;

  /// The user said yes on the card that explains the webcam; until then the webcam does not open
  final bool consent;

  /// The webcam picked in the menu, null for the default one (never an infrared camera)
  final String? cameraId;

  DesktopSpatialSettings copyWith({bool? webcam, bool? consent, String? cameraId, bool clearCamera = false}) =>
      DesktopSpatialSettings(
        webcam: webcam ?? this.webcam,
        consent: consent ?? this.consent,
        cameraId: clearCamera ? null : cameraId ?? this.cameraId,
      );

  @override
  bool operator ==(Object other) =>
      other is DesktopSpatialSettings &&
      other.webcam == webcam &&
      other.consent == consent &&
      other.cameraId == cameraId;

  @override
  int get hashCode => Object.hash(webcam, consent, cameraId);

  @override
  String toString() =>
      'DesktopSpatialSettings(webcam ${webcam ? 'allowed' : 'off'}${consent ? ', agreed' : ''}, '
      'camera ${cameraId ?? 'default'})';
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
    await repository.write(.viewerSpatialWebcam, settings.webcam);
    await repository.write(.viewerSpatialWebcamConsent, settings.consent);
    await repository.write(.viewerSpatialCamera, settings.cameraId);
  }
}
