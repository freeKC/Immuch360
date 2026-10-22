import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/services/pairing/phone_pairing.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_client.dart';
import 'package:immich_ui/immich_ui.dart';

/// "Sign in Living room TV?": what the phone is about to do, asked before anything is created on the server. Gives the
/// name the user kept or typed for the screen, null when the user cancelled.
Future<String?> showPairingConfirmSheet(
  BuildContext context, {
  required PairingScreenDevice device,
  required String server,
  required String user,
  required int headerCount,
  required bool notOnPhoneNetwork,
  required bool fromDeepLink,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => PairingConfirmSheet(
    device: device,
    server: server,
    user: user,
    headerCount: headerCount,
    notOnPhoneNetwork: notOnPhoneNetwork,
    fromDeepLink: fromDeepLink,
  ),
);

class PairingConfirmSheet extends StatefulWidget {
  const PairingConfirmSheet({
    super.key,
    required this.device,
    required this.server,
    required this.user,
    required this.headerCount,
    required this.notOnPhoneNetwork,
    required this.fromDeepLink,
  });

  final PairingScreenDevice device;

  /// The host of the server, as the user knows it
  final String server;
  final String user;

  /// How many custom headers of the Networking settings go along (their names and values are not shown)
  final int headerCount;

  /// The screen's address is not on one of the phone's own networks
  final bool notOnPhoneNetwork;

  /// The code came from a link rather than the scanner: only a screen in front of the user should be signed in
  final bool fromDeepLink;

  @override
  State<PairingConfirmSheet> createState() => _PairingConfirmSheetState();
}

class _PairingConfirmSheetState extends State<PairingConfirmSheet> {
  late final TextEditingController _name = TextEditingController(text: widget.device.label);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _confirm() {
    final label = cleanPairingLabel(_name.text) ?? cleanPairingLabel(widget.device.label);
    if (label != null) {
      Navigator.of(context).pop(label);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = context.textTheme;
    final scheme = context.colorScheme;
    final device = widget.device.label.isEmpty ? t.pairing_connect_title : widget.device.label;
    Widget warning(String text) => Padding(
      padding: const EdgeInsets.only(top: ImmichSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.error, size: 20),
          const SizedBox(width: ImmichSpacing.sm),
          Expanded(
            child: Text(text, style: theme.bodyMedium?.copyWith(color: scheme.error)),
          ),
        ],
      ),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        ImmichSpacing.lg,
        0,
        ImmichSpacing.lg,
        ImmichSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          key: const Key('pairing_confirm_sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.pairing_confirm_title(device: device), style: theme.titleLarge),
            const SizedBox(height: ImmichSpacing.sm),
            Text(t.pairing_confirm_body(device: device, server: widget.server, user: widget.user)),
            const SizedBox(height: ImmichSpacing.md),
            TextField(
              key: const Key('pairing_confirm_name'),
              controller: _name,
              maxLength: maxLabelLength,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(labelText: t.pairing_confirm_name_label, border: const OutlineInputBorder()),
              onSubmitted: (_) => _confirm(),
            ),
            Text(t.pairing_confirm_cascade, style: theme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            if (widget.headerCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: ImmichSpacing.xs),
                child: Text(
                  t.pairing_confirm_headers(count: widget.headerCount),
                  style: theme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            if (widget.notOnPhoneNetwork) warning(t.pairing_confirm_not_your_network),
            if (widget.fromDeepLink) warning(t.pairing_confirm_deep_link_warning),
            const SizedBox(height: ImmichSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.cancel)),
                const SizedBox(width: ImmichSpacing.sm),
                FilledButton.icon(
                  key: const Key('pairing_confirm_button'),
                  icon: const Icon(Icons.login_rounded),
                  label: Text(t.pairing_confirm_button),
                  onPressed: _confirm,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
