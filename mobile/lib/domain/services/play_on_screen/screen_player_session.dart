// The screen's side of "Play on the TV", without any network: the nonces it gives, the sessions of the linked phones
// it opens, the commands it opens and hands to the player, the state it tells back, and the token handover. The
// listener (play_link_server.dart) hands it what arrives and sends back what it answers.
//
// Rules:
// - only a phone of the linked list, proven with its link key over a nonce of the screen used once within
//   [nonceLifetime], opens a session; the screen proves itself back;
// - at most [maxSessions] sessions, the least recently used one goes first; a session unused for [sessionIdle] ends;
// - every command is sealed with a counter (PlayLinkChannel): a replayed one does not open;
// - a phone removed from the list loses its sessions at once;
// - a token arrives only through a handover: a fresh P-256 hello inside the session, whose check number the screen
//   shows with Accept and Not now, and the phone shows with its warning; the token opens only once both accepted.
//
// Nothing here goes to the logs: never a key, a nonce, a title, a token.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';

/// A phone linked to this screen, or a screen linked to this phone
class LinkedPeer {
  const LinkedPeer({
    required this.id,
    required this.name,
    required this.key,
    required this.linkedAt,
    this.kind = PairingScreenKind.tv,
  });

  /// Its install id (isPlayLinkId)
  final String id;
  final String name;

  /// The link key, [playLinkKeyBytes] bytes; secret, never logged
  final Uint8List key;
  final DateTime linkedAt;

  /// The kind of screen (on the phone's list), tv on the screen's list of phones
  final PairingScreenKind kind;

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'key': pairingBase64(key),
    'at': linkedAt.toUtc().toIso8601String(),
    'kind': kind.wire,
  };

  static LinkedPeer? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final id = json['id'];
    final name = json['name'];
    final key = pairingDecodeBase64(json['key']);
    final at = DateTime.tryParse('${json['at']}');
    if (!isPlayLinkId(id) || name is! String || key == null || key.length != playLinkKeyBytes || at == null) {
      return null;
    }
    return LinkedPeer(
      id: id as String,
      name: name,
      key: key,
      linkedAt: at,
      kind: PairingScreenKind.fromWire(json['kind']),
    );
  }

  LinkedPeer renamed(String name) => LinkedPeer(id: id, name: name, key: key, linkedAt: linkedAt, kind: kind);

  @override
  String toString() => 'LinkedPeer(${kind.wire})';
}

/// How a token handover ended on the screen
enum HandoverResult {
  added('added'),

  /// The user of the screen said Not now, or did not answer in time
  declined('declined'),

  /// The server refused the token
  tokenRefused('tokenRefused'),

  /// The server could not be reached from the screen
  unreachable('unreachable'),

  /// The address answers with another server or another certificate
  otherServer('otherServer'),
  failed('failed');

  const HandoverResult(this.wire);
  final String wire;

  static HandoverResult fromWire(Object? value) =>
      HandoverResult.values.where((result) => result.wire == value).firstOrNull ?? HandoverResult.failed;
}

/// What the screen's player does with the commands, replaced by a fake in the tests
abstract interface class ScreenPlayerActions {
  ScreenPlayState get state;

  /// Every change of [state]
  Stream<ScreenPlayState> get states;

  /// Opens [item] for [from]; returns once it was declined, failed or started to open (the state tells which)
  Future<void> play(PlayItem item, LinkedPeer from);
  Future<void> pause();
  Future<void> resume();
  Future<void> seek(int positionMs);

  /// Chooses the track [id] of [kind]; null turns the subtitles off
  Future<void> track(PlayTrackKind kind, String? id);
  Future<void> stop();

  /// Shows "Add (server) from (phone)?" with [check]; true once its user accepted, false on Not now. Ends with false
  /// when [cancel] completes first.
  Future<bool> askHandover({
    required LinkedPeer from,
    required String server,
    required String check,
    required Future<void> cancel,
  });

  /// Checks [server] with [token] (pinning, identity, libraries) and keeps it as a Plex source of this screen
  Future<HandoverResult> addServer(HandedPlexServer server, String token);
}

/// An answer of the listener: an HTTP status and its JSON body
typedef PlayLinkAnswer = ({int status, Map<String, Object?> body});

class _Session {
  _Session(this.phone, this.channel, this.lastUsed);

  final LinkedPeer phone;
  final PlayLinkChannel channel;
  DateTime lastUsed;
  _PendingHandover? handover;
}

class _PendingHandover {
  _PendingHandover(this.handover, this.accepted, this.cancel, this.at);

  final PlayHandover handover;
  final Future<bool> accepted;
  final Completer<void> cancel;
  final DateTime at;
  bool done = false;
}

