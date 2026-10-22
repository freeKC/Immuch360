// The phone's side of "Sign in with your phone": the hello to the big screen whose code the user scanned or typed,
// the check that it is that screen, and the sealed session sent to it.
//
// It talks to the address of the code only (a private IPv4 literal, pairing_protocol.dart), through a bare dart:io
// HttpClient: no proxy, no cookie, no custom header, no client certificate, no redirect, never the app's network
// stack, which would carry the user's cookie, headers and certificate to the screen. Nothing it sends or receives goes
// to the logs.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';

/// Why a step with the screen did not work
enum PairingFailure {
  /// No connection within the connect timeout, or refused: another network, a guest Wi-Fi, a firewall
  unreachable,

  /// The code is no longer the screen's (410 expired)
  expired,

  /// The code was used already (410 used)
  used,

  /// Too many phones on this code, or too many failures from this phone (429)
  throttled,

  /// The screen could not prove it knows the secret: a wrong typed code, or another device
  wrongCode,

  /// The screen refused the sealed message (400): its code is used up
  rejected,

  /// The screen is busy with another phone (409)
  busy,

  /// No answer the phone could trust in time
  lost,

  /// The screen answered something else than the protocol
  invalid,
}

class PairingException implements Exception {
  const PairingException(this.failure);
  final PairingFailure failure;

  @override
  String toString() => 'PairingException(${failure.name})';
}

/// What the screen tells of itself
class PairingScreenDevice {
  const PairingScreenDevice({required this.label, required this.kind, required this.os, required this.app});

  factory PairingScreenDevice.fromJson(Map<String, Object?> json) => PairingScreenDevice(
    label: _shortText(json['label']) ?? '',
    kind: PairingScreenKind.fromWire(json['kind']),
    os: _shortText(json['os']) ?? '',
    app: _shortText(json['app']) ?? '',
  );

  final String label;
  final PairingScreenKind kind;

  /// "Android", "Windows", "Linux" or "macOS"
  final String os;
  final String app;
}

String? _shortText(Object? value) {
  if (value is! String) {
    return null;
  }
  final text = cleanPairingText(value);
  return text.length > 64 ? text.substring(0, 64).trimRight() : text;
}

/// A hello the screen answered and proved: the channel of the rest of the pairing
class PairingHello {
  const PairingHello({required this.target, required this.channel, required this.device, required this.check});

  final PairingTarget target;
  final PairingChannel channel;
  final PairingScreenDevice device;

  /// The six digits the screen shows for this hello (pairingCheckNumber)
  final String check;

  @override
  String toString() => 'PairingHello(${target.mode.wire})';
}

/// What GET /p/info tells: the current code's id (not secret), null while the screen's codes are paused
class PairingScreenInfo {
  const PairingScreenInfo({required this.id, required this.device});
  final String? id;
  final PairingScreenDevice device;
}

/// Makes the bare HTTP client: the default one, outside any HttpOverrides of the app
HttpClient _bareClient() => HttpOverrides.runWithHttpOverrides(HttpClient.new, _NoOverrides());

class _NoOverrides extends HttpOverrides {}

/// See the top of this file
class PairingHttpClient {
  PairingHttpClient({
    HttpClient Function()? createClient,
    this.connectTimeout = const Duration(seconds: 5),
    this.answerTimeout = const Duration(seconds: 35),
    Random? random,
    @visibleForTesting Uri Function(String host, int port)? addressOf,
  }) : _createClient = createClient ?? _bareClient,
       _random = random ?? Random.secure(),
       _addressOf = addressOf ?? _address;

  final HttpClient Function() _createClient;

  /// Where a screen at a private IPv4 address is reached: there, except in the tests (the loopback)
  final Uri Function(String host, int port) _addressOf;

  static Uri _address(String host, int port) => Uri(scheme: 'http', host: host, port: port);
  final Duration connectTimeout;

  /// How long the phone waits for the screen to sign in and answer
  final Duration answerTimeout;
  final Random _random;

  static const _maxAnswer = 16 * 1024;

