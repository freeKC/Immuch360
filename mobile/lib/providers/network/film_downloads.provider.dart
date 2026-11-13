// "Download" of a Plex film (request 5 of the Plex films study of 10 November 2026, decision 4 a): the list of the
// copies on this device and the copy under way, one at a time, in the order they were asked. A copy runs in Dart
// through the open connection of its share (for Plex the pinned client, with the token in its header only), into the
// app's own storage (never the gallery) or the download folder of a computer; on Android a foreground service keeps it
// running while the screen is off. With "Download only on Wi-Fi" on (the default), a copy waits on mobile data unless
// it was asked "over mobile data this time", and goes on by itself on Wi-Fi. A copy cut by a lost link goes on where it
// stopped; one cut by the end of the app goes on once the app reads this list again. The notification of Android tells
// the film, its progress, the speed and the time left, why it waits (the Wi-Fi, the server), and stays at the end of a
// copy (Downloaded, or why it stopped with Retry, or Paused with Resume); a tap opens Downloaded films (release 47).

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/files/download_folder.dart';
import 'package:immich_mobile/domain/models/film_download.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/film_download/film_download_link.dart';
import 'package:immich_mobile/domain/services/film_download/film_download_rules.dart';
import 'package:immich_mobile/domain/services/film_download/film_download_store.dart';
import 'package:immich_mobile/domain/services/film_download/film_transfer.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/film_download/film_download_keep_alive.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

final _log = Logger('FilmDownloads');

/// What the copies need of the app and the platform; a provider so that the tests give their own
class FilmDownloadEnvironment {
  const FilmDownloadEnvironment({
    required this.fileSystem,
    required this.indexFolder,
    required this.filmsFolder,
    required this.capabilities,
    required this.networkChanges,
    required this.keepAlive,
    required this.isDesktop,
    this.texts = defaultFilmDownloadTexts,
    this.endTexts = defaultFilmDownloadEndTexts,
    this.retryDelays = filmTransferRetryDelays,
  });

  /// The open connection of a share
  final Future<NetworkFileSystem> Function(String sourceId) fileSystem;

  /// Where the list is kept
  final Future<Directory> Function() indexFolder;

  /// Where the copies go (see FilmDownloadFolderKind)
  final Future<Directory> Function() filmsFolder;
  final Future<List<NetworkCapability>> Function() capabilities;
  final Stream<void> Function() networkChanges;
  final FilmDownloadKeepAlive keepAlive;
  final bool isDesktop;

  /// The notification of [film], [received] of its bytes copied at [bytesPerSecond], or why it waits
  final FilmDownloadNoticeTexts Function(FilmDownload film, int received, double? bytesPerSecond, FilmDownloadWait wait)
  texts;

  /// The notification left at the end of the copy of [film], null for none
  final FilmDownloadEndTexts? Function(FilmDownload film) endTexts;
  final List<Duration> retryDelays;
}

/// What a copy under way waits for, if anything: the Wi-Fi ("Download only on Wi-Fi" on mobile data), or the server
/// between two tries after a cut link
enum FilmDownloadWait { none, wifi, server }

/// "27 % · 1.2 GiB of 4.5 GiB", the bytes alone while the size is not known
String filmDownloadProgressLine(Translations t, int received, int? size) => size == null || size <= 0
    ? formatBytes(received)
    : '${(received * 100 / size).floor().clamp(0, 100)} % · '
          '${t.film_download_progress(done: formatBytes(received), whole: formatBytes(size))}';

/// The notification in the language of the app: the film; the percentage, the bytes and the time left, the speed beside
/// the name of the app; or what the copy waits for
FilmDownloadNoticeTexts defaultFilmDownloadTexts(
  FilmDownload film,
  int received,
  double? bytesPerSecond,
  FilmDownloadWait wait,
) {
  final t = StaticTranslations.instance;
  final size = film.size;
  final moving = wait == FilmDownloadWait.none && bytesPerSecond != null && bytesPerSecond > 0;
  final parts = <String>[
    if (wait == FilmDownloadWait.wifi) t.film_download_waiting_wifi,
    if (wait == FilmDownloadWait.server) t.film_download_waiting_server,
    filmDownloadProgressLine(t, received, size),
    if (moving && size != null && size > received)
      t.film_download_time_left(minutes: '${max(1, ((size - received) / bytesPerSecond / 60).ceil())}'),
  ];
  return (
    channelName: t.film_download_notification_channel,
    title: t.film_download_notification_title(name: film.shownTitle),
    text: parts.join(' · '),
    subText: moving ? t.film_download_speed(bytes: formatBytes(bytesPerSecond.round())) : null,
    pause: t.pause,
    cancel: t.cancel,
  );
}

