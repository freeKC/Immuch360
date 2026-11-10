import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_client.dart';
import 'package:immich_mobile/presentation/widgets/pairing/pairing_confirm.sheet.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_check_number.widget.dart';
import 'package:immich_ui/immich_ui.dart';

/// "Let this phone play films on Living room TV?": the sheet of a screen whose panel shows "Play from a phone", with
/// the check number it shows. True when the user links it.
Future<bool> showPlayLinkConfirmSheet(
  BuildContext context, {
  required PairingScreenDevice device,
  required String address,
  required String check,
}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => PlayLinkConfirmSheet(device: device, address: address, check: check),
    ) ??
    false;

class PlayLinkConfirmSheet extends StatelessWidget {
  const PlayLinkConfirmSheet({super.key, required this.device, required this.address, required this.check});

  final PairingScreenDevice device;
  final String address;
  final String check;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = context.textTheme;
    final scheme = context.colorScheme;
    final name = device.label.isEmpty ? playScreenKindName(t, device.kind) : device.label;
    return Padding(
      padding: const EdgeInsets.fromLTRB(ImmichSpacing.lg, 0, ImmichSpacing.lg, ImmichSpacing.lg),
      child: SingleChildScrollView(
        child: Column(
          key: const Key('play_link_confirm_sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.play_link_confirm_title(device: name), style: theme.titleLarge),
            const SizedBox(height: ImmichSpacing.xs),
            Row(
              children: [
                Icon(pairingKindIcon(device.kind), size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: ImmichSpacing.xs),
                Expanded(
                  child: Text(
                    t.pairing_confirm_where(kind: playScreenKindName(t, device.kind), address: address),
                    style: theme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: ImmichSpacing.md),
            PlayCheckNumber(check: check, hint: t.pairing_confirm_check),
            const SizedBox(height: ImmichSpacing.md),
            Text(t.play_link_confirm_body(device: name)),
            const SizedBox(height: ImmichSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.cancel)),
                const SizedBox(width: ImmichSpacing.sm),
                FilledButton.icon(
                  key: const Key('play_link_confirm_button'),
                  icon: const Icon(Icons.cast_rounded),
                  label: Text(t.play_link_confirm_button),
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "TV", "headset", "computer" as the pairing texts say them
String playScreenKindName(Translations t, PairingScreenKind kind) => switch (kind) {
  PairingScreenKind.tv => t.pairing_kind_tv,
  PairingScreenKind.headset => t.pairing_kind_headset,
  PairingScreenKind.computer => t.pairing_kind_computer,
};
