// A big screen that a phone signed in loses its session when the phone signs it out, when Immich does (Account
// settings, Authorized devices), or when the phone stopped waiting for the screen's answer and deleted the session.
// The server refuses the token at once, but a running screen keeps showing what it has: this check, a while after a
// pairing and each time the app comes back to the front, brings it back to its sign-in page, as the guard of the
// routes does on the next page it opens (routing/auth_guard.dart).

import 'dart:async';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/auth.service.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';

final _log = Logger('PairedScreenCheck');

/// See the top of this file
class PairedScreenCheck {
  PairedScreenCheck(this._ref);

  final Ref _ref;
  Timer? _timer;

  /// Once the phone has stopped waiting for the screen's answer (35 s), and deleted the session if it never came
  static const afterPairingDelay = Duration(seconds: 40);

  /// After a pairing: a check once the phone can no longer delete the session for a lost answer
  void afterPairing() {
    _timer?.cancel();
    _timer = Timer(afterPairingDelay, () => unawaited(check()));
  }

  /// Back to the sign-in page when the server refuses the session a phone gave this screen; nothing otherwise, and
  /// nothing offline
  Future<void> check() async {
    try {
      final token = Store.tryGet(StoreKey.accessToken);
      if (token == null || Store.tryGet(StoreKey.pairingSignedInBy) == null) {
        return;
      }
      if (await _sessionGone(token)) {
        _log.info('Pairing: the session of this screen is gone, back to its sign-in page');
        await _ref.read(appRouterProvider).replaceAll([const WelcomeRoute(), const LoginRoute()]);
        await _ref.read(authServiceProvider).clearLocalData();
      }
    } catch (error) {
      _log.fine('Pairing: the session of this screen was not checked: ${error.runtimeType}');
    }
  }

  /// Whether the server refuses [token], still the one of the app (another sign in meanwhile is not this check's
  /// business); false offline
  Future<bool> _sessionGone(String token) async {
    try {
      await _ref.read(apiServiceProvider).usersApi.getMyUser();
      return false;
    } on ApiException catch (error) {
      return error.code == HttpStatus.unauthorized && Store.tryGet(StoreKey.accessToken) == token;
    }
  }

  void dispose() => _timer?.cancel();
}

final pairedScreenCheckProvider = Provider<PairedScreenCheck>((ref) {
  final check = PairedScreenCheck(ref);
  ref.onDispose(check.dispose);
  return check;
});