/// Why a copy stopped, in one sentence
String filmDownloadFailureMessage(Translations t, FilmDownloadFailure? failure) => switch (failure) {
  FilmDownloadFailure.forbidden => t.film_download_forbidden,
  FilmDownloadFailure.noSpace => t.film_download_disk_full,
  FilmDownloadFailure.unreachable => t.film_download_unreachable,
  FilmDownloadFailure.gone => t.film_download_gone,
  FilmDownloadFailure.unreadable => t.film_download_unreadable,
  FilmDownloadFailure.failed || null => t.download_failed,
};

/// The notification left at the end of a copy: Downloaded with its size; why it stopped, with Retry when trying again
/// may help (not for a film gone from the server or an account that may not download); Paused, with Resume. None for a
/// copy that runs, waits or was cancelled.
FilmDownloadEndTexts? defaultFilmDownloadEndTexts(FilmDownload film) {
  final t = StaticTranslations.instance;
  final size = film.size;
  final channelName = t.film_download_notification_channel;
  switch (film.state) {
    case FilmDownloadState.done:
      return (
        channelName: channelName,
        title: film.shownTitle,
        text: size == null ? t.film_downloaded : '${t.film_downloaded} · ${formatBytes(size)}',
        actionLabel: null,
        actionLink: null,
      );
    case FilmDownloadState.failed:
      final retry = film.failure != FilmDownloadFailure.gone && film.failure != FilmDownloadFailure.forbidden;
      return (
        channelName: channelName,
        title: film.shownTitle,
        text: filmDownloadFailureMessage(t, film.failure),
        actionLabel: retry ? t.retry : null,
        actionLink: retry ? filmDownloadActionLink(film.id, FilmDownloadLinkAction.retry) : null,
      );
    case FilmDownloadState.paused:
      return (
        channelName: channelName,
        title: film.shownTitle,
        text: '${t.film_download_paused} · ${filmDownloadProgressLine(t, film.received, size)}',
        actionLabel: t.resume,
        actionLink: filmDownloadActionLink(film.id, FilmDownloadLinkAction.resume),
      );
    case FilmDownloadState.queued || FilmDownloadState.running || FilmDownloadState.waitingForWifi:
      return null;
  }
}

/// The platform as Download sees it, read in this one place (PLATFORM-AUDIT.md): an Android service, an iPhone kept
/// open with a notification at the end, the download folder of a computer
typedef FilmDownloadPlatform = ({bool isAndroid, bool isIOS, bool isDesktop});

FilmDownloadPlatform filmDownloadPlatform() =>
    (isAndroid: CurrentPlatform.isAndroid, isIOS: CurrentPlatform.isIOS, isDesktop: CurrentPlatform.isDesktop);

/// What keeps a copy running and tells it: the foreground service on Android, the notification of the end on iPhone
/// and iPad, nothing on a computer
FilmDownloadKeepAlive filmDownloadKeepAliveOf(FilmDownloadPlatform platform) {
  if (platform.isAndroid) {
    return AndroidFilmDownloadKeepAlive();
  }
  if (platform.isIOS) {
    return IosFilmDownloadKeepAlive();
  }
  return PlainFilmDownloadKeepAlive(isDesktop: platform.isDesktop);
}

