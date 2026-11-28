// "Share with Windows…" and "Share with macOS…" of the Share menu of a computer (desktop_share.dart): the share window
// of the system for files of this computer. Linux has none; its menu offers Copy and Save to a folder instead.
//
// - Windows: the channel immuch360/share of the runner (windows/runner/share_channel.cpp, share_sheet.cpp), which
//   opens each file before the window shows (a missing or unreadable file fails at once, with the reason Windows
//   gives), hands the files to the window when it asks for them, and tells when a program was chosen and when the
//   window let the files go. share_plus 10.1.4 answered before the window asked and logged nothing: desktop build 35
//   deleted a fetched file in that answer, so the window found no file (the probe of the share in the desktop
//   workflow, lot share 54).
// - macOS: share_plus, whose picker answers once a service is chosen (its name) or the picker is closed (empty).
//
// The files stay until [SystemShare.finished]: the window, or the program chosen in it, reads them after the answer.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:share_plus/share_plus.dart';

/// The channel of the Windows runner
const desktopShareChannel = MethodChannel('immuch360/share');

/// How long the share window of Windows may take to ask for the files once it was opened: it asked within 1.3 s on the
/// runners of the desktop workflow
const systemShareRequestTimeout = Duration(seconds: 20);

/// Why the share window did not take the files: [step] says where it failed ("activation", "window", "file", "show",
/// "request", "picker"), [code] the HRESULT of Windows when there is one, [reason] the text of the system, and [file]
/// the name of the file for "file" (never its folder)
class SystemShareException implements Exception {
  const SystemShareException(this.step, this.reason, {this.code, this.file});

  final String step;
  final String reason;
  final String? code;
  final String? file;

  @override
  String toString() =>
      'SystemShareException($step${code == null ? '' : ' $code'}${file == null ? '' : ' $file'}: $reason)';
}

/// How a share ended
enum SystemShareEnd {
  /// A program or a service was chosen
  shared,

  /// The window was closed without a choice: nothing to tell the user
  dismissed,
}

/// A share under way: [opened] completes once the window took the files (or throws a [SystemShareException]),
/// [finished] once it, and the program chosen in it, let them go
class SystemShare {
  SystemShare({required this.opened, required this.finished});

  final Future<void> opened;
  final Future<SystemShareEnd> finished;

  /// The name of the program chosen, when the system tells it
  String? target;
}

/// The share window of this computer
abstract interface class SystemShareSheet {
  /// Whether this computer has a share window the app can open
  Future<bool> supported();

  /// Opens the window for [paths], files of this computer, under [title]; [origin] is where the user clicked, which
  /// the macOS picker points to
  SystemShare share(List<String> paths, {required String title, Rect? origin});
}

/// The share window of the system this app runs on, null on Linux
SystemShareSheet? systemShareSheetHere() {
  if (CurrentPlatform.isWindows) {
    return WindowsShareSheet();
  }
  if (CurrentPlatform.isMacOS) {
    return const MacShareSheet();
  }
  return null;
}

/// The share window of Windows through the runner's channel
class WindowsShareSheet implements SystemShareSheet {
  WindowsShareSheet({this._channel = desktopShareChannel, this._requestTimeout = systemShareRequestTimeout});

  final MethodChannel _channel;
  final Duration _requestTimeout;

  /// The shares waiting for their events, by the number the runner gave them
  static final Map<int, _WindowsShare> _shares = {};
  static MethodChannel? _listening;

  void _listen() {
    if (identical(_listening, _channel)) {
      return;
    }
    _listening = _channel;
    _channel.setMethodCallHandler((call) async {
      final arguments = call.arguments;
      if (arguments is! Map) {
        return null;
      }
      if (call.method == 'observed') {
        final elapsed = arguments['elapsedMs'];
        final existing = arguments['existing'];
        observedShareRequests.add((
          elapsedMs: elapsed is num ? elapsed.toDouble() : -1,
          existing: existing is int ? existing : -1,
        ));
        return null;
      }
      if (call.method != 'event') {
        return null;
      }
      final share = arguments['share'];
      final event = arguments['event'];
      final detail = arguments['detail'];
      if (share is int && event is String) {
        _shares[share]?.onEvent(event, detail is String ? detail : '');
      }
      return null;
    });
  }

  /// For the tests of the desktop workflow: the next request of the share window that is not one of this app's (one
  /// of share_plus) comes on [observedShareRequests], with how many of [paths] still existed then
  @visibleForTesting
  Future<void> observeNextRequest(List<String> paths) async {
    _listen();
    await _channel.invokeMethod<void>('observeNextRequest', {'paths': paths});
  }

