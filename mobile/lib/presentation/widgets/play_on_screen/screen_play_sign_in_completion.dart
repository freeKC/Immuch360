// After "Sign (screen) in to (server)" from a linked phone (screen_play_sign_in.dart): the toast "Signed in as (user)
// with (phone)", then what any sign in of the app does (the sync, the timeline in place of the sign in page), as
// the pairing panel does after "Sign in with your phone".

import 'dart:async';

import 'package:fluttertoast/fluttertoast.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/pairing/screen_sign_in.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/pairing/paired_screen_check.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:immich_mobile/widgets/forms/login/sign_in_completion.dart';

Future<void> completeScreenPlaySignIn(WidgetRef ref, ScreenSignedIn signedIn) async {
  final context = ref.read(appRouterProvider).navigatorKey.currentContext;
  if (context == null || !context.mounted) {
    return;
  }
  final phone = signedIn.phone;
  if (signedIn.user.isNotEmpty && phone != null) {
    ImmichToast.show(
      context: context,
      msg: context.t.pairing_screen_signed_in_with(user: signedIn.user, phone: phone),
      toastType: ToastType.success,
      gravity: ToastGravity.TOP,
    );
  }
  // The server may refuse the session later (the phone signed out meanwhile): back to the sign in page then
  ref.read(pairedScreenCheckProvider).afterPairing();
  await completeSignIn(context, ref);
}
