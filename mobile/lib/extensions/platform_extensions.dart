import 'package:flutter/foundation.dart';

extension CurrentPlatform on TargetPlatform {
  @pragma('vm:prefer-inline')
  static bool get isIOS => defaultTargetPlatform == TargetPlatform.iOS;

  @pragma('vm:prefer-inline')
  static bool get isAndroid => defaultTargetPlatform == TargetPlatform.android;

  // The desktop gates read defaultTargetPlatform, never dart:io's Platform: under flutter test it answers android
  // unless debugDefaultTargetPlatformOverride says otherwise, so both sides of a gate can be tested on any machine.
  // In profile and release builds, as defaultTargetPlatform itself, they are constants of the compiler: a desktop
  // branch is then removed before the tree shaking, with the classes only it creates, so the phones do not carry the
  // desktop code. Inlining alone removed the branch but kept the methods of those classes.
  @pragma('vm:platform-const-if', !kDebugMode)
  @pragma('vm:prefer-inline')
  static bool get isWindows => defaultTargetPlatform == TargetPlatform.windows;

  @pragma('vm:platform-const-if', !kDebugMode)
  @pragma('vm:prefer-inline')
  static bool get isMacOS => defaultTargetPlatform == TargetPlatform.macOS;

  @pragma('vm:platform-const-if', !kDebugMode)
  @pragma('vm:prefer-inline')
  static bool get isLinux => defaultTargetPlatform == TargetPlatform.linux;

  /// Windows, macOS or Linux: Immuch360 Desktop, started from lib/main_desktop.dart
  @pragma('vm:platform-const-if', !kDebugMode)
  @pragma('vm:prefer-inline')
  static bool get isDesktop => isWindows || isMacOS || isLinux;
}
