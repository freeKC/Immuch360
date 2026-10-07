// Fakes for the tests of the network share browser and viewers: a share in memory, the connections to it, and a real
// router whose network routes render the real pages or a stub telling where they were opened.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/routing/router.dart';

import '../../../providers/network/fakes.dart';

/// A share in memory: [folders] by path, [files] by path. Reads are recorded.
class MemoryShare implements NetworkFileSystem {
  MemoryShare(this.source, {Map<String, List<NetworkEntry>>? folders, Map<String, Uint8List>? files})
    : folders = folders ?? {},
      files = files ?? {};

  @override
  final NetworkSource source;
  final Map<String, List<NetworkEntry>> folders;
  final Map<String, Uint8List> files;
  final List<String> listed = [];
  final List<(String, int, int)> reads = [];

  /// Thrown by [list] and [stat] when set
  Exception? error;

  /// Holds [list] until completed, when set
  Completer<void>? listGate;

  static final modified = DateTime.utc(2026, 10, 1, 12);

  /// A file entry of this share, with the size of its bytes in [files]
  NetworkEntry file(String path) =>
      NetworkEntry(sourceId: source.id, path: path, isDirectory: false, size: files[path]?.length, modified: modified);

  NetworkEntry folder(String path) => NetworkEntry(sourceId: source.id, path: path, isDirectory: true);

  @override
  Future<List<NetworkEntry>> list(String path) async {
    listed.add(path);
    final gate = listGate;
    if (gate != null) {
      await gate.future;
    }
    final error = this.error;
    if (error != null) {
      throw error;
    }
    final found = folders[path];
    if (found == null) {
      throw NetworkFileSystemException('No folder $path', isNotFound: true);
    }
    return found;
  }

  @override
  Future<NetworkEntry> stat(String path) async {
    final error = this.error;
    if (error != null) {
      throw error;
    }
    if (!files.containsKey(path)) {
      throw NetworkFileSystemException('No file $path', isNotFound: true);
    }
    return file(path);
  }

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    reads.add((path, offset, length));
    final bytes = files[path];
    if (bytes == null) {
      throw NetworkFileSystemException('No file $path', isNotFound: true);
    }
    final start = math.min(offset, bytes.length);
    return Uint8List.sublistView(bytes, start, math.min(start + length, bytes.length));
  }

  @override
  Future<void> close() async {}
}

/// The connections of the app with one open share, [share], whose files are at [baseUrl] followed by their path (a
/// stand in for the media bridge)
class FakeConnections extends NetworkConnections {
  FakeConnections(Ref ref, this.share, {Uri? baseUrl})
    : baseUrl = baseUrl ?? Uri.parse('http://127.0.0.1:1234/token/${share.source.id}'),
      super(ref, FakeMediaBridge());

  final MemoryShare share;
  final Uri baseUrl;

  /// Thrown when the share is asked for, when set
  Exception? openError;

  @override
  NetworkFileSystem? opened(String sourceId) => sourceId == share.source.id ? share : null;

  @override
  Future<NetworkFileSystem> fileSystem(String sourceId) async {
    final error = openError;
    if (error != null) {
      throw error;
    }
    if (sourceId != share.source.id) {
      throw NetworkFileSystemException('Unknown share $sourceId', isNotFound: true);
    }
    return share;
  }

  @override
  Future<Uri> mediaUrl(String sourceId, String path) async {
    await fileSystem(sourceId);
    return baseUrl.replace(
      pathSegments: [...baseUrl.pathSegments, ...path.split('/').where((segment) => segment.isNotEmpty)],
    );
  }
}

/// The override that makes [connections] the connections of the app
Override overrideConnections(FakeConnections Function(Ref ref) connections) =>
    networkConnectionsProvider.overrideWith(connections);

/// A JPEG-like file with [xmp] at its head: enough for the GPano tags, not for a decoder
Uint8List fakePhoto([String xmp = '']) =>
    Uint8List.fromList([0xff, 0xd8, ...ascii.encode(xmp), ...List.filled(256, 0)]);

/// GPano tags of an equirectangular photo
const equirectangularXmp = '<rdf:Description GPano:ProjectionType="equirectangular"/>';