final filmDownloadEnvironmentProvider = Provider<FilmDownloadEnvironment>((ref) {
  final platform = filmDownloadPlatform();
  final isDesktop = platform.isDesktop;
  final kind = filmDownloadFolderKind(isIOS: platform.isIOS, isDesktop: isDesktop);
  Future<Directory> indexFolder() async =>
      Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}$filmDownloadFolderName');
  return FilmDownloadEnvironment(
    fileSystem: (sourceId) => ref.read(networkConnectionsProvider).fileSystem(sourceId),
    indexFolder: indexFolder,
    filmsFolder: () async => switch (kind) {
      FilmDownloadFolderKind.downloadFolder => DownloadFolder.instance.prepare(),
      FilmDownloadFolderKind.appCaches => Directory(
        '${(await getApplicationCacheDirectory()).path}${Platform.pathSeparator}$filmDownloadFolderName',
      ).create(recursive: true),
      FilmDownloadFolderKind.appFiles => (await indexFolder()).create(recursive: true),
    },
    capabilities: () => ref.read(connectivityApiProvider).getCapabilities(),
    networkChanges: () => Connectivity().onConnectivityChanged.map<void>((_) {}),
    keepAlive: filmDownloadKeepAliveOf(platform),
    isDesktop: isDesktop,
  );
});

/// The copies on this device and the setting
class FilmDownloadsState {
  const FilmDownloadsState({
    this.loaded = false,
    this.wifiOnly = true,
    this.films = const [],
    this.bytesPerSecond,
    this.waitingForServer = false,
  });

  final bool loaded;

  /// "Download only on Wi-Fi"
  final bool wifiOnly;

  /// In the order they were asked
  final List<FilmDownload> films;

  /// The speed of the copy under way, null when none runs or it is not measured yet
  final double? bytesPerSecond;

  /// The copy under way waits before it tries the server again (a cut link, a server that does not answer)
  final bool waitingForServer;

  FilmDownload? of(String sourceId, String path) =>
      films.where((film) => film.sourceId == sourceId && film.path == path).firstOrNull;

  FilmDownload? byId(String id) => films.where((film) => film.id == id).firstOrNull;

  List<FilmDownload> get done => [
    for (final film in films)
      if (film.isDone) film,
  ];

  /// The bytes the copies take on this device, whole or partial
  int get bytesOnDevice =>
      films.fold(0, (sum, film) => sum + (film.isDone ? (film.size ?? film.received) : film.received));

  FilmDownloadsState copyWith({
    bool? loaded,
    bool? wifiOnly,
    List<FilmDownload>? films,
    double? bytesPerSecond,
    bool? waitingForServer,
  }) => FilmDownloadsState(
    loaded: loaded ?? this.loaded,
    wifiOnly: wifiOnly ?? this.wifiOnly,
    films: films ?? this.films,
    bytesPerSecond: bytesPerSecond,
    waitingForServer: waitingForServer ?? this.waitingForServer,
  );
}

/// Whether a share of [type] gives films to download: Plex, the request of the study (the other shares may follow)
bool filmDownloadSourceType(NetworkSourceType? type) => type == NetworkSourceType.plex;

class FilmDownloadsNotifier extends Notifier<FilmDownloadsState> {
  late FilmDownloadEnvironment _env;
  FilmDownloadStore? _store;
  Future<void>? _loading;
  FilmTransfer? _transfer;
  String? _runningId;

  /// What a copy stopped for its pause becomes: paused, or waiting for the Wi-Fi
  FilmDownloadState _haltedAs = FilmDownloadState.paused;
  StreamSubscription<void>? _network;
  Timer? _saveTimer;
  bool _pumping = false;
  bool _pumpAgain = false;

  /// For the speed and the throttling of the updates
  DateTime _lastShown = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastNotice = DateTime.fromMillisecondsSinceEpoch(0);
  int _speedBytes = 0;
  DateTime? _speedSince;
  double? _speed;

  static const _showEvery = Duration(milliseconds: 250);
  static const _noticeEvery = Duration(seconds: 1);
  static const _saveEvery = Duration(seconds: 10);

  @override
  FilmDownloadsState build() {
    _env = ref.watch(filmDownloadEnvironmentProvider);
    ref.onDispose(() {
      _saveTimer?.cancel();
      unawaited(_network?.cancel());
      _transfer?.pause();
    });
    _loading = _load();
    return const FilmDownloadsState();
  }

  /// Completes once the list is read
  Future<void> get ready => _loading ?? Future.value();

