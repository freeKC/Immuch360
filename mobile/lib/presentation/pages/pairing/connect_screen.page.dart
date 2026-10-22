// "Connect a TV or computer" on a phone or a tablet: scan the code a big screen shows (or type it), check that it is
// that screen, ask the user, then sign it in with a session of its own (phone_pairing.service.dart). Below, the
// screens this phone signed in, each with Sign out.
//
// An immuch360://pair link (the "Open it" link of the page a screen serves to a phone's browser) only opens this page
// with the screen's address: the phone then scans the code on the screen, or asks for the code it shows, before it
// says anything to that address. A link can come from anywhere; the camera and the code on the screen cannot.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/pairing/phone_pairing.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_client.dart';
import 'package:immich_mobile/platform/qr_scan_api.g.dart';
import 'package:immich_mobile/presentation/widgets/pairing/pairing_confirm.sheet.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';
import 'package:immich_mobile/providers/pairing/phone_pairing.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:url_launcher/url_launcher.dart';

@RoutePage()
class ConnectScreenPage extends ConsumerStatefulWidget {
  const ConnectScreenPage({super.key, this.linkedAddress});

  /// The address ("192.168.1.23:8361") of the screen whose link opened the page; never a secret
  final String? linkedAddress;

  @override
  ConsumerState<ConnectScreenPage> createState() => _ConnectScreenPageState();
}

class _ConnectScreenPageState extends ConsumerState<ConnectScreenPage> {
  bool _busy = false;

  /// The address of the screen a link named, for the hint and Enter a code
  String? _linked;

