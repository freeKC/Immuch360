import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/services/tiff_decoder.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// The code ImmersiveApi.open refuses with on a Meta Quest whose Android is older than the Meta Spatial SDK needs
/// (Android 13, see SpatialSdkSupport.kt): the viewer would end the app as it starts, so it does not start
const kImmersiveHorizonOsTooOld = 'horizon_os_too_old';

/// What to tell, in the words of [t], when the immersive viewer did not open because of [error]: update the headset
/// when its Horizon OS is too old, the TIFF of the headset that does not decode, or the plain message
String immersiveOpenFailedMessage(Translations t, Object error) => switch (error) {
  PlatformException(code: kImmersiveHorizonOsTooOld) => t.immersive_viewer_update_headset,
  TiffDecodeException() => t.tiff_cannot_decode,
  _ => t.immersive_viewer_open_failed,
};