/// See the top of this file
class ScreenPlayerSession {
  ScreenPlayerSession({
    required this.screenId,
    required this._phones,
    required this._actions,
    DateTime Function()? clock,
    Random? random,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  static const nonceLifetime = Duration(seconds: 30);
  static const maxNonces = 16;
  static const maxSessions = 8;
  static const sessionIdle = Duration(minutes: 15);

  /// The longest a status request waits for a change
  static const maxWait = Duration(seconds: 25);

  /// The longest a handover waits for the user of the screen
  static const handoverLifetime = Duration(minutes: 2);

  final String screenId;
  final List<LinkedPeer> Function() _phones;
  final ScreenPlayerActions _actions;
  final DateTime Function() _clock;
  final Random _random;

  final Map<String, DateTime> _nonces = {};
  final Map<String, _Session> _sessions = {};

  int get sessionCount => _sessions.length;

  static PlayLinkAnswer _error(int status, String error) =>
      (status: status, body: {'v': playLinkProtocolVersion, 'error': error});

  void _expire() {
    final now = _clock();
    _nonces.removeWhere((_, at) => now.difference(at) >= nonceLifetime);
    final idle = [
      for (final MapEntry(:key, :value) in _sessions.entries)
        if (now.difference(value.lastUsed) >= sessionIdle) key,
    ];
    idle.forEach(_end);
  }

  void _end(String handle) {
    final session = _sessions.remove(handle);
    final pending = session?.handover;
    if (pending != null && !pending.cancel.isCompleted) {
      pending.cancel.complete();
    }
  }

  /// GET /v1/hello
  PlayLinkAnswer hello() {
    _expire();
    if (_nonces.length >= maxNonces) {
      // The oldest goes (the map keeps the order they were given in): a device that only asks for nonces cannot keep
      // a phone out
      _nonces.remove(_nonces.keys.first);
    }
    final nonce = pairingBase64(pairingRandomBytes(playLinkNonceBytes, _random));
    _nonces[nonce] = _clock();
    return (status: 200, body: {'v': playLinkProtocolVersion, 'id': screenId, 'n': nonce});
  }

  /// POST /v1/open: 403 for anything that is not a linked phone's proof over a live nonce, which is used up either way
  PlayLinkAnswer open(Map<String, Object?> body) {
    _expire();
    final phoneId = body['phone'];
    final screenNonceText = body['ns'];
    final screenNonce = pairingDecodeBase64(screenNonceText);
    final phoneNonce = pairingDecodeBase64(body['np']);
    final proof = pairingDecodeBase64(body['proof']);
    if (!isPlayLinkId(phoneId) ||
        screenNonce == null ||
        screenNonce.length != playLinkNonceBytes ||
        phoneNonce == null ||
        phoneNonce.length != playLinkNonceBytes ||
        proof == null) {
      return _error(400, 'invalid');
    }
    // Used once, whatever comes next
    if (_nonces.remove(screenNonceText) == null) {
      return _error(403, 'nonce');
    }
    final phone = _phones().where((peer) => peer.id == phoneId).firstOrNull;
    if (phone == null) {
      return _error(403, 'unknown');
    }
    final transcript = playLinkTranscript(
      screenId: screenId,
      phoneId: phone.id,
      screenNonce: screenNonce,
      phoneNonce: phoneNonce,
    );
    final expected = playLinkProof(key: phone.key, role: PlayLinkRole.phone, transcript: transcript);
    if (!pairingSameBytes(expected, proof)) {
      return _error(403, 'proof');
    }
    final channel = PlayLinkChannel(
      transcript: transcript,
      keys: derivePlayLinkKeys(key: phone.key, transcript: transcript),
      sends: PairingDirection.down,
    );
    if (_sessions.length >= maxSessions) {
      // The least recently used one, the first opened of those used at the same time
      final oldest = _sessions.entries.reduce((a, b) => b.value.lastUsed.isBefore(a.value.lastUsed) ? b : a).key;
      _end(oldest);
    }
    _sessions[channel.handle] = _Session(phone, channel, _clock());
    return (
      status: 200,
      body: {
        'v': playLinkProtocolVersion,
        's': channel.handle,
        'proof': pairingBase64(playLinkProof(key: phone.key, role: PlayLinkRole.screen, transcript: transcript)),
      },
    );
  }

  /// The sessions of [phoneId] end: it was removed from the list
  void forgetPhone(String phoneId) {
    final handles = [
      for (final MapEntry(:key, :value) in _sessions.entries)
        if (value.phone.id == phoneId) key,
    ];
    handles.forEach(_end);
  }

  /// Every session ends
  void close() => [..._sessions.keys].forEach(_end);

  /// POST /v1/cmd: 410 for a session the screen no longer has (the phone opens a new one), 400 for an envelope that
  /// does not open; else the sealed answer
  Future<PlayLinkAnswer> command(Map<String, Object?> envelope) async {
    _expire();
    final session = _sessions[envelope['s']];
    if (session == null) {
      return _error(410, 'session');
    }
    // A phone removed meanwhile
    if (!_phones().any((peer) => peer.id == session.phone.id)) {
      _end(session.channel.handle);
      return _error(410, 'session');
    }
    final message = session.channel.open(envelope);
    if (message == null) {
      return _error(400, 'sealed');
    }
    session.lastUsed = _clock();
    // The answer goes under the keys of the session before it ends, so that the phone does not open a new one to say
    // goodbye again
    if (message['type'] == 'bye') {
      final body = session.channel.seal({'status': 'ok'});
      _end(session.channel.handle);
      return (status: 200, body: body);
    }
    final answer = await _handle(session, message);
    // Gone while it waited: nothing goes back under its keys
    if (!identical(_sessions[session.channel.handle], session)) {
      return _error(410, 'session');
    }
    session.lastUsed = _clock();
    return (status: 200, body: session.channel.seal(answer));
  }

  Map<String, Object?> _withState(String status) => {'status': status, 'state': _actions.state.toJson()};

  Future<Map<String, Object?>> _handle(_Session session, Map<String, Object?> message) async {
    switch (message['type']) {
      case 'status':
        final after = message['after'];
        final wait = message['waitMs'];
        await _waitAfter(
          after is int ? after : -1,
          wait is int && wait > 0 ? Duration(milliseconds: min(wait, maxWait.inMilliseconds)) : Duration.zero,
        );
        return _withState('ok');
      case 'play':
        final item = PlayItem.fromJson(message);
        if (item == null) {
          return _withState('invalid');
        }
        await _actions.play(item, session.phone);
        return _withState('ok');
      case 'pause':
        await _actions.pause();
        return _withState('ok');
      case 'resume':
        await _actions.resume();
        return _withState('ok');
      case 'seek':
        final position = message['positionMs'];
        if (position is! int || position < 0) {
          return _withState('invalid');
        }
        await _actions.seek(position);
        return _withState('ok');
      case 'track':
        final kind = PlayTrackKind.fromWire(message['kind']);
        final id = message['id'];
        if (kind == null ||
            (id != null && (id is! String || id.length > 64)) ||
            (id == null && kind != PlayTrackKind.subtitle)) {
          return _withState('invalid');
        }
        await _actions.track(kind, id as String?);
        return _withState('ok');
      case 'stop':
        await _actions.stop();
        return _withState('ok');
      case 'handoverHello':
        return _handoverHello(session, message);
      case 'handoverServer':
        return _handoverServer(session, message);
      default:
        return {'status': 'unknown'};
    }
  }

  /// Waits until the state is past [after], [wait] at most
  Future<void> _waitAfter(int after, Duration wait) async {
    if (_actions.state.seq > after || wait == Duration.zero) {
      return;
    }
    // A subscription of its own, cancelled at the end of the wait: a long poll every 25 s of an idle screen leaves
    // nothing behind
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) {
        done.complete();
      }
    }

    final subscription = _actions.states.listen(
      (state) {
        if (state.seq > after) {
          finish();
        }
      },
      onDone: finish,
      onError: (Object _) => finish(),
    );
    final timer = Timer(wait, finish);
    await done.future;
    timer.cancel();
    await subscription.cancel();
  }

