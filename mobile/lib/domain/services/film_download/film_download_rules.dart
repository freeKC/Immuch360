// The rules of "Download" for the films of a Plex server (request 5 of the Plex films study, decision 4 a of FreeKC,
// 10 November 2026): where it is offered, where the copy goes, on which network it runs, and whether it fits. Pure
// functions, so that the tests pin them.

import 'dart:io';

import 'package:immich_mobile/platform/connectivity_api.g.dart';

/// The screens that copy films to the device: phones, tablets, the Meta Quest window (a film for the plane), computers,
/// iPhone and iPad while the app stays open, and Android TV since release 47 (FreeKC's request of 12 November 2026):
/// a TV often has little room, so the sheet tells the size of the film and the free room first and refuses a film that
/// does not fit (filmDownloadRoom).
bool filmDownloadOffered({required bool isAndroid, required bool isIOS, required bool isDesktop}) =>
    isAndroid || isIOS || isDesktop;

/// Whether the first copy asks the permission of the notifications (Android 13 and later grant it only when asked):
/// on Android, while it was neither given nor refused for good, once in a run of the app. Refused, the copy runs all
/// the same, its progress in Downloaded films. iPhone and iPad ask at the start of the app
/// (flutter_local_notifications); a computer shows none.
bool filmDownloadAsksNotifications({required bool isAndroid, required bool denied, required bool askedBefore}) =>
    isAndroid && denied && !askedBefore;

/// iPhone and iPad suspend the app once it leaves the screen, and with it the copy, which goes on when the app comes
/// back: the sheet says to keep the app open. Decision 4 a: no background session of iOS, which would carry the token
/// in a request of the system.
bool filmDownloadNeedsAppOpen({required bool isIOS}) => isIOS;

/// Where the copies go
enum FilmDownloadFolderKind {
  /// The app's own files (Android: out of the gallery and out of the backups, the manifest turns them off)
  appFiles,

  /// The app's caches (iPhone and iPad: the storage rules of Apple keep a file the app can fetch again out of the
  /// iCloud backup; the system may remove it when the device runs out of room, and the list then drops it)
  appCaches,

  /// The download folder of the app on a computer (Downloads/Immuch360 by default), under the name of the file
  downloadFolder,
}

FilmDownloadFolderKind filmDownloadFolderKind({required bool isIOS, required bool isDesktop}) => isDesktop
    ? FilmDownloadFolderKind.downloadFolder
    : isIOS
    ? FilmDownloadFolderKind.appCaches
    : FilmDownloadFolderKind.appFiles;

/// The name of the folder of the copies under the app's files or caches
const filmDownloadFolderName = 'plex_films';

/// What a copy being made is called until it is whole, next to the place it will have
const filmDownloadPartialSuffix = '.part';

/// Whether a copy may run on the network [capabilities] tell: anywhere with "Download only on Wi-Fi" off, or for a copy
/// asked "over mobile data this time"; on Wi-Fi, or on a network that is not metered and not mobile (Ethernet), with
/// the setting on. A computer always may: it tells no mobile network.
bool filmDownloadMayRun(
  List<NetworkCapability> capabilities, {
  required bool wifiOnly,
  required bool mobileDataThisTime,
  required bool isDesktop,
}) {
  if (isDesktop || !wifiOnly || mobileDataThisTime) {
    return true;
  }
  if (capabilities.contains(NetworkCapability.wifi)) {
    return true;
  }
  return capabilities.contains(NetworkCapability.unmetered) && !capabilities.contains(NetworkCapability.cellular);
}

/// Room kept free on the device besides the film, so that the system and the other apps keep working
const filmDownloadSpareBytes = 512 * 1024 * 1024;

/// Whether a film fits
enum FilmDownloadRoom { enough, notEnough, unknown }

/// Whether the [size] bytes of a film, [have] of them already copied, fit in [free] bytes, [filmDownloadSpareBytes]
/// kept free. Unknown when the size or the free room is not known: the copy starts, and a full disk stops it.
FilmDownloadRoom filmDownloadRoom({required int? size, required int have, required int? free}) {
  if (size == null || free == null) {
    return FilmDownloadRoom.unknown;
  }
  final missing = size - have;
  if (missing <= 0) {
    return FilmDownloadRoom.enough;
  }
  return missing + filmDownloadSpareBytes <= free ? FilmDownloadRoom.enough : FilmDownloadRoom.notEnough;
}

final _forbiddenCharacters = RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]');
final _reservedNames = RegExp(r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])$', caseSensitive: false);

/// Longest name kept, in characters, extension included
const filmFileNameMaxLength = 160;

/// [name] as a file name every system takes: the last segment of a path of the server (either separator), without the
/// characters Windows refuses, the dots and spaces it drops at the end, nor its device names; cut to
/// [filmFileNameMaxLength] characters with its extension kept. "film" when nothing is left.
String safeFilmFileName(String name) {
  final segment = name.split(RegExp(r'[/\\]')).lastWhere((part) => part.trim().isNotEmpty, orElse: () => '');
  var cleaned = segment.replaceAll(_forbiddenCharacters, '_').trim();
  cleaned = cleaned.replaceAll(RegExp(r'[. ]+$'), '');
  while (cleaned.startsWith('.')) {
    cleaned = cleaned.substring(1);
  }
  if (cleaned.isEmpty) {
    return 'film';
  }
  final dot = cleaned.lastIndexOf('.');
  var stem = dot > 0 ? cleaned.substring(0, dot) : cleaned;
  final extension = dot > 0 ? cleaned.substring(dot) : '';
  if (_reservedNames.hasMatch(stem)) {
    stem = '${stem}_';
  }
  final room = filmFileNameMaxLength - extension.length;
  if (stem.length > room) {
    stem = stem.substring(0, room < 1 ? 1 : room).trimRight();
  }
  return '$stem$extension';
}

/// [name] in [folder], or "name (2).ext", "name (3).ext"... when [taken] says a name is already used there (a file, a
/// copy under way, or one of the list)
String uniqueFilmPath(String folder, String name, bool Function(String path) taken) {
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final extension = dot > 0 ? name.substring(dot) : '';
  var candidate = '$folder${Platform.pathSeparator}$name';
  for (var n = 2; taken(candidate) || taken('$candidate$filmDownloadPartialSuffix'); n++) {
    candidate = '$folder${Platform.pathSeparator}$stem ($n)$extension';
  }
  return candidate;
}

/// The name of a copy in the app's storage: its id and the extension of the file, which the players read the type from
String appStorageFilmName(String id, String fileName) {
  final safe = safeFilmFileName(fileName);
  final dot = safe.lastIndexOf('.');
  final extension = dot > 0 ? safe.substring(dot).toLowerCase() : '';
  return '$id$extension';
}
