// Finds the Tapo cameras of the local network with the TP-Link discovery protocol (TDP, UDP 20002, Tapo design 2.2 and
// 3.3): a 16 byte header (version 2, probe, flags 17, a random serial, the CRC32 of the whole datagram) then the PEM of
// an RSA public key in JSON. Each device answers to the port the probe came from with its type, model, MAC address,
// address, firmware and login generation in clear, and an encrypt_info only that key opens (the state of the memory
// card).
//
// As for SSDP (see ../network/upnp/ssdp.dart), the probe goes to the broadcast address from one socket and to every
// host of the local /24 subnets from another: iOS fails the broadcast without the multicast entitlement, and a failed
// send closes the socket it went from. The older 16 byte probe without a key is sent too, in case a camera answers it.
// The RSA key is made once per run, off the UI isolate.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/infrastructure/network/udp_transport.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:logging/logging.dart';
import 'package:pointycastle/export.dart';

final _log = Logger('TapoDiscovery');

/// The port the devices listen on; python-kasa also sends to [tdpAltPort]
const tdpPort = 20002;
const tdpAltPort = 20004;

/// The device types of the cameras (a doorbell is one too)
const tdpCameraTypes = {'SMART.IPCAMERA', 'SMART.TAPODOORBELL'};

/// The older probe, without a key (python-kasa DISCOVERY_QUERY_2)
final Uint8List tdpBareProbe = bytesOfHex('020000010000000000000000463cb5d3');

/// An RSA key pair for the probe: the public key goes out as PEM, the private one opens encrypt_info
class TdpKeyPair {
  TdpKeyPair(this.modulus, this.publicExponent, this.privateExponent, this.p, this.q);

  final BigInt modulus;
  final BigInt publicExponent;
  final BigInt privateExponent;
  final BigInt p;
  final BigInt q;

  /// The PEM of the SubjectPublicKeyInfo of the public key, as python-kasa sends it
  late final String publicPem = () {
    final der = _derSequence([
      _derSequence([
        // rsaEncryption, NULL parameters
        Uint8List.fromList([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]),
        Uint8List.fromList([0x05, 0x00]),
      ]),
      _derBitString(_derSequence([_derInteger(modulus), _derInteger(publicExponent)])),
    ]);
    final text = base64.encode(der);
    final lines = [for (var i = 0; i < text.length; i += 64) text.substring(i, min(i + 64, text.length))];
    return '-----BEGIN PUBLIC KEY-----\n${lines.join('\n')}\n-----END PUBLIC KEY-----\n';
  }();

  /// RSA-OAEP with SHA-1 (the default of pointycastle and what the devices use) of [cipherText]
  Uint8List decrypt(Uint8List cipherText) {
    final engine = OAEPEncoding(RSAEngine())
      ..init(false, PrivateKeyParameter<RSAPrivateKey>(RSAPrivateKey(modulus, privateExponent, p, q)));
    return engine.process(cipherText);
  }

  /// The encryption of the devices, for the tests
  Uint8List encrypt(Uint8List plain) {
    final engine = OAEPEncoding(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(RSAPublicKey(modulus, publicExponent)));
    return engine.process(plain);
  }

  @override
  String toString() => 'TdpKeyPair';
}

/// A new RSA key pair of [bits] bits; slow (up to seconds for 2048 bits on a phone)
TdpKeyPair generateTdpKeyPair({int bits = 2048}) {
  final random = FortunaRandom()..seed(KeyParameter(randomBytes(32)));
  final generator = RSAKeyGenerator()
    ..init(ParametersWithRandom(RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64), random));
  final pair = generator.generateKeyPair();
  final public = pair.publicKey;
  final private = pair.privateKey;
  return TdpKeyPair(public.modulus!, public.publicExponent!, private.privateExponent!, private.p!, private.q!);
}

Future<TdpKeyPair>? _runKey;

/// The key pair of this run, made once in an isolate
Future<TdpKeyPair> tdpKeyPair() {
  final running = _runKey ??= Isolate.run(generateTdpKeyPair);
  // A failure is not kept: the next discovery tries again
  unawaited(
    running.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_runKey, running)) {
          _runKey = null;
        }
      },
    ),
  );
  return running;
}

