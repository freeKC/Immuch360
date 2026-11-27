// What a big screen shows when a linked phone plays on it (screen_player.provider.dart): the toast "From (phone)",
// the question of the Quest (and of a TV with "Ask before a phone plays") before a film plays, and the question of a
// token handover with its check number. Dialogs, never sheets or menus: they hold the focus of a remote, and their
// first button has it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_check_number.widget.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:immich_ui/immich_ui.dart';

/// Where the Meta Quest shows a phone's 360° item
enum ScreenSphereChoice {
  /// In the immersive viewer
  headset,

  /// In the app's window, as on a TV
  window,
}

/// See the top of this file; a fake in the tests
abstract interface class ScreenPlayerPrompts {
  /// "(phone) wants to play (title)", or "wants to show" a [photo]: true on Play; false on Not now, or after
  /// [askTimeout]
  Future<bool> askPlay({required String phone, String? title, bool photo = false});

  /// The same for a 360° item on the Meta Quest, asked before the user puts the headset view on: "In the headset" or
  /// "In the window"; null on Not now, or after [askTimeout]. The tap on "In the headset" is the user's gesture the
  /// immersive viewer opens with.
  Future<ScreenSphereChoice?> askPlaySphere({required String phone, String? title, bool photo = false});

  /// "Add (server) from (phone)?" with the warning and [check], or "Sign in to (server) with (phone)?" for the
  /// account [signInAs]: true on Add or Sign in; false on Not now, or once [cancel] completes
  Future<bool> askHandover({
    required String phone,
    required String server,
    required String check,
    required Future<void> cancel,
    String? signInAs,
  });

  /// "From (phone)", fading after a few seconds
  void toast({required String from});
}

/// A context under the overlay of the navigator of [key], for a toast: the navigator's own context is above its
/// overlay, where a toast finds none (found on the TV emulator, 25 November 2026)
BuildContext? overlayChildContext(GlobalKey<NavigatorState> key) {
  final overlay = key.currentState?.overlay;
  if (overlay == null || !overlay.mounted) {
    return null;
  }
  // The first element down the overlay that finds it: the overlay tells its entries apart from its own children
  Element? found;
  void visit(Element element) {
    if (found != null) {
      return;
    }
    if (Overlay.maybeOf(element) != null) {
      found = element;
      return;
    }
    element.visitChildElements(visit);
  }

  (overlay.context as Element).visitChildElements(visit);
  return found;
}

/// How long the screen waits for its user before a phone's play is taken as Not now
const askTimeout = Duration(seconds: 60);

final screenPlayerPromptsProvider = Provider<ScreenPlayerPrompts>((ref) => _AppScreenPlayerPrompts(ref));

class _AppScreenPlayerPrompts implements ScreenPlayerPrompts {
  _AppScreenPlayerPrompts(this._ref);

  final Ref _ref;

  BuildContext? get _context {
    final context = _ref.read(appRouterProvider).navigatorKey.currentContext;
    return context != null && context.mounted ? context : null;
  }

  /// Shows [dialog]; null when it closed without an answer, false once [until] completes first
  Future<bool> _ask(Widget Function(BuildContext context) dialog, Future<void> until) async {
    final context = _context;
    if (context == null) {
      return false;
    }
    var open = true;
    final navigator = Navigator.of(context, rootNavigator: true);
    final answer = showDialog<bool>(context: context, builder: dialog).whenComplete(() => open = false);
    unawaited(
      until.then((_) {
        if (open && navigator.mounted) {
          navigator.pop(false);
        }
      }),
    );
    return await answer ?? false;
  }

  @override
  Future<bool> askPlay({required String phone, String? title, bool photo = false}) => _ask(
    (context) => AlertDialog(
      key: const Key('play_from_phone_ask'),
      icon: const Icon(Icons.cast_connected_rounded),
      title: Text(switch ((title, photo)) {
        (null, false) => context.t.play_from_phone_ask_untitled(phone: phone),
        (null, true) => context.t.play_from_phone_ask_item_untitled(phone: phone),
        (final title?, false) => context.t.play_from_phone_ask(phone: phone, title: title),
        (final title?, true) => context.t.play_from_phone_ask_item(phone: phone, title: title),
      }),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t.play_from_phone_not_now)),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(context.t.play_from_phone_play),
        ),
      ],
    ),
    Future<void>.delayed(askTimeout),
  );

  @override
  Future<ScreenSphereChoice?> askPlaySphere({required String phone, String? title, bool photo = false}) async {
    final context = _context;
    if (context == null) {
      return null;
    }
    var open = true;
    final navigator = Navigator.of(context, rootNavigator: true);
    final answer = showDialog<ScreenSphereChoice>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('play_from_phone_ask_sphere'),
        icon: const Icon(Icons.vrpano_rounded),
        title: Text(switch ((title, photo)) {
          (null, false) => context.t.play_from_phone_ask_untitled(phone: phone),
          (null, true) => context.t.play_from_phone_ask_item_untitled(phone: phone),
          (final title?, false) => context.t.play_from_phone_ask(phone: phone, title: title),
          (final title?, true) => context.t.play_from_phone_ask_item(phone: phone, title: title),
        }),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.play_from_phone_not_now)),
          TextButton(
            key: const Key('play_from_phone_in_window'),
            onPressed: () => Navigator.of(context).pop(ScreenSphereChoice.window),
            child: Text(context.t.play_from_phone_in_window),
          ),
          FilledButton(
            key: const Key('play_from_phone_in_headset'),
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(ScreenSphereChoice.headset),
            child: Text(context.t.play_from_phone_in_headset),
          ),
        ],
      ),
    ).whenComplete(() => open = false);
    unawaited(
      Future<void>.delayed(askTimeout).then((_) {
        if (open && navigator.mounted) {
          navigator.pop();
        }
      }),
    );
    return answer;
  }

  @override
  Future<bool> askHandover({
    required String phone,
    required String server,
    required String check,
    required Future<void> cancel,
    String? signInAs,
  }) => _ask(
    (context) => AlertDialog(
      key: const Key('play_handover_ask'),
      icon: Icon(signInAs == null ? Icons.dns_rounded : Icons.login_rounded),
      title: Text(
        signInAs == null
            ? context.t.play_handover_screen_title(server: server, phone: phone)
            : context.t.play_sign_in_screen_title(server: server, phone: phone),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PlayCheckNumber(
              check: check,
              hint: context.t.play_handover_screen_check(phone: phone),
            ),
            const SizedBox(height: ImmichSpacing.md),
            Text(
              signInAs == null
                  ? context.t.play_handover_screen_warning(server: server, phone: phone)
                  : context.t.play_sign_in_screen_body(user: signInAs, phone: phone),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.t.play_from_phone_not_now),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(signInAs == null ? context.t.play_handover_add : context.t.pairing_confirm_button),
        ),
      ],
    ),
    cancel,
  );

  @override
  void toast({required String from}) {
    final context = overlayChildContext(_ref.read(appRouterProvider).navigatorKey);
    if (context == null || !context.mounted) {
      return;
    }
    ImmichToast.show(
      context: context,
      msg: context.t.play_from_phone_toast(phone: from),
      toastType: ToastType.info,
      gravity: ToastGravity.TOP,
    );
  }
}
