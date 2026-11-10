// The phone's side of "Play on the TV": the connection to the listener of a linked screen, its proofs, and the sealed
// commands (play_link_protocol.dart). Like the pairing client it talks to a private IPv4 literal only, through a bare
// dart:io HttpClient (no proxy, cookie, custom header, client certificate nor redirect). Nothing it sends or
// receives goes to the logs.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';

/// Why a step with the screen did not work
enum PlayLinkFailure {
  /// No connection: the screen is off, Immuch360 is not open on it, another network
  unreachable,

  /// The screen does not know this phone any more (removed there), or another device answered
  notLinked,

  /// The screen answered something else than the protocol, or nothing that opens
  invalid,
}

class PlayLinkException implements Exception {
  const PlayLinkException(this.failure);
  final PlayLinkFailure failure;

  @override
  String toString() => 'PlayLinkException(${failure.name})';
}

HttpClient _bareClient() => HttpOverrides.runWithHttpOverrides(HttpClient.new, _NoOverrides());

class _NoOverrides extends HttpOverrides {}

/// An open session with a screen
class PlayLinkConnection {
  PlayLinkConnection._(this._client, this.screen, this._base, this._channel);

  final PlayLinkClient _client;
  final LinkedPeer screen;
  final Uri _base;
  PlayLinkChannel _channel;

  /// The address the session talks to
  String get address => '${_base.host}:${_base.port}';

  /// Sends [message] sealed and gives the sealed answer, opened. A session the screen no longer has (it restarted) is
  /// opened again once.
  Future<Map<String, Object?>> send(Map<String, Object?> message, {Duration? timeout}) async {
    for (var attempt = 0; ; attempt++) {
      final channel = _channel;
      final answer = await _client._request(
        'POST',
        _base.replace(path: '/v1/cmd'),
        channel.seal(message),
        timeout: timeout,
      );
      if (answer.status == HttpStatus.gone && attempt == 0) {
        _channel = await _client._open(_base, screen);
        continue;
      }
      if (answer.status != HttpStatus.ok) {
        throw const PlayLinkException(PlayLinkFailure.invalid);
      }
      final opened = channel.open(answer.json);
      if (opened == null) {
        throw const PlayLinkException(PlayLinkFailure.invalid);
      }
      return opened;
    }
  }

  /// The state of the screen once it is past [after], waiting [wait] at most for a change
  Future<ScreenPlayState> status({int after = -1, Duration wait = Duration.zero}) async {
    final answer = await send({
      'type': 'status',
      'after': after,
      'waitMs': wait.inMilliseconds,
    }, timeout: wait + _client.answerTimeout);
    return ScreenPlayState.fromJson(answer['state']);
  }

  /// Sends [command] ({type, ...}) and gives the status word and the state after it
  Future<({String status, ScreenPlayState state})> command(Map<String, Object?> command, {Duration? timeout}) async {
    final answer = await send(command, timeout: timeout);
    final status = answer['status'];
    return (status: status is String ? status : 'failed', state: ScreenPlayState.fromJson(answer['state']));
  }

  /// Ends the session; never throws
  Future<void> close() async {
    try {
      await send({'type': 'bye'}, timeout: const Duration(seconds: 2));
    } catch (_) {
      // The screen forgets it after a while anyway
    }
  }
}

/// See the top of this file
class PlayLinkClient {
  PlayLinkClient({
    required this.phoneId,
    HttpClient Function()? createClient,
    this.connectTimeout = const Duration(seconds: 4),
    this.answerTimeout = const Duration(seconds: 15),
    Random? random,
    @visibleForTesting Uri Function(String host, int port)? addressOf,
  }) : _createClient = createClient ?? _bareClient,
       _random = random ?? Random.secure(),
       _addressOf = addressOf ?? ((host, port) => Uri(scheme: 'http', host: host, port: port));

  /// This phone's install id
  final String phoneId;
  final HttpClient Function() _createClient;
  final Random _random;
  final Uri Function(String host, int port) _addressOf;
  final Duration connectTimeout;
  final Duration answerTimeout;

  static const _maxAnswer = 64 * 1024;

  /// Opens a session with [screen] at [host]:[port]: its nonce, this phone's proof, the screen's proof. Throws
  /// [PlayLinkException].
  Future<PlayLinkConnection> connect({required String host, required int port, required LinkedPeer screen}) async {
    if (!isPrivatePairingIPv4(host)) {
      throw const PlayLinkException(PlayLinkFailure.invalid);
    }
    final base = _addressOf(host, port);
    final channel = await _open(base, screen);
    return PlayLinkConnection._(this, screen, base, channel);
  }