/// The probe datagram with the public key of [key]; [serial] is random, given by the tests
Uint8List tdpProbe(TdpKeyPair key, {int? serial}) {
  final payload = utf8.encode(
    jsonEncode({
      'params': {'rsa_key': key.publicPem},
    }),
  );
  final header = ByteData(16)
    ..setUint8(0, 2) // version
    ..setUint8(1, 0) // message type
    ..setUint16(2, 1) // probe
    ..setUint16(4, payload.length)
    ..setUint8(6, 17) // flags
    ..setUint8(7, 0)
    ..setUint32(8, serial ?? Random.secure().nextInt(1 << 32))
    ..setUint32(12, 0x5a6b7c8d);
  final datagram = Uint8List(16 + payload.length)
    ..setRange(0, 16, header.buffer.asUint8List())
    ..setRange(16, 16 + payload.length, payload);
  // The CRC is computed while its field holds the constant above, then replaces it
  ByteData.sublistView(datagram).setUint32(12, crc32(datagram));
  return datagram;
}

/// What a device answers to the probe
class TdpReply {
  const TdpReply({
    required this.deviceType,
    required this.model,
    required this.mac,
    required this.ip,
    this.firmware,
    this.encryptTypes = const [],
    this.pake = const [],
    this.userHashType,
    this.sdStatus,
  });

  final String deviceType;

  /// What is before a "(" of device_model ("C510W")
  final String model;

  /// aa-bb-cc-dd-ee-ff, lower case
  final String mac;
  final String ip;
  final String? firmware;

  /// encrypt_type (["4"] on V4 firmware), and the pake list of the tpap object
  final List<String> encryptTypes;
  final List<int> pake;
  final int? userHashType;

  /// The state of the memory card from encrypt_info ("normal"), when the key opened it
  final String? sdStatus;

  bool get isCamera => tdpCameraTypes.contains(deviceType);

  /// Whether the device announces the V4 login (TPAP)
  bool get offersV4 => encryptTypes.contains('4') || pake.contains(2);
}

/// The answer in [data] (the 16 byte header, then JSON), null when it is not one. [key] opens encrypt_info.
TdpReply? parseTdpReply(Uint8List data, {TdpKeyPair? key, String? sender}) {
  if (data.length <= 16) {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(Uint8List.sublistView(data, 16), allowMalformed: true));
  } on FormatException {
    return null;
  }
  if (decoded is! Map) {
    return null;
  }
  final result = decoded['result'];
  if (result is! Map) {
    return null;
  }
  final deviceType = result['device_type'];
  final mac = result['mac'];
  if (deviceType is! String || mac is! String) {
    return null;
  }
  final ipText = result['ip'];
  final address = ipText is String ? InternetAddress.tryParse(ipText) : null;
  final ip = address != null && address.type == InternetAddressType.IPv4 ? address.address : sender;
  if (ip == null) {
    return null;
  }
  final model = '${result['device_model'] ?? ''}'.split('(').first.trim();
  final firmware = result['firmware_version'];
  final encryptTypes = <String>[];
  final encryptType = result['encrypt_type'];
  if (encryptType is List) {
    encryptTypes.addAll(encryptType.map((type) => '$type'));
  } else if (encryptType != null) {
    encryptTypes.add('$encryptType');
  }
  final scheme = result['mgt_encrypt_schm'];
  if (scheme is Map && scheme['encrypt_type'] != null) {
    encryptTypes.add('${scheme['encrypt_type']}');
  }
  final tpap = result['tpap'];
  final pake = <int>[
    if (tpap is Map && tpap['pake'] is List)
      for (final value in tpap['pake'] as List)
        if (value is int) value,
  ];
  final userHashType = tpap is Map && tpap['user_hash_type'] is int ? tpap['user_hash_type'] as int : null;

  String? sdStatus;
  final encryptInfo = result['encrypt_info'];
  if (key != null && encryptInfo is Map) {
    try {
      final keyAndIv = key.decrypt(base64.decode('${encryptInfo['key']}'));
      if (keyAndIv.length >= 32) {
        final plain = aesCbcDecrypt(
          Uint8List.sublistView(keyAndIv, 0, 16),
          Uint8List.sublistView(keyAndIv, 16, 32),
          base64.decode('${encryptInfo['data']}'),
        );
        final info = jsonDecode(utf8.decode(plain, allowMalformed: true));
        if (info is Map && info['sd_status'] is String) {
          sdStatus = info['sd_status'] as String;
        }
      }
    } catch (error) {
      // Only the hint of the memory card is lost
      _log.finest('The encrypt_info of a TDP answer could not be read: ${error.runtimeType}');
    }
  }
  return TdpReply(
    deviceType: deviceType,
    model: model,
    mac: mac.replaceAll(':', '-').toLowerCase(),
    ip: ip,
    firmware: firmware is String && firmware.isNotEmpty ? firmware : null,
    encryptTypes: encryptTypes,
    pake: pake,
    userHashType: userHashType,
    sdStatus: sdStatus,
  );
}

