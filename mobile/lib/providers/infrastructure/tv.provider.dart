// Android TV and Google TV: whether this device is a TV, read once before the first frame (see main.dart), and whether
// the remote control layout is on (the setting, Automatic by default: on on a TV only).

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('TvMode');

final tvApiProvider = Provider<TvApi>((_) => TvApi());

/// What the platform told before the first frame; overridden in main() on Android. Not a TV everywhere else, the
/// tests included.
final tvDeviceProvider = Provider<TvDeviceInfo>((_) => TvDeviceInfo(isTelevision: false, isLowRamDevice: false));

/// What the platform tells of this device, for [tvDeviceProvider]: read before runApp so that the first screen is
/// already in TV mode. Not a TV on iOS, nor when Android cannot tell.
Future<TvDeviceInfo> readTvDeviceInfo({TvApi? api}) async {
  final notATelevision = TvDeviceInfo(isTelevision: false, isLowRamDevice: false);
  if (!Platform.isAndroid) {
    return notATelevision;
  }
  try {
    return await (api ?? TvApi()).deviceInfo();
  } catch (error, stackTrace) {
    _log.warning('Could not tell whether this device is a TV', error, stackTrace);
    return notATelevision;
  }
}

/// Whether the remote control layout is on: the setting when it is On or Off, else whether this device is a TV.
/// Always off on iOS.
final tvModeProvider = Provider.autoDispose<bool>((ref) {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return false;
  }
  TvLayoutMode layout;
  try {
    layout = ref.watch(appConfigProvider.select((config) => config.tvLayout));
  } on StateError {
    // The settings are not loaded (the tests of pages that do not need them): the default, Automatic
    layout = TvLayoutMode.auto;
  }
  return switch (layout) {
    TvLayoutMode.on => true,
    TvLayoutMode.off => false,
    TvLayoutMode.auto => ref.watch(tvDeviceProvider).isTelevision,
  };
});

/// The app is a viewer: what the read only mode hides in the viewers and the app bars (share, upload, edit, add to an
/// album, delete, multi select) is hidden on a TV too, without the tab restrictions of the read only mode. Declares
/// its dependencies so that the scoped readonlyModeProvider of Timeline(readOnly: true) reaches it.
final viewOnlyProvider = Provider.autoDispose<bool>(
  (ref) => ref.watch(readonlyModeProvider) || ref.watch(tvModeProvider),
  dependencies: [readonlyModeProvider, tvModeProvider],
);
