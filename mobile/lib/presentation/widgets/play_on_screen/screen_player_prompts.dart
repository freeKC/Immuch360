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

/// See the top of this file; a fake in the tests
abstract interface class ScreenPlayerPrompts {
  /// "(phone) wants to play (title)": true on Play; false on Not now, or after [askTimeout]
  Future<bool> askPlay({required String phone, String? title});

  /// "Add (server) from (phone)?" with the warning and [check]: true on Add; false on Not now, or once [cancel]
  /// completes
  Future<bool> askHandover({
    required String phone,
    required String server,
    required String check,
    required Future<void> cancel,
  });

  /// "From (phone)", fading after a few seconds
  void toast({required String from});
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
  Future<bool> askPlay({required String phone, String? title}) => _ask(
    (context) => AlertDialog(
      key: const Key('play_from_phone_ask'),
      icon: const Icon(Icons.cast_connected_rounded),
      title: Text(
        title == null
            ? context.t.play_from_phone_ask_untitled(phone: phone)
            : context.t.play_from_phone_ask(phone: phone, title: title),
      ),
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
  Future<bool> askHandover({
    required String phone,
    required String server,
    required String check,
    required Future<void> cancel,
  }) => _ask(
    (context) => AlertDialog(
      key: const Key('play_handover_ask'),
      icon: const Icon(Icons.dns_rounded),
      title: Text(context.t.play_handover_screen_title(server: server, phone: phone)),
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
            Text(context.t.play_handover_screen_warning(server: server, phone: phone)),
          ],
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.t.play_from_phone_not_now),
        ),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(context.t.play_handover_add)),
      ],
    ),
    cancel,
  );

  @override
  void toast({required String from}) {
    final context = _context;
    if (context == null) {
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
