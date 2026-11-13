// The rules of Download for the Plex films (decision 4 a of the study of 10 November 2026): the screens that offer it,
// where the copies go, the Wi-Fi rule, the free room, and the names of the files.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/film_download/film_download_rules.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';

void main() {
  group('screens', () {
    test('phones, tablets, the Quest window, Android TV, iPhone and computers download', () {
      expect(filmDownloadOffered(isAndroid: true, isIOS: false, isDesktop: false), isTrue);
      expect(filmDownloadOffered(isAndroid: false, isIOS: true, isDesktop: false), isTrue);
      expect(filmDownloadOffered(isAndroid: false, isIOS: false, isDesktop: true), isTrue);
      expect(filmDownloadOffered(isAndroid: false, isIOS: false, isDesktop: false), isFalse);
    });

    test(
      'the first copy on Android asks the notifications once, while they were neither given nor refused for good',
      () {
        expect(filmDownloadAsksNotifications(isAndroid: true, denied: true, askedBefore: false), isTrue);
        expect(filmDownloadAsksNotifications(isAndroid: true, denied: true, askedBefore: true), isFalse);
        expect(filmDownloadAsksNotifications(isAndroid: true, denied: false, askedBefore: false), isFalse);
        expect(filmDownloadAsksNotifications(isAndroid: false, denied: true, askedBefore: false), isFalse);
      },
    );

    test('only iPhone and iPad need the app open', () {
      expect(filmDownloadNeedsAppOpen(isIOS: true), isTrue);
      expect(filmDownloadNeedsAppOpen(isIOS: false), isFalse);
    });
  });

  group('storage', () {
    test('the app files on Android, the caches on iPhone, the download folder on a computer, never the gallery', () {
      expect(filmDownloadFolderKind(isIOS: false, isDesktop: false), FilmDownloadFolderKind.appFiles);
      expect(filmDownloadFolderKind(isIOS: true, isDesktop: false), FilmDownloadFolderKind.appCaches);
      expect(filmDownloadFolderKind(isIOS: false, isDesktop: true), FilmDownloadFolderKind.downloadFolder);
      expect(FilmDownloadFolderKind.values, hasLength(3));
    });

    test('a copy in the app storage is named by its id and the extension of the film', () {
      expect(appStorageFilmName('0a1b2c3d', 'Le Fabuleux Destin (2001).MKV'), '0a1b2c3d.mkv');
      expect(appStorageFilmName('0a1b2c3d', 'no extension'), '0a1b2c3d');
    });

    test('a file name every system takes', () {
      expect(safeFilmFileName('/data/movies/Amélie (2001).mkv'), 'Amélie (2001).mkv');
      expect(safeFilmFileName(r'D:\Plex\Films\Heat.mp4'), 'Heat.mp4');
      expect(safeFilmFileName('What? 12:30 <cut>.mkv'), 'What_ 12_30 _cut_.mkv');
      expect(safeFilmFileName('Trailing dots... '), 'Trailing dots');
      expect(safeFilmFileName('..hidden.mkv'), 'hidden.mkv');
      expect(safeFilmFileName('CON.mkv'), 'CON_.mkv');
      expect(safeFilmFileName('lpt1'), 'lpt1_');
      expect(safeFilmFileName(''), 'film');
      expect(safeFilmFileName('/'), 'film');
      final long = safeFilmFileName('${'a' * 300}.mkv');
      expect(long.length, filmFileNameMaxLength);
      expect(long, endsWith('.mkv'));
    });

    test('a name already used in the folder, or by a copy under way, gets a number', () {
      final sep = Platform.pathSeparator;
      final taken = {'f${sep}Heat.mkv', 'f${sep}Heat (2).mkv.part'};
      expect(uniqueFilmPath('f', 'Heat.mkv', taken.contains), 'f${sep}Heat (3).mkv');
      expect(uniqueFilmPath('f', 'Ronin.mkv', taken.contains), 'f${sep}Ronin.mkv');
    });
  });

  group('Wi-Fi rule', () {
    const wifi = [NetworkCapability.wifi, NetworkCapability.unmetered];
    const mobile = [NetworkCapability.cellular];
    const ethernet = [NetworkCapability.unmetered];

    bool mayRun(List<NetworkCapability> network, {bool wifiOnly = true, bool once = false, bool desktop = false}) =>
        filmDownloadMayRun(network, wifiOnly: wifiOnly, mobileDataThisTime: once, isDesktop: desktop);

    test('Download only on Wi-Fi holds a copy on mobile data', () {
      expect(mayRun(wifi), isTrue);
      expect(mayRun(mobile), isFalse);
      expect(mayRun(const []), isFalse);
      expect(mayRun(const [NetworkCapability.cellular, NetworkCapability.unmetered]), isFalse);
    });

    test('a network that is neither metered nor mobile counts as Wi-Fi', () {
      expect(mayRun(ethernet), isTrue);
    });

    test('over mobile data this time, or with the setting off, a copy runs anywhere', () {
      expect(mayRun(mobile, once: true), isTrue);
      expect(mayRun(mobile, wifiOnly: false), isTrue);
    });

    test('a computer always runs', () {
      expect(mayRun(const [], desktop: true), isTrue);
    });
  });

  group('room', () {
    const gb = 1024 * 1024 * 1024;

    test('a film fits with the spare room kept free', () {
      expect(filmDownloadRoom(size: 4 * gb, have: 0, free: 10 * gb), FilmDownloadRoom.enough);
      expect(filmDownloadRoom(size: 4 * gb, have: 0, free: 4 * gb), FilmDownloadRoom.notEnough);
      expect(filmDownloadRoom(size: 4 * gb, have: 0, free: 4 * gb + filmDownloadSpareBytes), FilmDownloadRoom.enough);
    });

    test('the bytes already copied count', () {
      expect(filmDownloadRoom(size: 8 * gb, have: 6 * gb, free: 3 * gb), FilmDownloadRoom.enough);
      expect(filmDownloadRoom(size: 8 * gb, have: 8 * gb, free: 0), FilmDownloadRoom.enough);
    });

    test('unknown when the size or the free room is not told', () {
      expect(filmDownloadRoom(size: null, have: 0, free: gb), FilmDownloadRoom.unknown);
      expect(filmDownloadRoom(size: gb, have: 0, free: null), FilmDownloadRoom.unknown);
    });
  });
}