  /// The screen's code id and device, for a code typed with the address shown on the screen
  Future<PairingScreenInfo> info({required String host, required int port}) async {
    if (!isPrivatePairingIPv4(host)) {
      throw const PairingException(PairingFailure.invalid);
    }
    final answer = await _request('GET', _addressOf(host, port).replace(path: '/p/info'), null);
    if (answer.status != HttpStatus.ok) {
      throw PairingException(_failureOf(answer));
    }
    final device = answer.json['device'];
    final id = answer.json['id'];
    return PairingScreenInfo(
      id: id is String && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id) ? id : null,
      device: PairingScreenDevice.fromJson(device is Map<String, Object?> ? device : const {}),
    );
  }

  /// Says hello to the screen of [target] and checks its proof; throws [PairingException]
  Future<PairingHello> hello(PairingTarget target) async {
    if (!isPrivatePairingIPv4(target.host)) {
      throw const PairingException(PairingFailure.invalid);
    }
    final keyPair = PairingKeyPair.generate(_random);
    final answer = await _request('POST', _addressOf(target.host, target.port).replace(path: '/p/${target.id}/hello'), {
      'v': pairingProtocolVersion,
      'mode': target.mode.wire,
      'client': PairingClient.app.wire,
      'pk': pairingBase64(keyPair.publicKey),
    });
    if (answer.status != HttpStatus.ok) {
      throw PairingException(_failureOf(answer));
    }
    final screenKey = pairingDecodeBase64(answer.json['pk']);
    final deviceBytes = pairingDecodeBase64(answer.json['d']);
    final confirm = pairingDecodeBase64(answer.json['confirm']);
    if (screenKey == null || deviceBytes == null || confirm == null || deviceBytes.length > 1024) {
      throw const PairingException(PairingFailure.invalid);
    }
    final shared = keyPair.agree(screenKey);
    if (shared == null) {
      throw const PairingException(PairingFailure.invalid);
    }
    final transcript = pairingTranscript(
      id: target.id,
      mode: target.mode,
      client: PairingClient.app,
      phoneKey: keyPair.publicKey,
      screenKey: screenKey,
    );
    final keys = derivePairingKeys(shared: shared, secret: target.secretBytes, transcript: transcript);
    final expected = pairingConfirm(confirmKey: keys.confirm, transcript: transcript, device: deviceBytes);
    if (!pairingSameBytes(expected, confirm)) {
      throw const PairingException(PairingFailure.wrongCode);
    }
    final Object? device;
    try {
      device = jsonDecode(utf8.decode(deviceBytes));
    } on FormatException {
      throw const PairingException(PairingFailure.invalid);
    }
    if (device is! Map<String, Object?>) {
      throw const PairingException(PairingFailure.invalid);
    }
    return PairingHello(
      target: target,
      channel: PairingChannel(transcript: transcript, keys: keys, sends: PairingDirection.up, random: _random),
      device: PairingScreenDevice.fromJson(device),
      check: pairingCheckNumber(confirmKey: keys.confirm, transcript: transcript),
    );
  }

  /// Tells the screen of [hello] that its user cancelled, so that its panel no longer waits for this phone; sealed
  /// like a session, so that nobody else can send it. Best effort: throws [PairingException].
  Future<void> cancel(PairingHello hello) async {
    final answer = await _request(
      'POST',
      _addressOf(hello.target.host, hello.target.port).replace(path: '/p/${hello.target.id}/session'),
      hello.channel.seal({'v': pairingProtocolVersion, 'cancel': true}),
    );
    if (answer.status != HttpStatus.ok) {
      throw PairingException(_failureOf(answer));
    }
  }

  /// Seals [payload] for the screen of [hello] and gives its sealed answer, opened; [PairingFailure.lost] when no
  /// answer that opens comes within [answerTimeout]
  Future<Map<String, Object?>> send(PairingHello hello, Map<String, Object?> payload) async {
    final _Answer answer;
    try {
      answer = await _request(
        'POST',
        _addressOf(hello.target.host, hello.target.port).replace(path: '/p/${hello.target.id}/session'),
        hello.channel.seal({'v': pairingProtocolVersion, ...payload}),
        timeout: answerTimeout,
      );
    } on PairingException catch (error) {
      // Sent, maybe received: from here on, not knowing is losing
      throw PairingException(
        error.failure == PairingFailure.unreachable || error.failure == PairingFailure.invalid
            ? PairingFailure.lost
            : error.failure,
      );
    }
    if (answer.status != HttpStatus.ok) {
      final failure = _failureOf(answer);
      throw PairingException(failure == PairingFailure.invalid ? PairingFailure.lost : failure);
    }
    final opened = hello.channel.open(answer.json);
    if (opened == null || opened['v'] != pairingProtocolVersion) {
      throw const PairingException(PairingFailure.lost);
    }
    return opened;
  }

  static PairingFailure _failureOf(_Answer answer) => switch (answer.status) {
    HttpStatus.gone => answer.json['error'] == 'used' ? PairingFailure.used : PairingFailure.expired,
    HttpStatus.tooManyRequests => PairingFailure.throttled,
    HttpStatus.badRequest when answer.json['error'] == 'rejected' => PairingFailure.rejected,
    HttpStatus.conflict => PairingFailure.busy,
    _ => PairingFailure.invalid,
  };

  Future<_Answer> _request(String method, Uri uri, Map<String, Object?>? body, {Duration? timeout}) async {
    final client = _createClient()
      ..connectionTimeout = connectTimeout
      ..findProxy = ((_) => 'DIRECT')
      ..userAgent = 'Immuch360'
      ..autoUncompress = false;
    try {
      final HttpClientRequest request;
      try {
        request = await client.openUrl(method, uri).timeout(connectTimeout);
      } on TimeoutException {
        throw const PairingException(PairingFailure.unreachable);
      } on SocketException {
        throw const PairingException(PairingFailure.unreachable);
      }
      request
        ..followRedirects = false
        ..persistentConnection = false;
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(timeout ?? connectTimeout * 2);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout ?? connectTimeout * 2)) {
        bytes.add(chunk);
        if (bytes.length > _maxAnswer) {
          throw const PairingException(PairingFailure.invalid);
        }
      }
      Map<String, Object?> json = const {};
      try {
        final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
        if (decoded is Map<String, Object?>) {
          json = decoded;
        }
      } on FormatException {
        // An empty or other body: the status tells enough
      }
      return _Answer(response.statusCode, json);
    } on TimeoutException {
      throw const PairingException(PairingFailure.unreachable);
    } on SocketException {
      throw const PairingException(PairingFailure.unreachable);
    } on HttpException {
      throw const PairingException(PairingFailure.unreachable);
    } finally {
      client.close(force: true);
    }
  }
}

class _Answer {
  const _Answer(this.status, this.json);
  final int status;
  final Map<String, Object?> json;
}