  Future<PlayLinkChannel> _open(Uri base, LinkedPeer screen) async {
    final hello = await _request('GET', base.replace(path: '/v1/hello'), null);
    final screenNonce = pairingDecodeBase64(hello.json['n']);
    if (hello.status != HttpStatus.ok || screenNonce == null || screenNonce.length != playLinkNonceBytes) {
      throw const PlayLinkException(PlayLinkFailure.invalid);
    }
    // Another screen at that address: nothing of this link goes to it
    if (hello.json['id'] != screen.id) {
      throw const PlayLinkException(PlayLinkFailure.notLinked);
    }
    final phoneNonce = pairingRandomBytes(playLinkNonceBytes, _random);
    final transcript = playLinkTranscript(
      screenId: screen.id,
      phoneId: phoneId,
      screenNonce: screenNonce,
      phoneNonce: phoneNonce,
    );
    final opened = await _request('POST', base.replace(path: '/v1/open'), {
      'v': playLinkProtocolVersion,
      'phone': phoneId,
      'ns': pairingBase64(screenNonce),
      'np': pairingBase64(phoneNonce),
      'proof': pairingBase64(playLinkProof(key: screen.key, role: PlayLinkRole.phone, transcript: transcript)),
    });
    if (opened.status == HttpStatus.forbidden) {
      throw const PlayLinkException(PlayLinkFailure.notLinked);
    }
    final proof = pairingDecodeBase64(opened.json['proof']);
    final expected = playLinkProof(key: screen.key, role: PlayLinkRole.screen, transcript: transcript);
    if (opened.status != HttpStatus.ok || proof == null || !pairingSameBytes(proof, expected)) {
      throw const PlayLinkException(PlayLinkFailure.notLinked);
    }
    final channel = PlayLinkChannel(
      transcript: transcript,
      keys: derivePlayLinkKeys(key: screen.key, transcript: transcript),
      sends: PairingDirection.up,
    );
    if (opened.json['s'] != channel.handle) {
      throw const PlayLinkException(PlayLinkFailure.invalid);
    }
    return channel;
  }

  Future<_Answer> _request(String method, Uri uri, Map<String, Object?>? body, {Duration? timeout}) async {
    final client = _createClient()
      ..connectionTimeout = connectTimeout
      ..findProxy = ((_) => 'DIRECT')
      ..userAgent = 'Immuch360'
      ..autoUncompress = false;
    final wait = timeout ?? answerTimeout;
    try {
      final HttpClientRequest request;
      try {
        request = await client.openUrl(method, uri).timeout(connectTimeout);
      } on TimeoutException {
        throw const PlayLinkException(PlayLinkFailure.unreachable);
      } on SocketException {
        throw const PlayLinkException(PlayLinkFailure.unreachable);
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
      final response = await request.close().timeout(wait);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(wait)) {
        bytes.add(chunk);
        if (bytes.length > _maxAnswer) {
          throw const PlayLinkException(PlayLinkFailure.invalid);
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
      throw const PlayLinkException(PlayLinkFailure.unreachable);
    } on SocketException {
      throw const PlayLinkException(PlayLinkFailure.unreachable);
    } on HttpException {
      throw const PlayLinkException(PlayLinkFailure.unreachable);
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

/// The phone's side of "Add (server) to (screen)", inside [connection]: the fresh hello, then the check number for
/// the user, then the server and its token sealed under the keys of that hello
class PhoneHandover {
  PhoneHandover._(this._connection, this._handover);

  final PlayLinkConnection _connection;
  final PlayHandover _handover;

  /// The six digits the screen shows too
  String get check => _handover.check;

  /// Starts the handover of [serverName]: the screen shows its question with the check number. Throws
  /// [PlayLinkException]; [PlayLinkFailure.invalid] also when the screen is busy with another one.
  static Future<PhoneHandover> start(
    PlayLinkConnection connection, {
    required String serverName,
    Random? random,
  }) async {
    final own = PairingKeyPair.generate(random);
    final answer = await connection.send({
      'type': 'handoverHello',
      'pk': pairingBase64(own.publicKey),
      'serverName': serverName,
    });
    final screenKey = pairingDecodeBase64(answer['pk']);
    if (answer['status'] != 'ok' || screenKey == null) {
      throw const PlayLinkException(PlayLinkFailure.invalid);
    }
    final handover = PlayHandover.of(own: own, peerKey: screenKey, isPhone: true, session: connection._channel);
    if (handover == null) {
      throw const PlayLinkException(PlayLinkFailure.invalid);
    }
    return PhoneHandover._(connection, handover);
  }

  /// The user of the phone accepted: [server] and [token] go, and the answer comes once the user of the screen
  /// answered and the screen checked the server
  Future<HandoverResult> send(HandedPlexServer server, String token) async {
    final answer = await _connection.send({
      'type': 'handoverServer',
      'h': _handover.channel(isPhone: true).seal({'server': server.toJson(), 'token': token}),
    }, timeout: ScreenPlayerSession.handoverLifetime + const Duration(seconds: 30));
    return HandoverResult.fromWire(answer['status']);
  }
}
