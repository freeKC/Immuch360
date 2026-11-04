// The WebView2 SDK and wil of the splat viewer's window on the licence page of Windows (review of 2 November 2026):
// the texts of the entries are those of the files in the copy of desktop_webview_window, and the entries name them.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/splat/splat_window_licenses.dart';

String _lines(String text) => text.replaceAll('\r\n', '\n').split('\n').map((line) => line.trim()).join('\n').trim();

void main() {
  const folder = 'packages/desktop_webview_window/windows';

  test('the texts are those of the files next to the WebView2 SDK and wil', () {
    expect(_lines(webView2SdkLicense), _lines(File('$folder/WebView2-SDK-LICENSE.txt').readAsStringSync()));
    expect(_lines(wilLicense), _lines(File('$folder/wil/LICENSE').readAsStringSync()));
    expect(_lines(wilThirdPartyNotices), _lines(File('$folder/wil/ThirdPartyNotices.txt').readAsStringSync()));
  });

  test('the headers and the loader of the copy are those the licence covers', () {
    final options = File('$folder/WebView2EnvironmentOptions.h').readAsStringSync();
    expect(options, contains('Copyright (C) Microsoft Corporation'));
    expect(options, contains('BSD-style license'));
    expect(options, contains('L"94.0.992.28"'));
    expect(File('$folder/WebView2.h').readAsStringSync(), contains('webview2.idl'));
    expect(File('$folder/libs/x64/WebView2Loader.dll').existsSync(), isTrue);
    expect(
      File('packages/desktop_webview_window/IMMUCH360-NOTE.md').readAsStringSync(),
      contains('WebView2-SDK-LICENSE.txt'),
    );
  });

  test('two entries, each saying what it does in the app before its text', () async {
    final entries = await splatWindowLicenseEntries().toList();
    expect(entries.map((entry) => entry.packages.single), [
      'Microsoft Edge WebView2 SDK',
      'Windows Implementation Libraries (wil)',
    ]);
    final texts = entries.map((entry) => entry.paragraphs.map((paragraph) => paragraph.text).join('\n')).toList();
    expect(texts[0], startsWith('WebView2 SDK 1.0.992.28: the window of the splat viewer'));
    expect(texts[0], contains('Redistribution and use in source and binary forms'));
    expect(texts[1], contains('MIT License'));
    expect(texts[1], contains('Libc++'));
  });
}
