// The camera of macOS for the head tracking of Spatial 2.5D (lot S7): without NSCameraUsageDescription in the app's
// Info.plist macOS ends the app the first time it opens a camera, and the sandboxed Debug profile needs the camera
// entitlement (Release carries it too, ready for the hardened runtime of notarisation). This keeps both in place, and
// the text of the system's prompt within the app's rules for user text.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The string value of [key] in the property list [text], null when absent
String? plistString(String text, String key) =>
    RegExp('<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>').firstMatch(text)?.group(1);

bool plistTrue(String text, String key) => RegExp('<key>${RegExp.escape(key)}</key>\\s*<true/>').hasMatch(text);

void main() {
  test('Info.plist says what the camera is for', () {
    final plist = File('macos/Runner/Info.plist').readAsStringSync();
    final text = plistString(plist, 'NSCameraUsageDescription');
    expect(text, isNotNull, reason: 'macOS ends the app at the first camera open without it');
    expect(text, contains('Spatial 2.5D'));
    expect(text, contains('never saved or sent'));
    for (final word in ['experimental', 'beta', 'preview', 'test build']) {
      expect(text!.toLowerCase(), isNot(contains(word)));
    }
    expect(text, isNot(matches(RegExp('[–—]| - '))));
  });

  test('both entitlement files allow the camera', () {
    for (final name in ['DebugProfile', 'Release']) {
      final entitlements = File('macos/Runner/$name.entitlements').readAsStringSync();
      expect(plistTrue(entitlements, 'com.apple.security.device.camera'), isTrue, reason: name);
    }
    // The sandbox of the Debug profile is what makes the entitlement needed there
    expect(
      plistTrue(File('macos/Runner/DebugProfile.entitlements').readAsStringSync(), 'com.apple.security.app-sandbox'),
      isTrue,
    );
  });

  test('the runner tells Dart when the session locks and the displays sleep', () {
    final window = File('macos/Runner/MainFlutterWindow.swift').readAsStringSync();
    expect(window, contains('SessionPresenceChannel.shared.attach(to: flutterViewController)'));
    for (final name in [
      'com.apple.screenIsLocked',
      'com.apple.screenIsUnlocked',
      'screensDidSleepNotification',
      'screensDidWakeNotification',
      '"immuch360/session"',
    ]) {
      expect(window, contains(name));
    }
  });
}
