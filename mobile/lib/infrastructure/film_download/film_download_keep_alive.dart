// What keeps a film download alive on each platform, and the free room of its folder: the foreground service of
// Android through the FilmDownloadApi pigeon; nothing on iPhone and iPad (the copy runs while the app is open,
// decision 4 a of the Plex films study) nor on the computers, which keep running with the screen off.

import 'dart:async';
import 'dart:io';

import 'package:immich_mobile/desktop/ai/components/disk_space.dart';
import 'package:immich_mobile/platform/film_download_api.g.dart';
import 'package:logging/logging.dart';

final _log = Logger('FilmDownloadKeepAlive');

/// The texts of the notification of a running copy
typedef FilmDownloadNoticeTexts = ({String channelName, String title, String text, String pause, String cancel});

abstract interface class FilmDownloadKeepAlive {
  /// Shows the copy under way (starts the service when it does not run), [progress] in thousandths or -1
  Future<void> show(FilmDownloadNoticeTexts texts, int progress);

  /// No copy runs any more
  Future<void> stop();

  /// The bytes free where [folder] is, null when unknown
  Future<int?> freeBytes(Directory folder);

  /// The Pause and Cancel of the notification
  void listen({required void Function() onPause, required void Function() onCancel});
}

/// Android: the foreground service of FilmDownloadService.kt
class AndroidFilmDownloadKeepAlive implements FilmDownloadKeepAlive {
  AndroidFilmDownloadKeepAlive([FilmDownloadApi? api]) : _api = api ?? FilmDownloadApi();

  final FilmDownloadApi _api;
  bool _started = false;

  @override
  Future<void> show(FilmDownloadNoticeTexts texts, int progress) async {
    final notice = FilmDownloadNotice(
      channelName: texts.channelName,
      title: texts.title,
      text: texts.text,
      progress: progress,
      pauseLabel: texts.pause,
      cancelLabel: texts.cancel,
    );
    try {
      if (_started) {
        await _api.updateKeepAlive(notice);
      } else {
        _started = true;
        await _api.startKeepAlive(notice);
      }
    } catch (error) {
      _log.info('The film download service did not answer: ${error.runtimeType}');
    }
  }

  @override
  Future<void> stop() async {
    if (!_started) {
      return;
    }
    _started = false;
    try {
      await _api.stopKeepAlive();
    } catch (error) {
      _log.info('The film download service did not stop: ${error.runtimeType}');
    }
  }

  @override
  Future<int?> freeBytes(Directory folder) async {
    try {
      return await _api.freeBytes(folder.path);
    } catch (error) {
      _log.info('No free room known: ${error.runtimeType}');
      return null;
    }
  }

  @override
  void listen({required void Function() onPause, required void Function() onCancel}) =>
      FilmDownloadEvents.setUp(_Events(onPause, onCancel));
}

class _Events implements FilmDownloadEvents {
  const _Events(this._pause, this._cancel);

  final void Function() _pause;
  final void Function() _cancel;

  @override
  void pauseRequested() => _pause();

  @override
  void cancelRequested() => _cancel();
}

/// iPhone, iPad and the computers: nothing to keep alive; the computers tell their free room
class PlainFilmDownloadKeepAlive implements FilmDownloadKeepAlive {
  const PlainFilmDownloadKeepAlive({required this.isDesktop});

  final bool isDesktop;

  @override
  Future<void> show(FilmDownloadNoticeTexts texts, int progress) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<int?> freeBytes(Directory folder) async => isDesktop ? (await systemFreeSpace(folder))?.free : null;

  @override
  void listen({required void Function() onPause, required void Function() onCancel}) {}
}
