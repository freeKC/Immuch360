// The DLNA client against real media servers (IMMUCH_NET_TESTS=1): minidlna at IMMUCH_DLNA_URL, by default
// http://127.0.0.1:8200/rootDesc.xml, or several servers separated by commas (minidlna, Gerbera...). Each server is
// expected to serve synthetic media only, at least one folder holding a video. See section 3.10 of the design of
// build 19 for the Docker commands.
//
// SSDP: the discovery binds to IMMUCH_SSDP_BIND when given (the address of the Docker bridge, 172.17.0.1, so that the
// multicast reaches the containers), and sweeps IMMUCH_SSDP_HOSTS (comma separated) instead of the local subnet. It
// must find every server of IMMUCH_DLNA_URL; IMMUCH_SSDP_UNICAST lists those expected to answer the unicast sweep
// alone (minidlna does not: on Linux it binds its SSDP socket to the multicast group).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/infrastructure/network/upnp/dlna_file_system.dart';
import 'package:immich_mobile/infrastructure/network/upnp/ssdp.dart';

List<String> _list(String? value) =>
    (value ?? '').split(',').map((part) => part.trim()).where((part) => part.isNotEmpty).toList();

NetworkSource _sourceOf(Uri description) => NetworkSource(
  id: 'dlna-${description.host}-${description.port}',
  type: NetworkSourceType.dlna,
  name: description.host,
  host: description.host,
  port: description.port,
  share: description.hasQuery ? '${description.path}?${description.query}' : description.path,
  useTls: description.scheme == 'https',
);

void main() {
  final enabled = Platform.environment['IMMUCH_NET_TESTS'] == '1';
  final urls = _list(Platform.environment['IMMUCH_DLNA_URL'] ?? 'http://127.0.0.1:8200/rootDesc.xml').map(Uri.parse);
  final bind = Platform.environment['IMMUCH_SSDP_BIND'];
  final sweepHosts = _list(Platform.environment['IMMUCH_SSDP_HOSTS']);
  final unicastOnly = _list(Platform.environment['IMMUCH_SSDP_UNICAST']).map(Uri.parse).toList();

  for (final url in urls) {
    group('DLNA server at $url', () {
      test('opens, lists the root and goes down to a folder with a video, reads its first 64 KiB', () async {
        final fileSystem = await DlnaFileSystem.open(_sourceOf(url), null);
        addTearDown(fileSystem.close);
        expect(fileSystem.device.contentDirectoryType, startsWith('urn:schemas-upnp-org:service:ContentDirectory:'));

        final root = await fileSystem.list('/');
        expect(root.where((entry) => entry.isDirectory), isNotEmpty);

        // Breadth first, a few levels down: the servers group the files by type, date, folder
        final queue = [for (final entry in root) entry];
        var listed = 0;
        while (queue.isNotEmpty && listed < 40) {
          final entry = queue.removeAt(0);
          if (entry.isVideo) {
            final stat = await fileSystem.stat(entry.path);
            expect(stat.size, greaterThan(0), reason: entry.path);
            final head = await fileSystem.readRange(entry.path, 0, 64 * 1024);
            expect(head.length, stat.size! < 64 * 1024 ? stat.size : 64 * 1024, reason: entry.path);
            // An MP4 or a QuickTime file: "ftyp" after the size of the first box
            expect(String.fromCharCodes(head.sublist(4, 8)), anyOf('ftyp', 'wide', 'mdat', 'moov'), reason: entry.path);
            final again = await fileSystem.readRange(entry.path, 1000, 100);
            expect(again, head.sublist(1000, 1100));
            return;
          }
          if (entry.isDirectory) {
            listed++;
            queue.addAll(await fileSystem.list(entry.path));
          }
        }
        fail('No video found on $url');
      }, skip: !enabled);

      test('streams a file through the media bridge with a Range request', () async {
        final fileSystem = await DlnaFileSystem.open(_sourceOf(url), null);
        addTearDown(fileSystem.close);
        final bridge = LocalMediaBridge();
        addTearDown(bridge.stop);
        await bridge.start();
        bridge.register(fileSystem);

        final queue = [...await fileSystem.list('/')];
        while (queue.isNotEmpty) {
          final entry = queue.removeAt(0);
          if (entry.isMedia) {
            final client = HttpClient();
            addTearDown(client.close);
            final request = await client.getUrl(bridge.urlFor(fileSystem.source.id, entry.path));
            request.headers.set(HttpHeaders.rangeHeader, 'bytes=10-109');
            final response = await request.close();
            final body = await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
            expect(response.statusCode, HttpStatus.partialContent, reason: entry.path);
            expect(body, await fileSystem.readRange(entry.path, 10, 100), reason: entry.path);
            expect(bridge.urlFor(fileSystem.source.id, entry.path).host, '127.0.0.1');
            return;
          }
          if (entry.isDirectory) {
            queue.addAll(await fileSystem.list(entry.path));
          }
        }
        fail('No media found on $url');
      }, skip: !enabled);
    });
  }

  test('SsdpProbe finds the servers', () async {
    final done = Completer<void>();
    final probe = SsdpProbe(bind: () => bindSsdpTransport(address: bind == null ? null : InternetAddress(bind)));
    final found = <DiscoveredServer>[];
    final subscription = probe(
      DiscoveryRequest(hosts: sweepHosts.isEmpty ? null : sweepHosts, done: done.future),
    ).listen(found.add);
    await Future<void>.delayed(const Duration(seconds: 5));
    done.complete();
    await subscription.cancel();

    for (final url in urls) {
      final server = found.where((s) => s.host == url.host && s.port == url.port).firstOrNull;
      expect(server, isNotNull, reason: '$url among $found');
      expect(server!.type, NetworkSourceType.dlna);
      expect(server.path, url.path);
      expect(server.discoveryId, startsWith('uuid:'));
      expect(server.origin, DiscoveryOrigin.ssdp);
    }
  }, skip: !enabled);

  test('SsdpProbe finds the servers that answer a unicast search, through the sweep alone', () async {
    final done = Completer<void>();
    // Bound to every interface: the multicast leaves through the default route, away from the servers
    final probe = SsdpProbe(localAddresses: () async => const []);
    final found = <DiscoveredServer>[];
    final subscription = probe(
      DiscoveryRequest(hosts: [for (final url in unicastOnly) url.host], done: done.future),
    ).listen(found.add);
    await Future<void>.delayed(const Duration(seconds: 4));
    done.complete();
    await subscription.cancel();

    for (final url in unicastOnly) {
      expect(found.where((s) => s.host == url.host && s.port == url.port), isNotEmpty, reason: '$url among $found');
    }
  }, skip: !enabled || unicastOnly.isEmpty);
}