  @override
  Future<bool> supported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  SystemShare share(List<String> paths, {required String title, Rect? origin}) {
    _listen();
    final opened = Completer<void>();
    final finished = Completer<SystemShareEnd>();
    final result = SystemShare(opened: opened.future, finished: finished.future);
    unawaited(() async {
      final int? number;
      try {
        number = await _channel.invokeMethod<int>('shareFiles', {'paths': paths, 'title': title});
      } on PlatformException catch (error) {
        final details = error.details;
        final index = details is Map ? details['index'] : null;
        final failure = SystemShareException(
          error.code,
          error.message ?? '',
          code: details is Map && details['hresult'] is String ? details['hresult'] as String : null,
          file: index is int && index >= 0 && index < paths.length ? _nameOf(paths[index]) : null,
        );
        opened.completeError(failure);
        finished.complete(SystemShareEnd.dismissed);
        return;
      } on MissingPluginException catch (error) {
        opened.completeError(SystemShareException('activation', error.message ?? 'No share channel'));
        finished.complete(SystemShareEnd.dismissed);
        return;
      }
      if (number == null) {
        opened.completeError(const SystemShareException('show', 'The runner gave no share'));
        finished.complete(SystemShareEnd.dismissed);
        return;
      }
      _shares[number] = _WindowsShare(result, opened, finished, () => _shares.remove(number));
      unawaited(
        Future<void>.delayed(_requestTimeout, () {
          if (!opened.isCompleted) {
            _shares.remove(number);
            opened.completeError(const SystemShareException('request', 'The share window did not ask for the files'));
            finished.complete(SystemShareEnd.dismissed);
          }
        }),
      );
    }());
    // Nobody waits for the failure twice: the caller reads it from [opened]
    unawaited(opened.future.then<void>((_) {}, onError: (Object _) {}));
    return result;
  }
}

class _WindowsShare {
  _WindowsShare(this.share, this.opened, this.finished, this.forget);

  final SystemShare share;
  final Completer<void> opened;
  final Completer<SystemShareEnd> finished;
  final VoidCallback forget;

  void onEvent(String event, String detail) {
    switch (event) {
      case 'requested':
        if (!opened.isCompleted) {
          opened.complete();
        }
      case 'target':
        if (detail.isNotEmpty) {
          share.target = detail;
        }
      case 'destroyed':
        forget();
        if (!opened.isCompleted) {
          opened.complete();
        }
        if (!finished.isCompleted) {
          finished.complete(share.target == null ? SystemShareEnd.dismissed : SystemShareEnd.shared);
        }
    }
  }
}

/// The share picker of macOS through share_plus
class MacShareSheet implements SystemShareSheet {
  const MacShareSheet({this._share});

  final Future<ShareResult> Function(List<XFile> files, Rect? origin)? _share;

  @override
  Future<bool> supported() async => true;

  @override
  SystemShare share(List<String> paths, {required String title, Rect? origin}) {
    final files = [for (final path in paths) XFile(path)];
    final asked = (_share ?? _sharePlus)(files, origin);
    final opened = Completer<void>();
    final finished = Completer<SystemShareEnd>();
    final result = SystemShare(opened: opened.future, finished: finished.future);
    unawaited(
      asked.then<void>(
        (answer) {
          if (answer.status == ShareResultStatus.success && answer.raw.isNotEmpty) {
            result.target = answer.raw;
          }
          opened.complete();
          finished.complete(
            answer.status == ShareResultStatus.dismissed ? SystemShareEnd.dismissed : SystemShareEnd.shared,
          );
        },
        onError: (Object error) {
          opened.completeError(
            SystemShareException('picker', error is PlatformException ? (error.message ?? error.code) : '$error'),
          );
          finished.complete(SystemShareEnd.dismissed);
        },
      ),
    );
    unawaited(opened.future.then<void>((_) {}, onError: (Object _) {}));
    return result;
  }

  static Future<ShareResult> _sharePlus(List<XFile> files, Rect? origin) =>
      Share.shareXFiles(files, sharePositionOrigin: origin);
}

String _nameOf(String path) {
  final slash = path.lastIndexOf(RegExp(r'[\\/]'));
  return slash < 0 ? path : path.substring(slash + 1);
}

/// The requests of the share window of Windows that were not the app's, as the runner saw them: how long after
/// [WindowsShareSheet.observeNextRequest] and how many of its files still existed (the tests of the desktop workflow)
@visibleForTesting
final observedShareRequests = StreamController<({double elapsedMs, int existing})>.broadcast();

/// For the tests: no share is waiting any more
@visibleForTesting
void resetWindowsShares() {
  WindowsShareSheet._shares.clear();
  WindowsShareSheet._listening = null;
}
