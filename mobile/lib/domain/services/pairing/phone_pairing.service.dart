// The phone's side of "Sign in with your phone", from a checked hello to the end: a new Immich session for the big
// screen, named after it ("Immuch360 on Living room TV"), sealed and sent to the screen, kept only when the screen
// answers, with the pairing key, that it signed in. On any other outcome (the screen cannot reach the server, it
// refused the token, no trusted answer within the timeout) the session is deleted at once: no orphan token.
//
// The session is a child of the phone's own (POST /sessions): it is listed and revocable in the Immich web app
// (Account settings, Authorized devices), and goes with the phone's session when that one ends.

import 'dart:async';

import 'package:immich_mobile/domain/services/pairing/big_screen_headers.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_client.dart';
import 'package:logging/logging.dart';

final _log = Logger('PhonePairing');

/// The sessions of the phone's account on its Immich server
abstract interface class PairingSessions {
  /// A new child session of the phone's: its id and token; throws [PairingSessionsException]
  Future<({String id, String token})> create({required String deviceType, required String deviceOS});
  Future<void> delete(String id);

  /// Every session of the account: id, and when it was last used
  Future<List<({String id, DateTime? updatedAt})>> list();
}

enum PairingSessionsFailure {
  /// The server has no POST /sessions (404): older than v1.133
  serverTooOld,

  /// The phone could not reach its own server
  phoneOffline,

  /// Anything else the server answered
  refused,
}

class PairingSessionsException implements Exception {
  const PairingSessionsException(this.failure);
  final PairingSessionsFailure failure;

  @override
  String toString() => 'PairingSessionsException(${failure.name})';
}

/// What the phone hands over of its connection to the server
class PhonePairingAccount {
  const PhonePairingAccount({
    required this.server,
    required this.endpoints,
    required this.headers,
    required this.userName,
    required this.userEmail,
    required this.phoneName,
  });

  /// Store.serverUrl
  final String server;

  /// The server endpoint, the local endpoint, then the external ones, without duplicates
  final List<String> endpoints;

  /// The custom headers of the Networking settings
  final Map<String, String> headers;
  final String userName;
  final String userEmail;
  final String phoneName;
}

/// How a pairing ended, for the phone's page
enum PhonePairingStatus {
  signedIn,

  /// The screen could not reach the server at any address it was given
  serverUnreachable,

  /// The screen reached the server, which refused the token
  tokenRejected,

  /// The screen is busy with another phone
  busy,

  /// No trusted answer: nothing was kept
  lost,

  /// The screen refused the message: its code was used up meanwhile
  rejected,

  /// The code expired meanwhile
  expired,

  /// Another phone used the code meanwhile: the screen is signed in
  used,

  serverTooOld,
  phoneOffline,
  refused,
}

class PhonePairingResult {
  const PhonePairingResult({required this.status, this.sessionId, this.label, this.triedAddresses});

  final PhonePairingStatus status;

  /// The session kept for the screen, when signed in
  final String? sessionId;
  final String? label;

  /// For [PhonePairingStatus.serverUnreachable]: how many addresses the screen tried
  final int? triedAddresses;

  bool get signedIn => status == PhonePairingStatus.signedIn;

  @override
  String toString() => 'PhonePairingResult(${status.name})';
}

/// The deviceOS the web app has an icon for, from what the screen said
String pairingSessionOs(PairingScreenDevice device) => switch (device.os) {
  'Windows' || 'Linux' || 'macOS' || 'Android' => device.os,
  _ => device.kind == PairingScreenKind.computer ? 'Linux' : 'Android',
};

const maxLabelLength = 40;

/// The name the user may give a screen: one line, at most [maxLabelLength] characters, no control nor format
/// character; null when nothing is left
String? cleanPairingLabel(String typed) {
  final label = cleanPairingText(typed);
  if (label.isEmpty) {
    return null;
  }
  return label.length > maxLabelLength ? label.substring(0, maxLabelLength).trimRight() : label;
}

