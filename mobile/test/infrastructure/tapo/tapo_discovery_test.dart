// The TP-Link discovery of the cameras: the probe datagram (header, CRC32, the PEM of the key), the answers (a synthetic
// one after the example of P§1, with an encrypt_info made with a key of the test), the filter on the cameras, and the
// probe on fake sockets: broadcast to 20002 and 20004, the sweep of the hosts, one find per camera.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/infrastructure/network/udp_transport.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_discovery.dart';
import 'package:pointycastle/asn1.dart';

import 'fake_tapo_camera.dart';

/// A reply as a camera sends it: the header of the probe, then the JSON
Uint8List _reply(Map<String, Object?> result) => Uint8List.fromList([
  ...tdpBareProbe,
  ...utf8.encode(jsonEncode({'result': result, 'error_code': 0})),
]);

Map<String, Object?> _cameraResult({String type = 'SMART.IPCAMERA', String ip = fakeCameraHost, Object? encryptInfo}) =>
    {
      'device_type': type,
      'device_model': 'C510W(EU)',
      'ip': ip,
      'mac': fakeCameraMac.toUpperCase(),
      'mgt_encrypt_schm': {'is_support_https': true},
      'encrypt_type': ['4'],
      'tpap': {
        'pake': [2],
        'tls': 1,
        'noc': 1,
        'port': 443,
      },
      'encrypt_info': ?encryptInfo,
      'firmware_version': '1.3.4 Build 260523 Rel.33481n',
    };

class _FakeUdp implements UdpTransport {
  final sent = <(List<int>, String, int)>[];
  final _datagrams = StreamController<Datagram>();
  bool closed = false;

  @override
  Stream<Datagram> get datagrams => _datagrams.stream;

  @override
  void send(List<int> bytes, InternetAddress address, int port) => sent.add((bytes, address.address, port));

  void answer(Uint8List data, String from) => _datagrams.add(Datagram(data, InternetAddress(from), tdpPort));

  @override
  void close() {
    closed = true;
    unawaited(_datagrams.close());
  }
}

