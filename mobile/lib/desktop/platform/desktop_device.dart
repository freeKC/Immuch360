import 'package:flutter/foundation.dart';

/// What the server lists a session of Immuch360 Desktop under: the app and the operating system, never the
/// computer's own name, which often holds the user's name
const desktopDeviceModel = 'Immuch360 Desktop';

String desktopDeviceType() => switch (defaultTargetPlatform) {
  TargetPlatform.windows => 'Windows',
  TargetPlatform.macOS => 'macOS',
  TargetPlatform.linux => 'Linux',
  _ => 'Unknown',
};
