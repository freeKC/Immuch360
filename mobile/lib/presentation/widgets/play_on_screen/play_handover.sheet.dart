import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_check_number.widget.dart';
import 'package:immich_ui/immich_ui.dart';

/// "Add (server) to (screen)?": the check number the screen shows too, and the warning of the user guide, before the
/// token of this phone for that server goes to the screen. True when the user adds it.
Future<bool> showPlayHandoverSheet(
  BuildContext context, {
  required String screen,
  required String server,
  required String check,
}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => PlayHandoverSheet(screen: screen, server: server, check: check),
    ) ??
    false;

/// "Sign (screen) in?" (release 53): the check number, who the screen will be signed in as, and the warning of "Sign
/// in with your phone", before a session of this phone's account goes to the screen. True when the user signs it in.
Future<bool> showPlaySignInSheet(
  BuildContext context, {
  required String screen,
  required String server,
  required String user,
  required String check,
}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => PlayHandoverSheet(
        screen: screen,
        server: server,
        check: check,
        title: context.t.pairing_confirm_title(device: screen),
        body: context.t.pairing_confirm_body(device: screen, server: server, user: user),
        warning: context.t.pairing_confirm_cascade,
        confirm: context.t.pairing_confirm_button,
      ),
    ) ??
    false;

class PlayHandoverSheet extends StatelessWidget {
  const PlayHandoverSheet({
    super.key,
    required this.screen,
    required this.server,
    required this.check,
    this.title,
    this.body,
    this.warning,
    this.confirm,
  });

  final String screen;
  final String server;
  final String check;

  /// The texts of "Sign (screen) in?" in place of those of "Add (server) to (screen)?"
  final String? title;
  final String? body;
  final String? warning;
  final String? confirm;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = context.textTheme;
    final scheme = context.colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(ImmichSpacing.lg, 0, ImmichSpacing.lg, ImmichSpacing.lg),
        child: SingleChildScrollView(
          child: Column(
            key: const Key('play_handover_sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title ?? t.play_handover_title(server: server, device: screen),
                style: theme.titleLarge,
              ),
              if (body case final body?) ...[
                const SizedBox(height: ImmichSpacing.sm),
                Text(body, key: const Key('play_handover_body'), style: theme.bodyLarge),
              ],
              const SizedBox(height: ImmichSpacing.md),
              PlayCheckNumber(
                check: check,
                hint: t.play_handover_check(device: screen),
              ),
              const SizedBox(height: ImmichSpacing.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, color: scheme.error, size: 20),
                  const SizedBox(width: ImmichSpacing.sm),
                  Expanded(
                    child: Text(
                      warning ?? t.play_handover_warning(device: screen, server: server),
                      key: const Key('play_handover_warning'),
                      style: theme.bodyMedium?.copyWith(color: scheme.error),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: ImmichSpacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.cancel)),
                  const SizedBox(width: ImmichSpacing.sm),
                  FilledButton(
                    key: const Key('play_handover_confirm'),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(confirm ?? t.play_handover_add),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
