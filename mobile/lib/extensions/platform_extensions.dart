import 'package:flutter/foundation.dart';

extension CurrentPlatform on TargetPlatform {
  @pragma('vm:prefer-inline')
  static bool get isIOS => defaultTargetPlatform == TargetPlatform.iOS;

  @pragma('vm:prefer-inline')
  static bool get isAndroid => defaultTargetPlatform == TargetPlatform.android;

  // The desktop gates read defaultTargetPlatform, never dart:io's Platform: under flutter test it answers android
  // unless debugDefaultTargetPlatformOverride says otherwise, so both sides of a gate can be tested on any machine,
  // and it is a constant in release builds, so the phones do not carry the desktop branches.
  @pragma('vm:prefer-inline')
  static bool get isWindows => defaultTargetPlatform == TargetPlatform.windows;

  @pragma('vm:prefer-inline')
  static bool get isMacOS => defaultTargetPlatform == TargetPlatform.macOS;

  @pragma('vm:prefer-inline')
  static bool get isLinux => defaultTargetPlatform == TargetPlatform.linux;

  /// Windows, macOS or Linux: Immuch360 Desktop, started from lib/main_desktop.dart
  @pragma('vm:prefer-inline')
  static bool get isDesktop => isWindows || isMacOS || isLinux;
}
