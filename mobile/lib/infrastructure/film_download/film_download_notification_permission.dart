// The permission of the notifications for the film downloads (release 47): Android 13 and later show none until the
// app asks, so the first "Download to this device" asks it, once in a run of the app, while it was neither given nor
// refused for good (filmDownloadAsksNotifications). Elsewhere nothing is asked here: iPhone and iPad ask at the start of
// the app (flutter_local_notifications), a computer shows no notification of a copy. A provider, so that the tests give
// their own.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/network/film_downloads.provider.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';

final _log = Logger('FilmDownloadNotifications');

abstract interface class FilmDownloadNotificationPermission {
  /// Whether the notifications show
  Future<bool> granted();

  /// Whether they were refused but may still be asked (never asked, or refused once on Android)
  Future<bool> askable();

  /// Asks them; true once they show
  Future<bool> request();

  /// Whether the question was asked in this run of the app
  bool get asked;

  /// The settings of the app, where the notifications are turned on
  Future<void> openSettings();
}

class PermissionHandlerFilmDownloadNotifications implements FilmDownloadNotificationPermission {
  PermissionHandlerFilmDownloadNotifications();

  bool _asked = false;

  @override
  bool get asked => _asked;

  @override
  Future<bool> granted() async {
    try {
      return (await Permission.notification.status).isGranted;
    } catch (error) {
      _log.info('The permission of the notifications is not known: ${error.runtimeType}');
      return true;
    }
  }

  @override
  Future<bool> askable() async {
    try {
      return (await Permission.notification.status).isDenied;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> request() async {
    _asked = true;
    try {
      return (await Permission.notification.request()).isGranted;
    } catch (error) {
      _log.info('The permission of the notifications was not asked: ${error.runtimeType}');
      return false;
    }
  }

  @override
  Future<void> openSettings() async {
    try {
      await openAppSettings();
    } catch (_) {
      // No settings page: nothing more to do
    }
  }
}

/// iPhone, iPad and the computers: nothing to ask before a copy
class NoFilmDownloadNotificationQuestion implements FilmDownloadNotificationPermission {
  const NoFilmDownloadNotificationQuestion();

  @override
  bool get asked => false;

  @override
  Future<bool> granted() async => true;

  @override
  Future<bool> askable() async => false;

  @override
  Future<bool> request() async => true;

  @override
  Future<void> openSettings() async {}
}

final filmDownloadNotificationPermissionProvider = Provider<FilmDownloadNotificationPermission>(
  (ref) => filmDownloadPlatform().isAndroid
      ? PermissionHandlerFilmDownloadNotifications()
      : const NoFilmDownloadNotificationQuestion(),
);
