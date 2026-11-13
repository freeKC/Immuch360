// What keeps a film download alive on each platform, what tells its progress and its end, and the free room of its
// folder: the foreground service of Android through the FilmDownloadApi pigeon, with its ongoing notification and the
// notification left at the end of a copy; on iPhone and iPad a local notification at the end only (the copy runs while
// the app is open, decision 4 a of the Plex films study, so there is no progress to show outside the app); nothing on
// the computers, which keep running with the screen off and whose app shows the progress itself.

import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:immich_mobile/desktop/ai/components/disk_space.dart';
import 'package:immich_mobile/domain/services/film_download/film_download_link.dart';
import 'package:immich_mobile/platform/film_download_api.g.dart';
import 'package:logging/logging.dart';

final _log = Logger('FilmDownloadKeepAlive');

/// The texts of the notification of a running copy; [subText] beside the name of the app (the speed)
typedef FilmDownloadNoticeTexts = ({
  String channelName,
  String title,
  String text,
  String? subText,
  String pause,
  String cancel,
});

/// The texts of the notification left at the end of a copy; [actionLabel] and [actionLink] a button (Retry, Resume)
typedef FilmDownloadEndTexts = ({
  String channelName,
  String title,
  String text,
  String? actionLabel,
  String? actionLink,
});

abstract interface class FilmDownloadKeepAlive {
  /// Shows the copy under way (starts the service when it does not run), [progress] in thousandths or -1; [waiting]
  /// while it waits for the Wi-Fi, the service then holding no lock
  Future<void> show(FilmDownloadNoticeTexts texts, int progress, {bool waiting = false});

  /// No copy runs nor waits any more
  Future<void> stop();

  /// The notification of the end of the copy of [filmId], in place of an earlier one of the same film
  Future<void> showEnd(String filmId, FilmDownloadEndTexts texts);

  /// Takes away the end notification of [filmId]
  Future<void> cancelEnd(String filmId);

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
  Future<void> show(FilmDownloadNoticeTexts texts, int progress, {bool waiting = false}) async {
    final notice = FilmDownloadNotice(
      channelName: texts.channelName,
      title: texts.title,
      text: texts.text,
      progress: progress,
      pauseLabel: texts.pause,
      cancelLabel: texts.cancel,
      subText: texts.subText,
      waiting: waiting,
      openLink: filmDownloadsLink,
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
  Future<void> showEnd(String filmId, FilmDownloadEndTexts texts) async {
    try {
      await _api.showEnd(
        FilmDownloadEndNotice(
          channelName: texts.channelName,
          filmId: filmId,
          title: texts.title,
          text: texts.text,
          openLink: filmDownloadsLink,
          actionLabel: texts.actionLabel,
          actionLink: texts.actionLink,
        ),
      );
    } catch (error) {
      _log.info('The end of a film download was not shown: ${error.runtimeType}');
    }
  }

  @override
  Future<void> cancelEnd(String filmId) async {
    try {
      await _api.cancelEnd(filmId);
    } catch (error) {
      _log.info('The end of a film download was not taken away: ${error.runtimeType}');
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

/// The id of the local notification of the end of the copy of [filmId] on iPhone and iPad: the first 7 digits of its
/// random hexadecimal id above 0x10000000, out of the ids of the other notifications, so that one film keeps one
/// notification (a 32 bit id, as both platforms want)
int filmDownloadLocalNotificationId(String filmId) {
  final head = filmId.length > 7 ? filmId.substring(0, 7) : filmId;
  return 0x10000000 + (int.tryParse(head, radix: 16) ?? 0);
}

/// iPhone and iPad: nothing keeps the copy alive (it runs while the app is open); a local notification tells its end,
/// a banner even while the app is in front, since the copy ends while another page is open. Its tap opens Downloaded
/// films (the payload, read in main.dart). No button: Retry is in the app.
class IosFilmDownloadKeepAlive implements FilmDownloadKeepAlive {
  IosFilmDownloadKeepAlive([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  @override
  Future<void> show(FilmDownloadNoticeTexts texts, int progress, {bool waiting = false}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> showEnd(String filmId, FilmDownloadEndTexts texts) async {
    try {
      await _plugin.show(
        filmDownloadLocalNotificationId(filmId),
        texts.title,
        texts.text,
        const NotificationDetails(
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentList: true,
            presentSound: false,
          ),
        ),
        payload: filmDownloadsLink,
      );
    } catch (error) {
      _log.info('The end of a film download was not shown: ${error.runtimeType}');
    }
  }

  @override
  Future<void> cancelEnd(String filmId) async {
    try {
      await _plugin.cancel(filmDownloadLocalNotificationId(filmId));
    } catch (error) {
      _log.info('The end of a film download was not taken away: ${error.runtimeType}');
    }
  }

  @override
  Future<int?> freeBytes(Directory folder) async => null;

  @override
  void listen({required void Function() onPause, required void Function() onCancel}) {}
}

/// The computers: nothing to keep alive and no notification (the app shows the progress on Downloaded films and on the
/// film's tile); they tell their free room
class PlainFilmDownloadKeepAlive implements FilmDownloadKeepAlive {
  const PlainFilmDownloadKeepAlive({required this.isDesktop});

  final bool isDesktop;

  @override
  Future<void> show(FilmDownloadNoticeTexts texts, int progress, {bool waiting = false}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> showEnd(String filmId, FilmDownloadEndTexts texts) async {}

  @override
  Future<void> cancelEnd(String filmId) async {}

  @override
  Future<int?> freeBytes(Directory folder) async => isDesktop ? (await systemFreeSpace(folder))?.free : null;

  @override
  void listen({required void Function() onPause, required void Function() onCancel}) {}
}