  Future<void> _load() async {
    try {
      final store = FilmDownloadStore(await _env.indexFolder());
      _store = store;
      final index = await store.load();
      // A copy that ran when the app ended goes on
      final films = [
        for (final film in index.films)
          film.state == FilmDownloadState.running ? film.copyWith(state: FilmDownloadState.queued) : film,
      ];
      state = state.copyWith(loaded: true, wifiOnly: index.wifiOnly, films: films);
    } catch (error, stackTrace) {
      _log.warning('The downloaded films could not be read', error, stackTrace);
      state = state.copyWith(loaded: true);
    }
    try {
      _env.keepAlive.listen(onPause: _pauseRunning, onCancel: _cancelRunning);
    } catch (error) {
      _log.info('The actions of the notification are not heard: ${error.runtimeType}');
    }
    unawaited(_pump());
  }

  /// Hears the changes of the network from the first copy on: the pages that only read the list (the tiles, the
  /// shares page) open no stream of the platform
  void _listenToNetwork() {
    if (_network != null) {
      return;
    }
    try {
      _network = _env.networkChanges().listen(
        (_) => unawaited(_onNetworkChanged()),
        onError: (Object error) => _log.info('The changes of the network are not heard: ${error.runtimeType}'),
      );
    } catch (error) {
      _log.info('The changes of the network are not heard: ${error.runtimeType}');
    }
  }

  /// The whole copy of the film at [path] of the share [sourceId], null when there is none
  Future<File?> completedCopy(String sourceId, String path) async {
    await ready;
    final film = state.of(sourceId, path);
    if (film == null || !film.isDone) {
      return null;
    }
    final file = File(film.localPath);
    if (file.existsSync()) {
      return file;
    }
    _remove(film.id);
    _saveSoon(now: true);
    return null;
  }

  /// The bytes free in the folder of the copies, null when unknown
  Future<int?> freeBytes() async {
    try {
      return await _env.keepAlive.freeBytes(await _env.filmsFolder());
    } catch (error) {
      _log.info('No free room known: ${error.runtimeType}');
      return null;
    }
  }

  /// The folder the copies go to, for the sheet of a computer
  Future<String?> folderPath() async {
    try {
      return (await _env.filmsFolder()).path;
    } catch (_) {
      return null;
    }
  }

  /// Asks the copy of [entry]; a film already in the list goes on instead (resumed when it was stopped)
  Future<FilmDownload> download(NetworkEntry entry, {String? title, bool mobileDataThisTime = false}) async {
    await ready;
    final known = state.of(entry.sourceId, entry.path);
    if (known != null) {
      if (!known.isDone && !known.isActive) {
        resume(known.id, mobileDataThisTime: mobileDataThisTime);
      }
      return state.byId(known.id) ?? known;
    }
    final id = _newId();
    final folder = await _env.filmsFolder();
    final localPath = _env.isDesktop
        ? uniqueFilmPath(
            folder.path,
            safeFilmFileName(entry.name),
            (path) => File(path).existsSync() || state.films.any((film) => film.localPath == path),
          )
        : '${folder.path}${Platform.pathSeparator}${appStorageFilmName(id, entry.name)}';
    final film = FilmDownload(
      id: id,
      sourceId: entry.sourceId,
      path: entry.path,
      fileName: entry.name,
      title: title,
      localPath: localPath,
      state: FilmDownloadState.queued,
      addedAt: DateTime.now().toUtc(),
      size: entry.size,
      modified: entry.modified,
      mimeType: entry.mimeType,
      width: entry.width,
      height: entry.height,
      durationMs: entry.durationMs,
      mobileDataThisTime: mobileDataThisTime,
    );
    state = state.copyWith(films: [...state.films, film], bytesPerSecond: _speed);
    _saveSoon(now: true);
    unawaited(_pump());
    return film;
  }

  /// Stops a copy, its bytes kept
  void pause(String id) {
    final film = state.byId(id);
    if (film == null || film.isDone) {
      return;
    }
    if (_runningId == id) {
      _haltedAs = FilmDownloadState.paused;
      _transfer?.pause();
    }
    _update(id, (film) => film.copyWith(state: FilmDownloadState.paused, mobileDataThisTime: false));
    _saveSoon(now: true);
  }