/// What the found list shows for a camera that answered, with the login it announces: V4 goes straight to V4 (Tapo
/// design 2.4), so that whoever answers the first probe in the camera's place cannot lead the login down to V2 and its
/// unsalted hash of the password; user_hash_type 1 names the SHA-256 form of the user name
DiscoveredServer tdpServerOf(TdpReply reply) => DiscoveredServer(
  host: reply.ip,
  displayName: reply.model.isEmpty ? 'Tapo' : 'Tapo ${reply.model}',
  type: NetworkSourceType.tapo,
  port: 443,
  useTls: true,
  origin: DiscoveryOrigin.tdp,
  discoveryId: reply.mac,
  version: reply.firmware,
  camera: reply.offersV4
      ? TapoCameraInfo(
          protocol: TapoLoginProtocol.v4,
          userName: reply.userHashType == 1 ? TapoUserNameForm.sha256 : null,
        )
      : null,
);

/// A [DiscoveryProbe] for the Tapo cameras, see the header
class TapoDiscoveryProbe {
  const TapoDiscoveryProbe({
    this.bind = bindUdpTransport,
    this.localAddresses = localIPv4Addresses,
    this.keyPair = tdpKeyPair,
    this.roundsAt = const [Duration.zero, Duration(milliseconds: 1500), Duration(seconds: 3)],
    this.keyWait = const Duration(seconds: 1),
    this.sweepBatch = 32,
    this.sweepInterval = const Duration(milliseconds: 20),
    this.port = tdpPort,
  });

  /// Opens a socket: one for the broadcast, one for the sweep
  final Future<UdpTransport> Function({InternetAddress? address, bool broadcast}) bind;
  final Future<List<String>> Function() localAddresses;
  final Future<TdpKeyPair> Function() keyPair;

  /// When each round of probes goes out: UDP may lose them
  final List<Duration> roundsAt;

  /// How long the first round waits for the key before it sends the probe without one
  final Duration keyWait;
  final int sweepBatch;
  final Duration sweepInterval;
  final int port;

