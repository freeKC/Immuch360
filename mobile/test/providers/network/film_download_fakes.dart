// Fakes of the film downloads: a share that gives files whole from an offset, a keep alive that records what it is
// told, and an environment over temporary folders. No network, no platform channel.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/film_download.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/film_download/film_download_keep_alive.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/providers/network/film_downloads.provider.dart';

const filmTestSource = NetworkSource(
  id: 'plex-1',
  type: NetworkSourceType.plex,
  name: 'Plex',
  host: '192.0.2.20',
  rootPath: '/',
  useTls: true,
);

Uint8List filmTestBytes(int size) => Uint8List.fromList([for (var i = 0; i < size; i++) (i * 13 + 5) % 256]);

NetworkEntry filmTestEntry(String path, int size) => NetworkEntry(
  sourceId: filmTestSource.id,
  path: path,
  isDirectory: false,
  size: size,
  modified: DateTime.utc(2020, 9, 13),
);

/// A Plex like share: each file whole from an offset, its body held while [hold] is set
class FakeDownloadShare implements NetworkFileSystem, NetworkFileDownloads {
  FakeDownloadShare(this.files);

  final Map<String, Uint8List> files;
  Completer<void>? hold;
  final List<int> asked = [];

  @override
  NetworkSource get source => filmTestSource;

  @override
  Future<List<NetworkEntry>> list(String path) async => const [];

  @override
  Future<NetworkEntry> stat(String path) async => filmTestEntry(path, files[path]!.length);

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async =>
      Uint8List.sublistView(files[path]!, offset, offset + length);

  @override
  Future<void> close() async {}

  @override
  Future<NetworkDownloadStream> openDownload(String path, {int from = 0, Future<void>? abort}) async {
    asked.add(from);
    final data = files[path];
    if (data == null) {
      throw const NetworkFileSystemException('gone', isNotFound: true);
    }
    final held = hold;
    final controller = StreamController<List<int>>();
    unawaited(() async {
      if (held != null) {
        await Future.any([held.future, ?abort]);
      }
      if (!controller.isClosed) {
        controller.add(Uint8List.sublistView(data, from));
        await controller.close();
      }
    }());
    return NetworkDownloadStream(start: from, total: data.length, identity: 'id:$path', bytes: controller.stream);
  }
}

class FakeKeepAlive implements FilmDownloadKeepAlive {
  final List<int> shown = [];
  int stops = 0;
  int? free;
  void Function()? onPause;
  void Function()? onCancel;

  @override
  Future<void> show(FilmDownloadNoticeTexts texts, int progress) async => shown.add(progress);

  @override
  Future<void> stop() async => stops++;

  @override
  Future<int?> freeBytes(Directory folder) async => free;

  @override
  void listen({required void Function() onPause, required void Function() onCancel}) {
    this.onPause = onPause;
    this.onCancel = onCancel;
  }
}

/// An environment over [root]: the list in root/index, the copies in root/films
class FakeFilmEnvironment {
  FakeFilmEnvironment(this.root, this.share);

  final Directory root;
  final FakeDownloadShare share;
  final keepAlive = FakeKeepAlive();
  final network = StreamController<void>.broadcast();
  List<NetworkCapability> capabilities = const [NetworkCapability.wifi, NetworkCapability.unmetered];

  Directory get films => Directory('${root.path}${Platform.pathSeparator}films');

  Future<void> close() => network.close();

  FilmDownloadEnvironment get environment => FilmDownloadEnvironment(
    fileSystem: (sourceId) async => share,
    indexFolder: () async => Directory('${root.path}${Platform.pathSeparator}index'),
    filmsFolder: () => films.create(recursive: true),
    capabilities: () async => capabilities,
    networkChanges: () => network.stream,
    keepAlive: keepAlive,
    isDesktop: false,
    texts: (film, received, speed) =>
        (channelName: 'Films', title: film.shownTitle, text: '$received', pause: 'Pause', cancel: 'Cancel'),
    retryDelays: const [Duration.zero],
  );
}

/// Waits until [done] holds, polling, or fails after [limit]
Future<void> waitUntil(bool Function() done, {Duration limit = const Duration(seconds: 10)}) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > limit) {
      throw TimeoutException('Condition not met in $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

FilmDownload? filmOf(FilmDownloadsState state, String path) => state.of(filmTestSource.id, path);