  /// Puts a stopped or failed copy back in the queue. Asked while the copy is still stopping after a pause, it goes
  /// on once the transfer has stopped, from its bytes.
  void resume(String id, {bool mobileDataThisTime = false}) {
    final film = state.byId(id);
    if (film == null || film.isDone || (_runningId == id && film.state == FilmDownloadState.running)) {
      return;
    }
    _update(
      id,
      (film) => film.copyWith(
        state: FilmDownloadState.queued,
        clearFailure: true,
        mobileDataThisTime: mobileDataThisTime || film.mobileDataThisTime,
      ),
    );
    _saveSoon(now: true);
    unawaited(_pump());
  }

  /// Retry or Resume of a notification (a link of film_download_link.dart): once the list is read, the film goes on
  /// when it is still stopped; a film gone from the list meanwhile is left
  Future<void> resumeFromNotification(String id) async {
    await ready;
    resume(id);
  }

  /// Stops a copy and deletes what it copied; the film leaves the list
  Future<void> cancel(String id) => delete(id);

  /// Deletes the copy of a film, whole or partial, and takes it off the list. The film stays on the server.
  Future<void> delete(String id) async {
    final film = state.byId(id);
    if (film == null) {
      return;
    }
    if (_runningId == id) {
      _transfer?.cancel();
    }
    _remove(id);
    _saveSoon(now: true);
    unawaited(_env.keepAlive.cancelEnd(id));
    await _deleteFiles(film);
  }

  /// Deletes every copy: the list empties at once, then the files go
  Future<void> deleteAll() async {
    final films = [...state.films];
    if (_runningId != null) {
      _transfer?.cancel();
    }
    state = state.copyWith(films: const []);
    _saveSoon(now: true);
    for (final film in films) {
      unawaited(_env.keepAlive.cancelEnd(film.id));
      await _deleteFiles(film);
    }
  }

  /// "Download only on Wi-Fi"
  Future<void> setWifiOnly(bool value) async {
    // The switch moves at once once the list is read
    if (!state.loaded) {
      await ready;
    }
    state = state.copyWith(wifiOnly: value, bytesPerSecond: _speed);
    _saveSoon(now: true);
    await _onNetworkChanged();
  }

  /// The film the notification of the service shows: the copy under way, or the one that waits for the Wi-Fi
  String? _noticeFilmId;

  void _pauseRunning() {
    final running = _runningId;
    final id = running ?? _noticeFilmId;
    if (id == null) {
      return;
    }
    pause(id);
    if (running == null) {
      // A film that waited for the Wi-Fi: no transfer ends, so its Paused notification is left here
      final paused = state.byId(id);
      final texts = paused == null ? null : _env.endTexts(paused);
      if (texts != null) {
        unawaited(_env.keepAlive.showEnd(id, texts));
      }
    }
    unawaited(_pump());
  }

  void _cancelRunning() {
    final id = _runningId ?? _noticeFilmId;
    if (id != null) {
      unawaited(cancel(id).then((_) => _pump()));
    }
  }

  Future<void> _onNetworkChanged() async {
    final id = _runningId;
    if (id != null) {
      final film = state.byId(id);
      if (film != null && !await _mayRun(film)) {
        _log.info('Mobile data with Download only on Wi-Fi: the copy waits for the Wi-Fi');
        _haltedAs = FilmDownloadState.waitingForWifi;
        _transfer?.pause();
        return;
      }
    }
    await _pump();
  }

  Future<bool> _mayRun(FilmDownload film) async {
    List<NetworkCapability> capabilities;
    try {
      capabilities = await _env.capabilities();
    } catch (_) {
      // Unknown: as on Wi-Fi, a failure of the network then shows
      capabilities = const [NetworkCapability.wifi];
    }
    return filmDownloadMayRun(
      capabilities,
      wifiOnly: state.wifiOnly,
      mobileDataThisTime: film.mobileDataThisTime,
      isDesktop: _env.isDesktop,
    );
  }

