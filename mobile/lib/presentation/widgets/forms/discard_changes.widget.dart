import 'dart:async';

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// Asks before a form whose fields hold unsaved changes is left: Back of a remote or of the system, the close button
/// of its app bar, anything that pops the page through the navigator. A form without changes leaves at once, as
/// before. [listenable] tells when [hasChanges] may have changed (the text controllers of the fields), so that the
/// system knows ahead whether the page may go (the back gesture of iOS, the predictive back of Android);
/// [hasChanges] is read again when the page is about to go.
class DiscardChangesScope extends StatelessWidget {
  const DiscardChangesScope({super.key, required this.listenable, required this.hasChanges, required this.child});

  final Listenable listenable;
  final bool Function() hasChanges;
  final Widget child;

  Future<void> _leave(BuildContext context) async {
    if (hasChanges() && !await confirmDiscardChanges(context)) {
      return;
    }
    if (!context.mounted) {
      return;
    }
    // A form that is the first page has nowhere to go back to, as without this scope
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, child) => PopScope(
        canPop: !hasChanges(),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            unawaited(_leave(context));
          }
        },
        child: child!,
      ),
      child: child,
    );
  }
}

/// "Discard the changes?": true when the user chose to lose what the form holds. The safe answer, keep editing, has
/// the focus, so that OK of a remote pressed once more by mistake loses nothing.
Future<bool> confirmDiscardChanges(BuildContext context) async {
  final discard = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.t.form_discard_changes_title),
      content: Text(context.t.form_discard_changes_body),
      actions: [
        TextButton(
          key: const Key('form_discard_changes_keep'),
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.t.form_discard_changes_keep),
        ),
        TextButton(
          key: const Key('form_discard_changes_discard'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(context.t.form_discard_changes_discard, style: TextStyle(color: context.colorScheme.error)),
        ),
      ],
    ),
  );
  return discard ?? false;
}
