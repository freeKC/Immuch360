import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_ui/immich_ui.dart';

/// The six digits both sides of a pairing or of a token handover show, in the box of the pairing sheet, with the line
/// that says what to check
class PlayCheckNumber extends StatelessWidget {
  const PlayCheckNumber({super.key, required this.check, required this.hint});

  final String check;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = context.textTheme;
    final scheme = context.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ImmichSpacing.md),
        child: Column(
          children: [
            Text(
              hint,
              textAlign: TextAlign.center,
              style: theme.bodyMedium?.copyWith(color: scheme.onPrimaryContainer),
            ),
            const SizedBox(height: ImmichSpacing.xs),
            Text(
              formatPairingCheckNumber(check),
              key: const Key('play_check_number'),
              style: TextStyle(
                fontFamily: 'GoogleSansCode',
                fontSize: 30,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
                color: scheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
