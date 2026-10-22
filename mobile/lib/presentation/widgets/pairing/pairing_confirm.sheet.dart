import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/pairing/phone_pairing.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_client.dart';
import 'package:immich_ui/immich_ui.dart';

/// What the user chose on the confirmation sheet
class PairingConfirmChoice {
  const PairingConfirmChoice({required this.label, required this.sendHeaders});

  /// The name the user kept or typed for the screen
  final String label;

  /// Whether the custom headers of the Networking settings go to the screen
  final bool sendHeaders;
}

/// The icon of a kind of big screen
IconData pairingKindIcon(PairingScreenKind kind) => switch (kind) {
  PairingScreenKind.tv => Icons.tv_rounded,
  PairingScreenKind.headset => Icons.view_in_ar_rounded,
  PairingScreenKind.computer => Icons.computer_rounded,
};

/// "Sign Living room TV in?": what the phone is about to do, asked before anything is created on the server, with what
/// the user can check against the screen in front of them: its kind, its address and the check number it shows. Gives
/// null when the user cancelled.
Future<PairingConfirmChoice?> showPairingConfirmSheet(
  BuildContext context, {
  required PairingScreenDevice device,
  required String address,
  required String check,
  required String server,
  required String user,
  required List<String> headerNames,
  required bool notOnPhoneNetwork,
}) => showModalBottomSheet<PairingConfirmChoice>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => PairingConfirmSheet(
    device: device,
    address: address,
    check: check,
    server: server,
    user: user,
    headerNames: headerNames,
    notOnPhoneNetwork: notOnPhoneNetwork,
  ),
);

class PairingConfirmSheet extends StatefulWidget {
  const PairingConfirmSheet({
    super.key,
    required this.device,
    required this.address,
    required this.check,
    required this.server,
    required this.user,
    required this.headerNames,
    required this.notOnPhoneNetwork,
  });

  final PairingScreenDevice device;

  /// The private IPv4 address the phone talks to
  final String address;

  /// The six digits the screen shows for this phone
  final String check;

  /// The host of the server, as the user knows it
  final String server;
  final String user;

  /// The names of the custom headers of the Networking settings, never their values
  final List<String> headerNames;

  /// The screen's address is not on one of the phone's own networks
  final bool notOnPhoneNetwork;

  @override
  State<PairingConfirmSheet> createState() => _PairingConfirmSheetState();
}

class _PairingConfirmSheetState extends State<PairingConfirmSheet> {
  late final TextEditingController _name = TextEditingController(text: widget.device.label);
  bool _sendHeaders = true;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _confirm() {
    final label = cleanPairingLabel(_name.text) ?? cleanPairingLabel(widget.device.label);
    if (label != null) {
      Navigator.of(context).pop(PairingConfirmChoice(label: label, sendHeaders: _sendHeaders));
    }
  }

  static String _kind(Translations t, PairingScreenKind kind) => switch (kind) {
    PairingScreenKind.tv => t.pairing_kind_tv,
    PairingScreenKind.headset => t.pairing_kind_headset,
    PairingScreenKind.computer => t.pairing_kind_computer,
  };

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = context.textTheme;
    final scheme = context.colorScheme;
    final device = widget.device.label.isEmpty ? _kind(t, widget.device.kind) : widget.device.label;
    final quiet = theme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
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
            const SizedBox(height: ImmichSpacing.xs),
            Row(
              children: [
                Icon(pairingKindIcon(widget.device.kind), size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: ImmichSpacing.xs),
                Expanded(
                  child: Text(
                    t.pairing_confirm_where(kind: _kind(t, widget.device.kind), address: widget.address),
                    key: const Key('pairing_confirm_where'),
                    style: theme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: ImmichSpacing.md),
            // What ties this sheet to the screen in front of the user: the same number shows there
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: const BorderRadius.all(Radius.circular(12)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(ImmichSpacing.md),
                child: Column(
                  children: [
                    Text(
                      t.pairing_confirm_check,
                      textAlign: TextAlign.center,
                      style: theme.bodyMedium?.copyWith(color: scheme.onPrimaryContainer),
                    ),
                    const SizedBox(height: ImmichSpacing.xs),
                    Text(
                      formatPairingCheckNumber(widget.check),
                      key: const Key('pairing_confirm_check'),
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
            ),
            const SizedBox(height: ImmichSpacing.md),
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
            Text(t.pairing_confirm_cascade, style: quiet),
            if (widget.headerNames.isNotEmpty)
              SwitchListTile(
                key: const Key('pairing_confirm_headers'),
                contentPadding: EdgeInsets.zero,
                value: _sendHeaders,
                onChanged: (value) => setState(() => _sendHeaders = value),
                title: Text(t.pairing_confirm_headers(count: widget.headerNames.length)),
                subtitle: Text(t.pairing_confirm_headers_hint(names: widget.headerNames.join(', ')), style: quiet),
              ),
            if (widget.notOnPhoneNetwork) warning(t.pairing_confirm_not_your_network),
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
