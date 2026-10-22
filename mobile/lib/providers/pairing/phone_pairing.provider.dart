// "Connect a TV or computer" on a phone: the scanner, the pairing service with the phone's own Immich session, and the
// list of the screens this phone signed in ("Connected by this phone"), kept in the Store without any token and
// brought in line with the sessions the server still has.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/pairing/phone_pairing.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_client.dart';
import 'package:immich_mobile/platform/qr_scan_api.g.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';

final _log = Logger('PhonePairing');

final qrScanApiProvider = Provider<QrScanApi>((_) => QrScanApi());

/// The address of a big screen ("192.168.1.23:8361") that came by an immuch360://pair link while the Connect page
/// shows: the page takes it from here, since the router does not open the page over itself
final pendingPairingLinkProvider = StateProvider<String?>((_) => null);

/// The address ("192.168.1.23:8361") of the screen an immuch360://pair link names, for the Connect page; null when it
/// names none, or when this device is a big screen ([isBigScreen]), which is signed in rather than signing in. The
/// link never makes the app talk to that address: the Connect page scans the code on the screen, or asks for it.
Future<String?> pairingLinkAddress(Uri uri, {required Future<bool> Function() isBigScreen}) async {
  final address = parsePairingLink(uri.toString());
  if (address == null || await isBigScreen()) {
    return null;
  }
  return '${address.host}:${address.port}';
}

/// The sessions of the phone's account through the app's API client (its cookie, headers and certificate)
class AppPairingSessions implements PairingSessions {
  const AppPairingSessions(this._api);

  final SessionsApi _api;

  @override
  Future<({String id, String token})> create({required String deviceType, required String deviceOS}) async {
    try {
      final created = await _api.createSession(
        SessionCreateDto(deviceType: Optional.present(deviceType), deviceOS: Optional.present(deviceOS)),
      );
      if (created == null) {
        throw const PairingSessionsException(PairingSessionsFailure.refused);
      }
      return (id: created.id, token: created.token);
    } on ApiException catch (error) {
      if (error.code == HttpStatus.notFound) {
        throw const PairingSessionsException(PairingSessionsFailure.serverTooOld);
      }
      // The client gives 400 with no code for a failure to connect
      throw PairingSessionsException(
        error.innerException is SocketException || error.innerException is http.ClientException
            ? PairingSessionsFailure.phoneOffline
            : PairingSessionsFailure.refused,
      );
    } on SocketException {
      throw const PairingSessionsException(PairingSessionsFailure.phoneOffline);
    } on TimeoutException {
      throw const PairingSessionsException(PairingSessionsFailure.phoneOffline);
    } on http.ClientException {
      throw const PairingSessionsException(PairingSessionsFailure.phoneOffline);
    }
  }

  @override
  Future<void> delete(String id) => _api.deleteSession(id);

  @override
  Future<List<({String id, DateTime? updatedAt})>> list() async => [
    for (final session in await _api.getSessions() ?? const <SessionResponseDto>[])
      (id: session.id, updatedAt: DateTime.tryParse(session.updatedAt)),
  ];
}

final pairingSessionsProvider = Provider<PairingSessions>(
  (ref) => AppPairingSessions(ref.watch(apiServiceProvider).sessionsApi),
);

final phonePairingServiceProvider = Provider<PhonePairingService>(
  (ref) => PhonePairingService(client: PairingHttpClient(), sessions: ref.watch(pairingSessionsProvider)),
);

/// What the phone hands over of its connection: the server, its addresses without duplicates, the custom headers
/// of the Networking settings, the account and the name of the phone
final phonePairingAccountProvider = Provider<Future<PhonePairingAccount> Function()>((ref) {
  return () async {
    final user = ref.read(currentUserProvider);
    final server = Store.tryGet(StoreKey.serverUrl);
    // The address the phone uses now first (at home the local one), the server's own address last, so that a screen
    // that cannot reach the first ones still finds the server
    final endpoints = <String>[
      ...{...ApiService.getServerUrls(), ?server},
    ];
    return PhonePairingAccount(
      server: server ?? endpoints.firstOrNull ?? '',
      endpoints: endpoints,
      headers: ApiService.getRequestHeaders(),
      userName: user?.name ?? '',
      userEmail: user?.email ?? '',
      phoneName: await phoneShareDeviceName(),
    );
  };
});

/// A screen this phone signed in: its session on the server, never its token
class PairedScreen {
  const PairedScreen({
    required this.sessionId,
    required this.label,
    required this.kind,
    required this.os,
    required this.at,
    this.lastSeen,
  });

  final String sessionId;
  final String label;
  final PairingScreenKind kind;
  final String os;

  /// When the phone signed it in
  final DateTime at;

  /// When the server last saw its session, after a refresh
  final DateTime? lastSeen;

  Map<String, Object> toJson() => {
    'sessionId': sessionId,
    'label': label,
    'kind': kind.wire,
    'os': os,
    'at': at.toUtc().toIso8601String(),
  };

  static PairedScreen? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final sessionId = json['sessionId'];
    final label = json['label'];
    final at = DateTime.tryParse('${json['at']}');
    if (sessionId is! String || label is! String || at == null) {
      return null;
    }
    return PairedScreen(
      sessionId: sessionId,
      label: label,
      kind: PairingScreenKind.fromWire(json['kind']),
      os: json['os'] is String ? json['os'] as String : '',
      at: at,
    );
  }

  PairedScreen withLastSeen(DateTime? lastSeen) =>
      PairedScreen(sessionId: sessionId, label: label, kind: kind, os: os, at: at, lastSeen: lastSeen);
}

/// "Connected by this phone": the list of StoreKey.pairedScreens, the latest first
class PairedScreensNotifier extends Notifier<List<PairedScreen>> {
  /// The screens a phone keeps in its list
  static const maxScreens = 32;

  @override
  List<PairedScreen> build() {
    final stored = Store.tryGet(StoreKey.pairedScreens);
    if (stored == null) {
      return const [];
    }
    try {
      final decoded = jsonDecode(stored);
      return [
        if (decoded is List)
          for (final entry in decoded) ?PairedScreen.fromJson(entry),
      ];
    } on FormatException {
      return const [];
    }
  }

  Future<void> _save(List<PairedScreen> screens) async {
    state = screens;
    await Store.put(StoreKey.pairedScreens, jsonEncode([for (final screen in screens) screen.toJson()]));
  }

  Future<void> add(PairedScreen screen) =>
      _save([screen, ...state.where((other) => other.sessionId != screen.sessionId)].take(maxScreens).toList());

  Future<void> remove(String sessionId) => _save(state.where((screen) => screen.sessionId != sessionId).toList());

  /// Drops the screens whose session the server no longer has (signed out on the web, from the screen, by the
  /// cascade), and tells when the others were last seen
  Future<void> refresh() async {
    if (state.isEmpty) {
      return;
    }
    try {
      final sessions = {
        for (final session in await ref.read(pairingSessionsProvider).list()) session.id: session.updatedAt,
      };
      await _save([
        for (final screen in state)
          if (sessions.containsKey(screen.sessionId)) screen.withLastSeen(sessions[screen.sessionId]),
      ]);
    } catch (error) {
      _log.fine('The sessions of the server are not known: ${error.runtimeType}');
    }
  }

  /// Signs [screen] out of the server, then out of the list
  Future<void> signOut(PairedScreen screen) async {
    await ref.read(phonePairingServiceProvider).signOut(screen.sessionId);
    await remove(screen.sessionId);
  }
}

final pairedScreensProvider = NotifierProvider<PairedScreensNotifier, List<PairedScreen>>(PairedScreensNotifier.new);