/// See the top of this file
class PhonePairingService {
  PhonePairingService({required this._client, required this._sessions, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final PairingHttpClient _client;
  final PairingSessions _sessions;
  final DateTime Function() _clock;

  /// Says hello to the screen of [target]; throws [PairingException]
  Future<PairingHello> hello(PairingTarget target) => _client.hello(target);

  /// The id of the code a screen shows now, for a code typed with the address on the screen
  Future<PairingScreenInfo> info({required String host, required int port}) => _client.info(host: host, port: port);

  /// Tells the screen of [hello] that the user cancelled; never throws
  Future<void> cancel(PairingHello hello) async {
    try {
      await _client.cancel(hello);
    } catch (error) {
      _log.fine('Pairing: the screen did not hear the cancel: ${error.runtimeType}');
    }
  }

  /// Signs the screen of [hello] in as [label] with a new session of [account], with its custom headers when
  /// [sendHeaders]. [onSession] hears of the session before it leaves the phone, so that a session the phone never
  /// hears back about (the app killed meanwhile) is still listed, and can be signed out.
  Future<PhonePairingResult> signIn(
    PairingHello hello, {
    required String label,
    required PhonePairingAccount account,
    bool sendHeaders = true,
    Future<void> Function(String sessionId, String label)? onSession,
  }) async {
    final name = cleanPairingLabel(label) ?? cleanPairingLabel(hello.device.label) ?? 'TV';
    final ({String id, String token}) session;
    try {
      session = await _sessions.create(deviceType: pairingSessionName(name), deviceOS: pairingSessionOs(hello.device));
    } on PairingSessionsException catch (error) {
      _log.info('Pairing: no session for the screen (${error.failure.name})');
      return PhonePairingResult(
        status: switch (error.failure) {
          PairingSessionsFailure.serverTooOld => PhonePairingStatus.serverTooOld,
          PairingSessionsFailure.phoneOffline => PhonePairingStatus.phoneOffline,
          PairingSessionsFailure.refused => PhonePairingStatus.refused,
        },
      );
    }

    Map<String, Object?> answer;
    try {
      await onSession?.call(session.id, name);
      answer = await _client.send(hello, {
        'server': account.server,
        'endpoints': account.endpoints,
        if (sendHeaders && account.headers.isNotEmpty) 'headers': account.headers,
        'token': session.token,
        'sessionId': session.id,
        'label': name,
        'user': {'name': account.userName, 'email': account.userEmail},
        'phone': account.phoneName,
        'issuedAt': _clock().toUtc().toIso8601String(),
      });
    } catch (error) {
      await _forget(session.id);
      if (error is! PairingException) {
        _log.warning('Pairing: the session could not go to the screen: ${error.runtimeType}, it is deleted');
        return const PhonePairingResult(status: PhonePairingStatus.lost);
      }
      _log.info('Pairing: the screen did not sign in (${error.failure.name}), its session is deleted');
      return PhonePairingResult(
        status: switch (error.failure) {
          PairingFailure.busy => PhonePairingStatus.busy,
          PairingFailure.rejected => PhonePairingStatus.rejected,
          PairingFailure.expired => PhonePairingStatus.expired,
          PairingFailure.used => PhonePairingStatus.used,
          _ => PhonePairingStatus.lost,
        },
      );
    }

    final status = switch (answer['status']) {
      'signedIn' => PhonePairingStatus.signedIn,
      'serverUnreachable' => PhonePairingStatus.serverUnreachable,
      'tokenRejected' => PhonePairingStatus.tokenRejected,
      'busy' => PhonePairingStatus.busy,
      _ => PhonePairingStatus.lost,
    };
    if (status != PhonePairingStatus.signedIn) {
      await _forget(session.id);
      _log.info('Pairing: the screen answered ${status.name}, its session is deleted');
      final tried = answer['tried'];
      return PhonePairingResult(status: status, triedAddresses: tried is int ? tried : null);
    }
    _log.info('Pairing: the screen signed in');
    return PhonePairingResult(status: status, sessionId: session.id, label: name);
  }

  /// Signs a screen this phone connected out of the server
  Future<void> signOut(String sessionId) => _sessions.delete(sessionId);

  Future<void> _forget(String sessionId) async {
    try {
      await _sessions.delete(sessionId);
    } catch (error) {
      // Its token went nowhere the phone trusts; the user still sees it in Authorized devices
      _log.warning('Pairing: the session made for the screen could not be deleted: ${error.runtimeType}');
    }
  }
}
