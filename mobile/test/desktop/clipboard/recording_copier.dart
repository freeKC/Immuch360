// The fakes of the tests of the copy: a copier for the menus and Control C, which keeps what it was asked to copy and
// touches no clipboard, and a clipboard that keeps what it was given.

import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/clipboard/clipboard_copies.dart';
import 'package:immich_mobile/desktop/clipboard/clipboard_copy.dart';
import 'package:immich_mobile/desktop/clipboard/desktop_clipboard.dart';

class RecordingCopier extends ClipboardCopier {
  final copies = <List<ClipboardSource>>[];

  @override
  Future<ClipboardCopyResult> copy(
    List<ClipboardSource> sources, {
    Future<void>? cancelled,
    ClipboardFetchProgress? onProgress,
  }) async {
    copies.add(sources);
    return (files: sources.length, picture: false);
  }
}

/// A clipboard that keeps what it was given
class FakeDesktopClipboard implements DesktopClipboard {
  final writes = <ClipboardPayload>[];
  final texts = <String>[];
  var _token = 100;
  bool refuse = false;

  int get token => _token;

  @override
  Future<int> writeFiles(ClipboardPayload payload) async {
    if (refuse) {
      throw PlatformException(code: 'clipboard', message: 'held by another program');
    }
    writes.add(payload);
    return ++_token;
  }

  @override
  Future<bool> holds(int token) async => token == _token;

  @override
  Future<void> writeText(String text) async => texts.add(text);
}