  @override
  void initState() {
    super.initState();
    unawaited(ref.read(pairedScreensProvider.notifier).refresh());
    final linked = widget.linkedAddress;
    if (linked != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_fromLink(linked)));
    }
  }

  /// A link of a screen: the scanner at once, since the user stands before that screen; nothing goes to the address
  Future<void> _fromLink(String address) async {
    if (!mounted || _busy) {
      return;
    }
    setState(() => _linked = address);
    await _scan();
  }

  Future<void> _scan() async {
    final t = context.t;
    final QrScanResult result;
    try {
      result = await ref.read(qrScanApiProvider).scan(t.pairing_scan_prompt, t.cancel);
    } catch (_) {
      return _showError(t.pairing_err_no_camera, offerCode: true);
    }
    if (!mounted) {
      return;
    }
    switch (result.status) {
      case QrScanStatus.scanned:
        // The text holds the secret of the code: it goes to the parser only, never to a log
        await _handleText(result.text ?? '');
      case QrScanStatus.permissionDenied:
        await _showError(t.pairing_err_camera_denied, offerCode: true);
      case QrScanStatus.noCamera:
        await _showError(t.pairing_err_no_camera, offerCode: true);
      case QrScanStatus.cancelled || QrScanStatus.failed:
        break;
    }
  }

  Future<void> _enterCode() async {
    final target = await context.pushRoute<PairingTarget>(EnterCodeRoute(address: _linked));
    if (target != null && mounted) {
      await _pair(target);
    }
  }

  Future<void> _handleText(String text) async {
    final t = context.t;
    switch (parsePairingText(text)) {
      case final PairingTarget target:
        await _pair(target);
      case WebOsPairingLink(:final uri):
        final open = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            content: Text(t.pairing_err_webos),
            actions: [
              TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(t.cancel)),
              FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: Text(t.open)),
            ],
          ),
        );
        if (open == true) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      case NotAPairingCode():
        await _showError(t.pairing_err_not_a_code);
    }
  }

  Future<void> _pair(PairingTarget target) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _pairNow(target);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _pairNow(PairingTarget target) async {
    final t = context.t;
    final service = ref.read(phonePairingServiceProvider);
    final PairingHello hello;
    try {
      hello = await service.hello(target);
    } on PairingException catch (error) {
      return _showError(_helloError(t, error.failure, target.host));
    }
    final account = await ref.read(phonePairingAccountProvider)();
    final onNetwork = await _onPhoneNetwork(target.host);
    if (!mounted) {
      return unawaited(service.cancel(hello));
    }
    final choice = await showPairingConfirmSheet(
      context,
      device: hello.device,
      address: target.host,
      check: hello.check,
      server: Uri.tryParse(account.server)?.host ?? account.server,
      user: account.userName.isNotEmpty ? account.userName : account.userEmail,
      headerNames: account.headers.keys.toList(),
      notOnPhoneNetwork: !onNetwork,
    );
    if (choice == null || !mounted) {
      // The screen stops waiting for this phone
      return unawaited(service.cancel(hello));
    }
    final label = choice.label;

    final screens = ref.read(pairedScreensProvider.notifier);
    String? listed;
    final progress = _showProgress(t.pairing_progress(device: label));
    final PhonePairingResult result;
    try {
      result = await service.signIn(
        hello,
        label: label,
        account: account,
        sendHeaders: choice.sendHeaders,
        // Listed before the session leaves the phone: if the app dies meanwhile, the user still sees it and can sign
        // it out; the refresh at the next start drops it when the server no longer has it
        onSession: (sessionId, name) {
          listed = sessionId;
          return screens.add(
            PairedScreen(
              sessionId: sessionId,
              label: name,
              kind: hello.device.kind,
              os: pairingSessionOs(hello.device),
              at: DateTime.now(),
            ),
          );
        },
      );
    } finally {
      progress.close();
    }
    final sessionId = result.sessionId;
    if (!result.signedIn || sessionId == null) {
      if (listed case final id?) {
        await screens.remove(id);
      }
    }
    if (!mounted) {
      return;
    }
    if (result.signedIn && sessionId != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.pairing_done(device: label))));
      return;
    }
    final server = Uri.tryParse(account.server)?.host ?? account.server;
    await _showError(switch (result.status) {
      PhonePairingStatus.serverUnreachable => t.pairing_err_screen_cannot_reach(device: label, server: server),
      PhonePairingStatus.tokenRejected => t.pairing_err_token_rejected(device: label),
      PhonePairingStatus.busy => t.pairing_err_busy(device: label),
      PhonePairingStatus.rejected => t.pairing_err_wrong_code,
      PhonePairingStatus.expired => t.pairing_err_expired,
      PhonePairingStatus.used => t.pairing_err_used,
      PhonePairingStatus.serverTooOld => t.pairing_err_server_old,
      PhonePairingStatus.phoneOffline => t.pairing_err_phone_offline,
      PhonePairingStatus.lost ||
      PhonePairingStatus.refused ||
      PhonePairingStatus.signedIn => t.pairing_err_lost(device: label),
    });
  }

  String _helloError(Translations t, PairingFailure failure, String host) => switch (failure) {
    PairingFailure.unreachable => _unreachable(t, host),
    PairingFailure.expired => t.pairing_err_expired,
    PairingFailure.used => t.pairing_err_used,
    PairingFailure.throttled => t.pairing_err_throttled,
    PairingFailure.wrongCode || PairingFailure.rejected => t.pairing_err_wrong_code,
    PairingFailure.busy => t.pairing_err_throttled,
    PairingFailure.lost || PairingFailure.invalid => t.pairing_err_screen_answer,
  };

  /// iOS asks for the local network once: a refusal looks like an unreachable screen
  static String _unreachable(Translations t, String host) {
    final message = t.pairing_err_unreachable(address: host);
    if (CurrentPlatform.isIOS) {
      return '$message ${t.pairing_err_local_network_ios}';
    }
    return message;
  }

  /// Whether [host] is on one of the networks of the phone: the same /24 as one of its LAN addresses, the size of
  /// almost every home network (the interfaces of dart:io do not tell their mask)
  Future<bool> _onPhoneNetwork(String host) async {
    final own = await phoneShareLocalAddresses();
    final prefix = host.substring(0, host.lastIndexOf('.') + 1);
    return own.any((address) => address.startsWith(prefix));
  }

  ({void Function() close}) _showProgress(String message) {
    var open = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 3)),
                const SizedBox(width: ImmichSpacing.lg),
                Expanded(child: Text(message)),
              ],
            ),
          ),
        ),
      ).whenComplete(() => open = false),
    );
    return (
      close: () {
        if (open && mounted) {
          Navigator.of(context, rootNavigator: true).pop();
        }
      },
    );
  }

  Future<void> _showError(String message, {bool offerCode = false}) async {
    if (!mounted) {
      return;
    }
    final t = context.t;
    final enterCode = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.error_outline_rounded),
        content: Text(message, key: const Key('pairing_error')),
        actions: [
          if (offerCode)
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: Text(t.pairing_enter_code)),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(t.ok)),
        ],
      ),
    );
    if (enterCode == true && mounted) {
      await _enterCode();
    }
  }

  Future<void> _signOut(PairedScreen screen) async {
    final t = context.t;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(t.pairing_sign_out_device_confirm(device: screen.label)),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: Text(t.pairing_sign_out_device)),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      await ref.read(pairedScreensProvider.notifier).signOut(screen);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.pairing_err_phone_offline)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // A link that came while the page shows
    ref.listen(pendingPairingLinkProvider, (_, address) {
      if (address != null) {
        ref.read(pendingPairingLinkProvider.notifier).state = null;
        unawaited(_fromLink(address));
      }
    });
    final t = context.t;
    final screens = ref.watch(pairedScreensProvider);
    final theme = context.textTheme;
    final dates = DateFormat.yMMMd(context.locale.toLanguageTag());
    return Scaffold(
      appBar: AppBar(title: Text(t.pairing_connect_title)),
      body: ListView(
        padding: const EdgeInsets.all(ImmichSpacing.lg),
        children: [
          Text(t.pairing_connect_subtitle, style: theme.bodyLarge),
          if (_linked case final linked?) ...[
            const SizedBox(height: ImmichSpacing.md),
            Text(
              t.pairing_link_hint(address: linked),
              key: const Key('pairing_link_hint'),
              style: theme.bodyMedium,
            ),
          ],
          const SizedBox(height: ImmichSpacing.lg),
          FilledButton.icon(
            key: const Key('pairing_scan'),
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: Text(t.pairing_scan_button),
            onPressed: _busy ? null : () => unawaited(_scan()),
          ),
          const SizedBox(height: ImmichSpacing.sm),
          OutlinedButton.icon(
            key: const Key('pairing_enter_code'),
            icon: const Icon(Icons.keyboard_rounded),
            label: Text(t.pairing_enter_code),
            onPressed: _busy ? null : () => unawaited(_enterCode()),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: ImmichSpacing.md),
              child: LinearProgressIndicator(),
            ),
          const SizedBox(height: ImmichSpacing.xl),
          Text(t.pairing_connected_title, style: theme.titleMedium),
          const SizedBox(height: ImmichSpacing.sm),
          if (screens.isEmpty)
            Text(t.pairing_connected_empty, style: theme.bodyMedium)
          else
            for (final screen in screens)
              ListTile(
                key: ValueKey('paired_${screen.sessionId}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(pairingKindIcon(screen.kind)),
                title: Text(screen.label),
                subtitle: Text(
                  [
                    t.pairing_connected_since(date: dates.format(screen.at.toLocal())),
                    if (screen.lastSeen case final lastSeen?) '${t.last_seen} ${dates.format(lastSeen.toLocal())}',
                  ].join(' · '),
                ),
                trailing: TextButton(
                  onPressed: () => unawaited(_signOut(screen)),
                  child: Text(t.pairing_sign_out_device),
                ),
              ),
          const SizedBox(height: ImmichSpacing.md),
          Text(t.pairing_connected_footer, style: theme.bodySmall),
        ],
      ),
    );
  }
}