  Stream<DiscoveredServer> call(DiscoveryRequest request) {
    final controller = StreamController<DiscoveredServer>();
    final stopped = Completer<void>();
    final transports = <UdpTransport>[];
    final subscriptions = <StreamSubscription<Datagram>>[];

    void stop() {
      if (stopped.isCompleted) {
        return;
      }
      stopped.complete();
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
      for (final transport in transports) {
        transport.close();
      }
      if (!controller.isClosed) {
        unawaited(controller.close());
      }
    }

    bool isOver() => stopped.isCompleted || request.isCancelled;

    Future<void> run() async {
      final UdpTransport group;
      final UdpTransport sweep;
      try {
        group = await bind(broadcast: true);
        if (isOver()) {
          group.close();
          return;
        }
        transports.add(group);
        sweep = await bind();
        if (isOver()) {
          sweep.close();
          return;
        }
        transports.add(sweep);
      } catch (error) {
        _log.fine('TDP is not available: $error');
        stop();
        return;
      }

      TdpKeyPair? key;
      final seen = <String>{};
      void received(Datagram datagram) {
        if (isOver()) {
          return;
        }
        // The clear fields are all the found list needs: encrypt_info is not opened here, on the UI isolate
        final reply = parseTdpReply(datagram.data, sender: datagram.address.address);
        if (reply == null || !reply.isCamera || !seen.add(reply.mac)) {
          return;
        }
        controller.add(tdpServerOf(reply));
      }

      for (final transport in [group, sweep]) {
        subscriptions.add(transport.datagrams.listen(received, onError: (Object error) => _log.fine('TDP: $error')));
      }

      final keyed = keyPair().then<TdpKeyPair?>((value) => key = value).catchError((Object error) {
        _log.fine('No RSA key for the TDP probe: $error');
        return null;
      });
      final hosts = await _hosts(request);
      var elapsed = Duration.zero;
      for (final (index, at) in roundsAt.indexed) {
        if (!await _pause(at - elapsed, stopped.future)) {
          return;
        }
        elapsed = at;
        if (index == 0 && key == null) {
          await Future.any([keyed, Future<void>.delayed(keyWait), stopped.future]);
        }
        if (isOver()) {
          return;
        }
        final probes = [if (key case final key?) tdpProbe(key), tdpBareProbe];
        final broadcast = InternetAddress('255.255.255.255');
        for (final probe in probes) {
          group
            ..send(probe, broadcast, port)
            ..send(probe, broadcast, tdpAltPort);
        }
        await _sweep(sweep, hosts, probes, stopped.future, isOver);
      }
    }

    controller.onListen = () => unawaited(run());
    controller.onCancel = stop;
    unawaited(request.done.whenComplete(stop));
    return controller.stream;
  }

  Future<List<InternetAddress>> _hosts(DiscoveryRequest request) async {
    final given = request.hosts;
    final List<String> hosts;
    if (given != null) {
      hosts = given;
    } else {
      final own = await localAddresses();
      hosts = {for (final address in own) ...SubnetScanProbe.subnetHostsOf(address)}.toList();
    }
    return [
      for (final host in hosts)
        if (InternetAddress.tryParse(host) case final address? when address.type == InternetAddressType.IPv4) address,
    ];
  }

  Future<void> _sweep(
    UdpTransport transport,
    List<InternetAddress> hosts,
    List<Uint8List> probes,
    Future<void> stopped,
    bool Function() isOver,
  ) async {
    var sent = 0;
    for (final host in hosts) {
      for (final probe in probes) {
        if (isOver()) {
          return;
        }
        transport.send(probe, host, port);
        sent++;
        if (sent % sweepBatch == 0 && !await _pause(sweepInterval, stopped)) {
          return;
        }
      }
    }
  }

  /// Waits [duration]; false when the discovery stopped meanwhile
  static Future<bool> _pause(Duration duration, Future<void> stopped) async {
    if (duration <= Duration.zero) {
      return true;
    }
    var timedOut = false;
    await Future.any([Future<void>.delayed(duration).then((_) => timedOut = true), stopped]);
    return timedOut;
  }
}

Uint8List _derLength(int length) {
  if (length < 0x80) {
    return Uint8List.fromList([length]);
  }
  final bytes = <int>[];
  for (var rest = length; rest > 0; rest >>= 8) {
    bytes.insert(0, rest & 0xff);
  }
  return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
}

Uint8List _derSequence(List<Uint8List> items) {
  final body = [for (final item in items) ...item];
  return Uint8List.fromList([0x30, ..._derLength(body.length), ...body]);
}

Uint8List _derInteger(BigInt value) {
  var bytes = bytesOfBigInt(value, (value.bitLength + 7) ~/ 8);
  if (bytes.isEmpty || bytes[0] & 0x80 != 0) {
    bytes = Uint8List.fromList([0, ...bytes]);
  }
  return Uint8List.fromList([0x02, ..._derLength(bytes.length), ...bytes]);
}

Uint8List _derBitString(Uint8List content) =>
    Uint8List.fromList([0x03, ..._derLength(content.length + 1), 0x00, ...content]);