/// Pumps [home] under a real router where the network browser route renders the real page, and the photo and video
/// routes the real page when in [pages], else a stub telling where they were opened. Returns the router.
Future<RootStackRouter> pumpNetworkRouter(
  WidgetTester tester, {
  required Widget home,
  required List<Override> overrides,
  Map<String, Widget Function(RouteData data)> pages = const {},
  bool settle = true,
}) async {
  final router = RootStackRouter.build(
    routes: [
      AutoRoute(
        path: '/',
        initial: true,
        page: PageInfo('HomeRoute', builder: (_) => home),
      ),
      AutoRoute(
        path: '/network-browser',
        page: PageInfo(
          NetworkBrowserRoute.name,
          builder: (data) {
            final args = data.argsAs<NetworkBrowserRouteArgs>();
            return NetworkBrowserPage(sourceId: args.sourceId, path: args.path);
          },
        ),
      ),
      AutoRoute(
        path: '/network-photo',
        page: PageInfo(
          NetworkPhotoRoute.name,
          builder:
              pages[NetworkPhotoRoute.name] ??
              (data) {
                final args = data.argsAs<NetworkPhotoRouteArgs>();
                return Text('photo ${args.sourceId} ${args.path}');
              },
        ),
      ),
      AutoRoute(
        path: '/network-video',
        page: PageInfo(
          NetworkVideoRoute.name,
          builder:
              pages[NetworkVideoRoute.name] ??
              (data) {
                final args = data.argsAs<NetworkVideoRouteArgs>();
                return Text('video ${args.sourceId} ${args.path}');
              },
        ),
      ),
      // Where the error view sends a share whose credentials were refused
      AutoRoute(
        path: '/network-share-edit',
        page: PageInfo(
          NetworkShareEditRoute.name,
          builder: (data) => Text('edit ${data.argsAs<NetworkShareEditRouteArgs>().source?.name}'),
        ),
      ),
      AutoRoute(
        path: '/plex-server-edit',
        page: PageInfo(
          PlexServerEditRoute.name,
          builder: (data) {
            final args = data.argsAs<PlexServerEditRouteArgs>();
            return Text('plex edit ${args.source?.name}${args.focusToken ? ' token' : ''}');
          },
        ),
      ),
    ],
  );

  await tester.pumpWidget(
    EasyLocalization(
      supportedLocales: locales.values.toList(),
      path: translationsPath,
      startLocale: locales.values.first,
      fallbackLocale: locales.values.first,
      saveLocale: false,
      useFallbackTranslations: true,
      assetLoader: const CodegenLoader(),
      child: ProviderScope(
        overrides: overrides,
        child: Builder(
          builder: (context) => MaterialApp.router(
            debugShowCheckedModeBanner: false,
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            routerConfig: router.config(),
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return router;
}

/// A tiny HTTP server standing in for the media bridge: serves the files of [share] under [baseUrl], with Range
/// requests, and records the requests
class TestMediaServer {
  TestMediaServer._(this._server, this.share) {
    _server.listen(_serve);
  }

  static Future<TestMediaServer> start(MemoryShare share) async =>
      TestMediaServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), share);

  final HttpServer _server;

  /// Whose files are served; replaced by the tests that need another one
  MemoryShare share;

  final List<({String method, String path, String? range})> requests = [];

  /// Holds the answers until completed, when set
  Completer<void>? gate;

  /// Requests being answered now, and the most there were at once
  int inFlight = 0;
  int maxInFlight = 0;

  Uri get baseUrl => Uri.parse('http://127.0.0.1:${_server.port}/token/${share.source.id}');

  /// The URL of the file at [path] of the share
  Uri urlOf(String path) => Uri.parse('$baseUrl$path');

  Future<void> _serve(HttpRequest request) async {
    final prefix = '/token/${share.source.id}';
    final path = request.uri.path.startsWith(prefix) ? request.uri.path.substring(prefix.length) : '';
    final range = request.headers.value(HttpHeaders.rangeHeader);
    requests.add((method: request.method, path: path, range: range));
    inFlight++;
    maxInFlight = math.max(maxInFlight, inFlight);
    try {
      await gate?.future;
      await _answer(request, path, range);
    } finally {
      inFlight--;
    }
  }

  Future<void> _answer(HttpRequest request, String path, String? range) async {
    final response = request.response;
    final bytes = share.files[path];
    if (bytes == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    var start = 0;
    var end = bytes.length;
    final match = range == null ? null : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
    if (match != null) {
      start = int.parse(match.group(1)!);
      final last = match.group(2)!;
      end = math.min(last.isEmpty ? bytes.length : int.parse(last) + 1, bytes.length);
      if (start >= bytes.length) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${end - 1}/${bytes.length}');
    }
    response.contentLength = end - start;
    if (request.method != 'HEAD') {
      response.add(Uint8List.sublistView(bytes, start, end));
    }
    try {
      await response.close();
    } catch (_) {
      // The client went away
    }
  }

  Future<void> close() => _server.close(force: true);
}

/// Lets the real I/O of the test (the server, the HTTP clients, the image decoders) go on, and the widgets follow,
/// until [done] or a few seconds passed
Future<void> pumpRealIo(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

/// Ends a test that did real I/O: unmounts the widgets, then lets the timers the HTTP clients and the viewers started
/// meanwhile (idle connections, read timeouts) run out
Future<void> endRealIo(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}
