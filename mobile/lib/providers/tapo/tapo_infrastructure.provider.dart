// The parts of the Tapo protocol layer the camera pages call, as providers so that the tests of the pages replace them
// with fakes.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_camera_tester.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_clip_cache.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_session_cache.dart';

/// "Test the camera" of the camera form
final tapoCameraTesterProvider = Provider<TapoCameraTester>((_) => testTapoCamera);

/// The certificate a camera found at a new address shows, compared with the stored one before the address is saved
final tapoCertificateReaderProvider = Provider<TapoCertificateReader>((_) => readTapoCertificateSha256);

/// Deletes what was fetched from the camera of a source id, when the camera is removed
final tapoCameraCacheDeleterProvider = Provider<Future<void> Function(String sourceId)>(
  (_) =>
      (sourceId) => deleteTapoCameraCache(sourceId),
);

/// Forgets the refused password or the lockout remembered for the camera of a source id, when the user asks the camera
/// again (see TapoSessionCache)
final tapoRefusalsForgetterProvider = Provider<void Function(String sourceId)>(
  (_) => TapoSessionCache.instance.forgetRefusals,
);
