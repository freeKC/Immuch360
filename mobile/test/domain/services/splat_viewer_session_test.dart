// The session of one viewing of the splat viewer (lot SV1), served by the real media bridge over HTTP on loopback, as
// the page fetches it: the page with its Content-Security-Policy, the modules as JavaScript, the session and the scene
// never cached, the events posted back; nothing once the session is gone.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/splat_viewer_host.dart';
import 'package:immich_mobile/domain/services/splat_viewer_session.dart';

Future<({int status, HttpHeaders headers, Uint8List body})> _send(
  Uri url, {
  String method = 'GET',
  String? range,
  List<int>? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, url);
    if (range != null) {
      request.headers.set(HttpHeaders.rangeHeader, range);
    }
    if (body != null) {
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close();
    final received = BytesBuilder(copy: false);
    await response.forEach(received.add);
    return (status: response.statusCode, headers: response.headers, body: received.takeBytes());
  } finally {
    client.close();
  }
}

void main() {
  late LocalMediaBridge bridge;
  late Directory folder;
  late File scene;
  late SplatViewerSession session;
  final events = <SplatViewerEvent>[];
  final page = {for (final name in splatViewerPageFiles) name: File('$splatViewerAssetFolder/$name').readAsBytesSync()};
  const id = '00112233445566778899aabbccddeeff';
  final json = {
    'v': 1,
    'scene': {'url': 'scene.spz', 'type': 'spz', 'name': 'axes_v2.spz', 'bytes': 913, 'gaussians': 686},
    'device': 'computer',
  };

  setUp(() async {
    events.clear();
    folder = await Directory.systemTemp.createTemp('splat_viewer_session_test');
    scene = File('test/fixtures/splat/axes_v2.spz').copySync('${folder.path}/axes_v2.spz');
    session = SplatViewerSession(
      id: id,
      page: page,
      session: json,
      scene: scene,
      sceneName: 'scene.spz',
      onEvent: events.add,
    );
    bridge = LocalMediaBridge();
    await bridge.start();
    bridge.registerGenerated(id, session);
  });

  tearDown(() async {
    await bridge.stop();
    await folder.delete(recursive: true);
  });

  test('every file of the page is in the assets', () {
    for (final name in splatViewerPageFiles) {
      expect(File('$splatViewerAssetFolder/$name').existsSync(), isTrue, reason: name);
    }
  });

  test('the page with a CSP of the app\'s own origin, its import map allowed by its hash', () async {
    final reply = await _send(bridge.urlFor(id, 'index.html'));
    expect(reply.status, HttpStatus.ok);
    expect(reply.headers.value(HttpHeaders.contentTypeHeader), 'text/html; charset=utf-8');
    expect(reply.headers.value('x-content-type-options'), 'nosniff');
    final csp = reply.headers.value('content-security-policy')!;
    expect(csp, startsWith("default-src 'none'; script-src 'self' 'wasm-unsafe-eval' blob: 'sha256-"));
    expect(csp, contains("connect-src 'self'"));
    expect(csp, isNot(contains('http')), reason: 'nothing from outside the app');
    final html = utf8.decode(reply.body);
    final importMap = RegExp(r'<script type="importmap">(.*?)</script>', dotAll: true).firstMatch(html)!.group(1)!;
    expect(csp, contains("'sha256-${base64.encode(sha256.convert(utf8.encode(importMap)).bytes)}'"));
    expect(splatViewerCsp(html), csp);
  });

  test('the modules as JavaScript, the WebAssembly as such, each the bytes of its asset', () async {
    for (final name in ['viewer.js', 'spark.module.min.js', 'three.module.min.js', 'Pass.js']) {
      final reply = await _send(bridge.urlFor(id, name));
      expect(reply.status, HttpStatus.ok, reason: name);
      expect(reply.headers.value(HttpHeaders.contentTypeHeader), 'text/javascript; charset=utf-8', reason: name);
      expect(reply.body, page[name], reason: name);
    }
    final wasm = await _send(bridge.urlFor(id, 'spark_rs_bg.wasm'));
    expect(wasm.headers.value(HttpHeaders.contentTypeHeader), 'application/wasm');
    expect(wasm.body.sublist(0, 4), [0, 0x61, 0x73, 0x6d]);
  });

  test('the session and the scene, never cached; the scene by ranges', () async {
    final reply = await _send(bridge.urlFor(id, 'session.json'));
    expect(jsonDecode(utf8.decode(reply.body)), json);
    expect(reply.headers.value(HttpHeaders.cacheControlHeader), 'no-store');
    final whole = await _send(bridge.urlFor(id, 'scene.spz'));
    expect(whole.body, scene.readAsBytesSync());
    expect(whole.headers.value(HttpHeaders.cacheControlHeader), 'no-store');
    final part = await _send(bridge.urlFor(id, 'scene.spz'), range: 'bytes=4-9');
    expect(part.status, HttpStatus.partialContent);
    expect(part.body, scene.readAsBytesSync().sublist(4, 10));
    expect((await _send(bridge.urlFor(id, 'scene.ply'))).status, HttpStatus.notFound);
    expect((await _send(bridge.urlFor(id, 'secret.txt'))).status, HttpStatus.notFound);
  });

  test('the events of the page reach the app; anything else is dropped', () async {
    Future<int> post(String name, String body) async =>
        (await _send(bridge.urlFor(id, name), method: 'POST', body: utf8.encode(body))).status;
    expect(
      await post('events', '{"type":"ready","loadMs":120,"gaussians":686,"renderer":"GPU","nonBlank":0.04}'),
      HttpStatus.noContent,
    );
    expect(await post('events', '{"type":"upright","value":"yUp"}'), HttpStatus.noContent);
    expect(await post('events', '{"type":"stats","fps":59.5}'), HttpStatus.noContent);
    expect(await post('events', '{"type":"close"}'), HttpStatus.noContent);
    expect(await post('events', 'not json'), HttpStatus.noContent);
    expect(await post('events', '{"type":"something new"}'), HttpStatus.noContent);
    expect(await post('index.html', '{"type":"close"}'), HttpStatus.notFound);
    expect(events, hasLength(4));
    final ready = events[0] as SplatViewerReady;
    expect(ready.loadMs, 120);
    expect(ready.gaussians, 686);
    expect(ready.renderer, 'GPU');
    expect(ready.nonBlank, closeTo(0.04, 1e-9));
    expect((events[1] as SplatViewerUpright).value, 'yUp');
    expect((events[2] as SplatViewerStats).fps, 59.5);
    expect(events[3], isA<SplatViewerClose>());
  });

  test('the first frames of a computer: what the page found, the reduced copy taken, every gaussian kept', () {
    final watch = SplatViewerEvent.parse({'type': 'watch', 'slow': true, 'fps': 19.3, 'keep': 1710000})!;
    expect(watch, isA<SplatViewerWatch>());
    expect((watch as SplatViewerWatch).slow, isTrue);
    expect(watch.fps, 19.3);
    expect(watch.keep, 1710000);
    expect((SplatViewerEvent.parse({'type': 'watch', 'slow': false, 'fps': 117})! as SplatViewerWatch).slow, isFalse);
    expect((SplatViewerEvent.parse({'type': 'reduce', 'keep': 1710000})! as SplatViewerReduce).keep, 1710000);
    expect(SplatViewerEvent.parse({'type': 'reduce', 'keep': 0}), isNull);
    expect(SplatViewerEvent.parse({'type': 'reduce', 'keep': '1000'}), isNull);
    expect(SplatViewerEvent.parse({'type': 'keepWhole'}), isA<SplatViewerKeepWhole>());
  });

  test('nothing is served once the session is unregistered', () async {
    bridge.unregisterGenerated(id);
    expect((await _send(bridge.urlFor(id, 'index.html'))).status, HttpStatus.notFound);
    expect((await _send(bridge.urlFor(id, 'events'), method: 'POST', body: [123, 125])).status, HttpStatus.notFound);
  });

  test('ids are random, 16 bytes in hex', () {
    final ids = {for (var i = 0; i < 50; i++) newSplatViewerSessionId()};
    expect(ids, hasLength(50));
    expect(ids.every((value) => RegExp(r'^[0-9a-f]{32}$').hasMatch(value)), isTrue);
  });

  test('the viewer keeps to the session\'s folder', () {
    final url = bridge.urlFor(id, 'index.html');
    final prefix = splatViewerPrefixOf(url);
    expect(prefix, endsWith('/$id/'));
    expect(splatViewerAllows(prefix, url.toString()), isTrue);
    expect(splatViewerAllows(prefix, '${prefix}viewer.js'), isTrue);
    expect(splatViewerAllows(prefix, 'https://example.com/'), isFalse);
    expect(splatViewerAllows(prefix, bridge.urlFor('other', 'index.html').toString()), isFalse);
    expect(splatViewerAllows(prefix, '$prefix../other/index.html'), isFalse);
  });

  test('the content types of the page', () {
    expect(splatViewerContentType('a.js'), 'text/javascript; charset=utf-8');
    expect(splatViewerContentType('a.css'), 'text/css; charset=utf-8');
    expect(splatViewerContentType('a.wasm'), 'application/wasm');
    expect(splatViewerContentType('a'), 'application/octet-stream');
  });
}