/// Waits until [done] holds: the rounds of the probe run on timers, late on a loaded machine
Future<void> _until(bool Function() done) async {
  final limit = DateTime.now().add(const Duration(seconds: 20));
  while (!done() && DateTime.now().isBefore(limit)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late TdpKeyPair key;

  setUpAll(() => key = generateTdpKeyPair(bits: 1024));

  test('builds the probe: header, length, flags, serial and the CRC32 of the whole datagram', () {
    final probe = tdpProbe(key, serial: 0x01020304);
    final data = ByteData.sublistView(probe);
    expect(data.getUint8(0), 2);
    expect(data.getUint8(1), 0);
    expect(data.getUint16(2), 1);
    expect(data.getUint16(4), probe.length - 16);
    expect(data.getUint8(6), 17);
    expect(data.getUint32(8), 0x01020304);
    final withConstant = Uint8List.fromList(probe)..buffer.asByteData().setUint32(12, 0x5a6b7c8d);
    expect(data.getUint32(12), crc32(withConstant));
    final payload = jsonDecode(utf8.decode(probe.sublist(16))) as Map;
    final pem = (payload['params'] as Map)['rsa_key'] as String;
    expect(pem, startsWith('-----BEGIN PUBLIC KEY-----\n'));
    expect(pem, endsWith('\n-----END PUBLIC KEY-----\n'));
  });

  test('writes the public key as a SubjectPublicKeyInfo of rsaEncryption', () {
    final body = key.publicPem.split('\n').where((line) => !line.startsWith('-----') && line.isNotEmpty).join();
    final info = ASN1Parser(base64.decode(body)).nextObject() as ASN1Sequence;
    final algorithm = info.elements![0] as ASN1Sequence;
    expect((algorithm.elements![0] as ASN1ObjectIdentifier).objectIdentifierAsString, '1.2.840.113549.1.1.1');
    final bits = info.elements![1] as ASN1BitString;
    final rsa = ASN1Parser(Uint8List.fromList(bits.stringValues!)).nextObject() as ASN1Sequence;
    expect((rsa.elements![0] as ASN1Integer).integer, key.modulus);
    expect((rsa.elements![1] as ASN1Integer).integer, BigInt.from(65537));
  });

  test('reads an answer, opens its encrypt_info with the key, and tells a camera from a plug', () {
    final aesKey = Uint8List.fromList(List.generate(16, (i) => i));
    final iv = Uint8List.fromList(List.generate(16, (i) => 16 + i));
    final encryptInfo = {
      'sym_schm': 'AES',
      'key': base64.encode(key.encrypt(Uint8List.fromList([...aesKey, ...iv]))),
      'data': base64.encode(aesCbcEncrypt(aesKey, iv, utf8.encode('{"http_port":443,"sd_status":"normal"}'))),
    };
    final reply = parseTdpReply(_reply(_cameraResult(encryptInfo: encryptInfo)), key: key)!;
    expect(reply.isCamera, isTrue);
    expect(reply.model, 'C510W');
    expect(reply.mac, fakeCameraMac);
    expect(reply.ip, fakeCameraHost);
    expect(reply.firmware, '1.3.4 Build 260523 Rel.33481n');
    expect(reply.offersV4, isTrue);
    expect(reply.sdStatus, 'normal');

    // Without the key, the clear fields are enough
    expect(parseTdpReply(_reply(_cameraResult(encryptInfo: encryptInfo)))!.sdStatus, isNull);
    expect(parseTdpReply(_reply(_cameraResult(type: 'SMART.TAPOPLUG')))!.isCamera, isFalse);
    expect(parseTdpReply(_reply(_cameraResult(type: 'SMART.TAPODOORBELL')))!.isCamera, isTrue);
    expect(parseTdpReply(Uint8List.fromList([...tdpBareProbe, ...utf8.encode('not json')])), isNull);
    expect(parseTdpReply(tdpBareProbe), isNull);
  });

  test('makes a find of type tapo on 443, with the MAC and the firmware', () {
    final server = tdpServerOf(parseTdpReply(_reply(_cameraResult()))!);
    expect(server.type, NetworkSourceType.tapo);
    expect(server.host, fakeCameraHost);
    expect(server.port, 443);
    expect(server.useTls, isTrue);
    expect(server.displayName, 'Tapo C510W');
    expect(server.discoveryId, fakeCameraMac);
    expect(server.version, '1.3.4 Build 260523 Rel.33481n');
    expect(server.origin, DiscoveryOrigin.tdp);
    // The login it announces leads its first test: straight to V4, never down to V2
    expect(server.camera?.protocol, TapoLoginProtocol.v4);
    expect(server.camera?.userName, isNull);
    final hashed = _cameraResult()
      ..['tpap'] = {
        'pake': [2],
        'user_hash_type': 1,
      };
    expect(tdpServerOf(parseTdpReply(_reply(hashed))!).camera?.userName, TapoUserNameForm.sha256);
    final older = _cameraResult()
      ..['encrypt_type'] = ['3']
      ..remove('tpap');
    expect(tdpServerOf(parseTdpReply(_reply(older))!).camera, isNull);
  });

  test('broadcasts to 20002 and 20004, sweeps the hosts, and finds each camera once', () async {
    final sockets = <_FakeUdp>[];
    final probe = TapoDiscoveryProbe(
      bind: ({InternetAddress? address, bool broadcast = false}) async {
        final socket = _FakeUdp();
        sockets.add(socket);
        return socket;
      },
      keyPair: () async => key,
      roundsAt: const [Duration.zero, Duration(milliseconds: 50)],
    );
    final done = Completer<void>();
    final request = DiscoveryRequest(hosts: ['192.0.2.30', '192.0.2.31'], done: done.future);
    final found = <DiscoveredServer>[];
    final subscription = probe(request).listen(found.add);
    await _until(() => sockets.length == 2 && sockets[1].sent.where((sent) => sent.$2 == '192.0.2.31').length == 4);
    expect(sockets, hasLength(2));
    final (group, sweep) = (sockets[0], sockets[1]);
    await _until(() => group.sent.length >= 4);
    expect(
      group.sent.map((sent) => (sent.$2, sent.$3)),
      containsAll([('255.255.255.255', 20002), ('255.255.255.255', 20004)]),
    );
    expect(sweep.sent.map((sent) => (sent.$2, sent.$3)).toSet(), {('192.0.2.30', 20002), ('192.0.2.31', 20002)});
    // The keyed probe and the bare one, in each of the two rounds
    expect(sweep.sent.where((sent) => sent.$2 == '192.0.2.30'), hasLength(4));

    sweep.answer(_reply(_cameraResult()), '192.0.2.30');
    sweep.answer(_reply(_cameraResult()), '192.0.2.30');
    group.answer(_reply(_cameraResult(type: 'SMART.TAPOPLUG', ip: '192.0.2.31')), '192.0.2.31');
    await _until(() => found.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(found.map((server) => server.host), [fakeCameraHost]);

    done.complete();
    await _until(() => sockets.every((socket) => socket.closed));
    expect(sockets.every((socket) => socket.closed), isTrue);
    await subscription.cancel();
  });

  test('ends quietly when no socket can be had', () async {
    final probe = TapoDiscoveryProbe(
      bind: ({InternetAddress? address, bool broadcast = false}) async => throw const SocketException('none'),
      keyPair: () async => key,
    );
    final done = Completer<void>();
    expect(await probe(DiscoveryRequest(done: done.future)).toList(), isEmpty);
  });
}