  /// Starts the next copy when none runs
  Future<void> _pump() async {
    if (_pumping) {
      _pumpAgain = true;
      return;
    }
    _pumping = true;
    try {
      do {
        _pumpAgain = false;
        if (_transfer != null || !state.loaded) {
          return;
        }
        FilmDownload? next;
        for (final film in state.films) {
          if (!film.isActive) {
            continue;
          }
          _listenToNetwork();
          if (await _mayRun(film)) {
            next = film;
            break;
          }
          if (film.state != FilmDownloadState.waitingForWifi) {
            _update(film.id, (film) => film.copyWith(state: FilmDownloadState.waitingForWifi));
            _saveSoon();
          }
        }
        if (next == null) {
          // A copy that waits for the Wi-Fi keeps the service and says so, without its locks: the change of network
          // reaches the app, which goes on by itself
          final waiting = state.films.where((film) => film.state == FilmDownloadState.waitingForWifi).firstOrNull;
          if (waiting == null) {
            _noticeFilmId = null;
            await _env.keepAlive.stop();
          } else {
            await _notify(waiting, waiting.received, force: true, wait: FilmDownloadWait.wifi);
          }
          continue;
        }
        _run(next);
      } while (_pumpAgain);
    } finally {
      _pumping = false;
    }
  }

  void _run(FilmDownload film) {
    final id = film.id;
    _haltedAs = FilmDownloadState.paused;
    _speed = null;
    _speedBytes = film.received;
    _speedSince = DateTime.now();
    _update(id, (film) => film.copyWith(state: FilmDownloadState.running, clearFailure: true));
    state = state.copyWith(waitingForServer: false, bytesPerSecond: _speed);
    _saveSoon(now: true);
    unawaited(_env.keepAlive.cancelEnd(id));
    final transfer = FilmTransfer(
      target: film.localPath,
      identity: film.identity,
      retryDelays: _env.retryDelays,
      open: (from, abort) async {
        final fileSystem = await _env.fileSystem(film.sourceId);
        if (fileSystem case final NetworkFileDownloads downloads) {
          return downloads.openDownload(film.path, from: from, abort: abort);
        }
        throw const FilmTransferException(FilmDownloadFailure.failed, 'This share gives no file to download');
      },
      onIdentity: (identity) {
        _update(id, (film) => film.copyWith(identity: identity));
        _saveSoon(now: true);
      },
      onProgress: (received, total) => _progress(id, received, total),
      onRetry: (_) => _waitForServer(id),
    );
    _transfer = transfer;
    _runningId = id;
    unawaited(_notify(state.byId(id) ?? film, film.received, force: true));
    unawaited(() async {
      try {
        final result = await transfer.run();
        if (result.end == FilmTransferEnd.completed) {
          _log.info('A film is whole on this device');
          _update(
            id,
            (film) => film.copyWith(
              state: FilmDownloadState.done,
              received: result.received,
              size: result.total ?? result.received,
              completedAt: DateTime.now().toUtc(),
              mobileDataThisTime: false,
            ),
          );
        } else if (result.end == FilmTransferEnd.paused) {
          final halted = _haltedAs;
          _update(
            id,
            (film) => film.copyWith(
              state: film.state == FilmDownloadState.running ? halted : film.state,
              received: result.received,
              size: result.total,
            ),
          );
        }
        // Cancelled: the film left the list with its bytes; waiting for the Wi-Fi: the notification of the service
        // says it
      } on FilmTransferException catch (error) {
        _update(
          id,
          (film) => film.copyWith(state: FilmDownloadState.failed, failure: error.failure, received: film.received),
        );
      } catch (error, stackTrace) {
        _log.warning('A film download failed', error, stackTrace);
        _update(id, (film) => film.copyWith(state: FilmDownloadState.failed, failure: FilmDownloadFailure.failed));
      } finally {
        if (identical(_transfer, transfer)) {
          _transfer = null;
          _runningId = null;
        }
        _speed = null;
        state = state.copyWith(bytesPerSecond: null, waitingForServer: false);
        _saveSoon(now: true);
        final ended = state.byId(id);
        final endTexts = ended == null ? null : _env.endTexts(ended);
        if (endTexts != null) {
          unawaited(_env.keepAlive.showEnd(id, endTexts));
        }
        unawaited(_pump());
      }
    }());
  }