  Map<String, Object?> _handoverHello(_Session session, Map<String, Object?> message) {
    final phoneKey = pairingDecodeBase64(message['pk']);
    final server = message['serverName'];
    if (phoneKey == null || phoneKey.length != 33 || server is! String) {
      return {'status': 'invalid'};
    }
    final previous = session.handover;
    if (previous != null && !previous.done && _clock().difference(previous.at) < handoverLifetime) {
      return {'status': 'busy'};
    }
    if (previous != null && !previous.cancel.isCompleted) {
      previous.cancel.complete();
    }
    final own = PairingKeyPair.generate(_random);
    final handover = PlayHandover.of(own: own, peerKey: phoneKey, isPhone: false, session: session.channel);
    if (handover == null) {
      return {'status': 'invalid'};
    }
    final cancel = Completer<void>();
    final name = cleanPairingText(server);
    final accepted = _actions
        .askHandover(
          from: session.phone,
          server: name.length > 64 ? name.substring(0, 64) : name,
          check: handover.check,
          cancel: Future.any([cancel.future, Future<void>.delayed(handoverLifetime)]),
        )
        .catchError((Object _) => false);
    session.handover = _PendingHandover(handover, accepted, cancel, _clock());
    return {'status': 'ok', 'pk': pairingBase64(own.publicKey)};
  }

  Future<Map<String, Object?>> _handoverServer(_Session session, Map<String, Object?> message) async {
    final pending = session.handover;
    final inner = message['h'];
    if (pending == null || pending.done || inner is! Map<String, Object?>) {
      return {'status': HandoverResult.failed.wire};
    }
    pending.done = true;
    // The token opens only once the user of the screen accepted
    final accepted = await pending.accepted.timeout(handoverLifetime, onTimeout: () => false);
    if (!accepted) {
      return {'status': HandoverResult.declined.wire};
    }
    final opened = pending.handover.channel(isPhone: false).open(inner);
    final server = HandedPlexServer.fromJson(opened?['server']);
    final token = opened?['token'];
    if (opened == null || server == null || token is! String || token.length < 8 || token.length > 4096) {
      return {'status': HandoverResult.failed.wire};
    }
    final result = await _actions.addServer(server, token).catchError((Object _) => HandoverResult.failed);
    return {'status': result.wire};
  }
}
