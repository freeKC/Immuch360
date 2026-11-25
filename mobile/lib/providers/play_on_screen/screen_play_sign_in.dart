// "Sign (screen) in to (server)" from a linked phone (release 53), on the screen's side: a screen signed in to no
// Immich server at all takes the session a phone made for it, through the handover with the six digits that both
// devices show and both users accept (screen_player_session.dart), and signs in with it as "Sign in with your phone"
// does (ScreenSignIn.withSession: the addresses tried in order, the token checked with the server, the screen left as
// it was on any failure). A screen signed in already never is: a phone cannot sign the household's TV out of its
// account. Once signed in, the app leaves its sign in page as after any sign in (ImmichApp listens to
// [screenPlaySignedInProvider]).

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/pairing/screen_sign_in.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/presentation/widgets/pairing/pairing_panel.widget.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('ScreenPlayer');

/// See the top of this file; a fake in the tests
abstract interface class ScreenPlaySignIn {
  /// Whether this screen has no account signed in
  bool get signedOut;

  /// Signs in with the session [payload] [phone] made for this screen
  Future<HandoverResult> signIn(String phone, Map<String, Object?> payload);
}

class AppScreenPlaySignIn implements ScreenPlaySignIn {
  AppScreenPlaySignIn(this._ref);

  final Ref _ref;

  @override
  bool get signedOut => _ref.read(currentUserProvider) == null;

  @override
  Future<HandoverResult> signIn(String phone, Map<String, Object?> payload) async {
    if (!signedOut) {
      return HandoverResult.alreadySignedIn;
    }
    final signIn = ScreenSignIn(AppScreenSignInActions.of(_ref));
    // The name of the phone is the one of its link, not one the payload claims
    final result = await signIn.withSession({...payload, 'phone': phone});
    final status = result.answer['status'];
    _log.info('Play from a phone: a sign in from a phone ended ($status)');
    if (!result.signedIn) {
      return switch (status) {
        'serverUnreachable' => HandoverResult.unreachable,
        'tokenRejected' => HandoverResult.tokenRefused,
        _ => HandoverResult.failed,
      };
    }
    _ref.read(screenPlaySignedInProvider.notifier).state = signIn.signedIn ?? ScreenSignedIn(user: '', phone: phone);
    return HandoverResult.added;
  }
}

final screenPlaySignInProvider = Provider<ScreenPlaySignIn>(AppScreenPlaySignIn.new);

/// Who signed this screen in from "Play on…", once it did: the app then leaves its sign in page
final screenPlaySignedInProvider = StateProvider<ScreenSignedIn?>((_) => null);