  /// The copy waits before it tries the server again: the page and the notification say so until bytes come
  void _waitForServer(String id) {
    if (_runningId != id) {
      return;
    }
    state = state.copyWith(waitingForServer: true, bytesPerSecond: null);
    final film = state.byId(id);
    if (film != null) {
      unawaited(_notify(film, film.received, force: true, wait: FilmDownloadWait.server));
    }
  }

  void _progress(String id, int received, int? total) {
    final now = DateTime.now();
    final before = state.byId(id)?.received ?? 0;
    if (state.waitingForServer && received > before) {
      state = state.copyWith(waitingForServer: false, bytesPerSecond: _speed);
    }
    final since = _speedSince;
    if (since != null && now.difference(since) >= const Duration(seconds: 2)) {
      final measured = (received - _speedBytes) * 1000 / now.difference(since).inMilliseconds;
      if (measured >= 0) {
        _speed = _speed == null ? measured : _speed! * 0.7 + measured * 0.3;
      }
      _speedBytes = received;
      _speedSince = now;
    }
    final whole = total != null && received >= total;
    if (!whole && now.difference(_lastShown) < _showEvery) {
      return;
    }
    _lastShown = now;
    _update(id, (film) => film.copyWith(received: received, size: total));
    _saveSoon();
    final film = state.byId(id);
    if (film != null) {
      unawaited(_notify(film, received));
    }
  }

  Future<void> _notify(FilmDownload film, int received, {bool force = false, FilmDownloadWait? wait}) async {
    final now = DateTime.now();
    if (!force && now.difference(_lastNotice) < _noticeEvery) {
      return;
    }
    _lastNotice = now;
    final size = film.size;
    final progress = size == null || size <= 0 ? -1 : (received * 1000 / size).floor().clamp(0, 1000);
    final waitingFor = wait ?? (state.waitingForServer ? FilmDownloadWait.server : FilmDownloadWait.none);
    _noticeFilmId = film.id;
    try {
      await _env.keepAlive.show(
        _env.texts(film, received, waitingFor == FilmDownloadWait.none ? _speed : null, waitingFor),
        progress,
        waiting: waitingFor == FilmDownloadWait.wifi,
      );
    } catch (error) {
      _log.info('The notification of the film download was not shown: ${error.runtimeType}');
    }
  }

  void _update(String id, FilmDownload Function(FilmDownload film) change) {
    final films = [...state.films];
    final index = films.indexWhere((film) => film.id == id);
    if (index < 0) {
      // Deleted meanwhile
      return;
    }
    films[index] = change(films[index]);
    state = state.copyWith(films: films, bytesPerSecond: _speed);
  }

  void _remove(String id) {
    state = state.copyWith(
      films: [
        for (final film in state.films)
          if (film.id != id) film,
      ],
      bytesPerSecond: _speed,
    );
  }

  Future<void> _deleteFiles(FilmDownload film) async {
    for (final path in [film.localPath, '${film.localPath}$filmDownloadPartialSuffix']) {
      try {
        final file = File(path);
        if (file.existsSync()) {
          await file.delete();
        }
      } on FileSystemException catch (error) {
        _log.warning('A copy of a film was not deleted: ${error.osError?.errorCode}');
      }
    }
  }

  void _saveSoon({bool now = false}) {
    if (now) {
      _saveTimer?.cancel();
      _saveTimer = null;
      unawaited(_save());
      return;
    }
    _saveTimer ??= Timer(_saveEvery, () {
      _saveTimer = null;
      unawaited(_save());
    });
  }

  Future<void>? _saving;

  Future<void> _save() async {
    final store = _store;
    if (store == null) {
      return;
    }
    // One write at a time, the last state wins
    final previous = _saving;
    final saving = () async {
      await previous;
      try {
        await store.save(FilmDownloadIndex(wifiOnly: state.wifiOnly, films: state.films));
      } catch (error) {
        _log.warning('The list of the downloaded films was not written: ${error.runtimeType}');
      }
    }();
    _saving = saving;
    await saving;
  }

  /// Waits for the writes under way, for the tests
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _save();
  }

  static String _newId() {
    final random = Random.secure();
    return List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

final filmDownloadsProvider = NotifierProvider<FilmDownloadsNotifier, FilmDownloadsState>(FilmDownloadsNotifier.new);
