import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/network/computer_share.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// "Share this phone on the network": the switch, then while it is on the address, the name the headset finds, the
/// user name and the password to type there, and who is connected. Phones only (see [PhoneShareTile]).
@RoutePage()
class PhoneSharePage extends ConsumerWidget {
  const PhoneSharePage({super.key});

  Future<void> _switch(BuildContext context, WidgetRef ref, bool on) async {
    final controller = ref.read(phoneShareProvider.notifier);
    if (!on) {
      return controller.stop();
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    // A computer shares the folders the user chose: none chosen yet is what stops it there
    final refused = CurrentPlatform.isDesktop
        ? context.t.desktop_folders_choose_title
        : context.t.local_session_permission_title;
    // Nothing to share without the photos and videos
    if (!await ref.read(phoneSharePermissionsProvider)()) {
      messenger?.showSnackBar(SnackBar(content: Text(refused)));
      return;
    }
    // A computer may be on a network Windows marks as public (lib/desktop/network/computer_share.dart)
    if (CurrentPlatform.isDesktop && (!context.mounted || !await confirmComputerShare(context))) {
      return;
    }
    await controller.start();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(phoneShareProvider);
    final t = context.t;
    // The same share on a computer, with its own wording
    final computer = CurrentPlatform.isDesktop;

    return Scaffold(
      appBar: AppBar(
        title: Text(computer ? t.computer_share_title : t.phone_share_title),
        elevation: 0,
        centerTitle: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 32),
          children: [
            SwitchListTile(
              key: const Key('phone_share_switch'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              secondary: Icon(computer ? Icons.computer : Icons.smartphone, color: context.primaryColor),
              title: Text(computer ? t.computer_share_switch : t.phone_share_switch),
              value: state.isEnabled,
              onChanged: state.status == PhoneShareStatus.starting
                  ? null
                  : (on) => unawaited(_switch(context, ref, on)),
            ),
            if (state.status == PhoneShareStatus.starting) const LinearProgressIndicator(),
            if (state.status == PhoneShareStatus.error && state.error != null)
              _Notice(icon: Icons.error_outline, text: state.error!, color: context.colorScheme.error),
            if (!state.isEnabled && state.stoppedIdle)
              _Notice(icon: Icons.timer_off_outlined, text: t.phone_share_stopped_idle),
            if (state.isEnabled) ...[
              _SharedCard(state: state),
              if (state.serviceName != null)
                _Notice(
                  icon: Icons.vrpano_outlined,
                  text: t.phone_share_headset_steps(name: state.serviceName!),
                ),
              if (state.status == PhoneShareStatus.on)
                ListTile(
                  key: const Key('phone_share_clients'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  leading: const Icon(Icons.devices_other_outlined),
                  title: Text(t.phone_share_clients(count: state.clients)),
                  subtitle: state.lastFile == null
                      ? null
                      : Text(state.lastFile!, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ],
            if (CurrentPlatform.isIOS) _Notice(icon: Icons.info_outline, text: t.phone_share_ios_foreground),
            // The firewall and the public networks of a computer (lib/desktop/network/computer_share.dart)
            if (computer) const ComputerShareNotices(),
            _Notice(icon: Icons.lock_outline, text: computer ? t.computer_share_read_only : t.phone_share_read_only),
          ],
        ),
      ),
    );
  }
}

/// The first tile of the network shares page, on phones only: the headset is the one that reads the share
class PhoneShareTile extends ConsumerWidget {
  const PhoneShareTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPhone = CurrentPlatform.isAndroid || CurrentPlatform.isIOS;
    // The computers share their folders once that is available (lib/desktop/network/computer_share.dart)
    final computer = CurrentPlatform.isDesktop && computerShareAvailable;
    // A TV reads the shares of others, it is not one: no phone share there either
    if (!(isPhone || computer) || ref.watch(isHorizonOsProvider).valueOrNull != false || ref.watch(tvModeProvider)) {
      return const SizedBox.shrink();
    }
    final state = ref.watch(phoneShareProvider);
    final address = state.address;
    final t = context.t;
    final subtitle = !state.isEnabled
        ? t.phone_share_subtitle_off
        : address == null
        ? (computer ? t.computer_share_no_network : t.phone_share_no_network)
        : t.phone_share_subtitle_on(address: address);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          key: const Key('phone_share_tile'),
          contentPadding: const EdgeInsets.only(left: 20, right: 8),
          leading: Icon(computer ? Icons.computer : Icons.smartphone, color: context.primaryColor, size: 28),
          title: Text(
            computer ? t.computer_share_title : t.phone_share_title,
            style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500),
          ),
          subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => context.pushRoute(const PhoneShareRoute()),
        ),
        const Divider(height: 1, indent: 20, endIndent: 20),
      ],
    );
  }
}

/// Where and how a headset reaches the share
class _SharedCard extends ConsumerWidget {
  const _SharedCard({required this.state});

  final PhoneShareState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final label = context.textTheme.labelMedium?.copyWith(color: context.colorScheme.onSurfaceVariant);
    const monospace = TextStyle(fontFamily: 'monospace', fontFamilyFallback: ['Courier', 'RobotoMono']);
    final serviceName = state.serviceName;
    final username = state.username;
    final password = state.password;

    return Card(
      key: const Key('phone_share_card'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.phone_share_address, style: label),
            if (state.urls.isEmpty && state.status == PhoneShareStatus.on)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 12, bottom: 8),
                child: Text(
                  CurrentPlatform.isDesktop ? t.computer_share_no_network : t.phone_share_no_network,
                  style: TextStyle(color: context.colorScheme.error),
                ),
              ),
            for (final url in state.urls) _CopyRow(value: url, style: monospace.copyWith(fontSize: 16)),
            if (serviceName != null) _CopyRow(value: serviceName, icon: Icons.wifi_tethering_rounded),
            if (username != null) ...[
              const SizedBox(height: 8),
              Text(t.phone_share_username, style: label),
              _CopyRow(
                value: username,
                style: monospace.copyWith(fontSize: 22, fontWeight: FontWeight.w600),
              ),
            ],
            if (password != null) ...[
              const SizedBox(height: 8),
              Text(t.phone_share_password, style: label),
              _CopyRow(
                key: const Key('phone_share_password'),
                value: password,
                shown: formatPhoneSharePassword(password),
                style: monospace.copyWith(fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: 2),
              ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('phone_share_new_password'),
                onPressed: () => unawaited(ref.read(phoneShareProvider.notifier).newPassword()),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(t.phone_share_new_password),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// [shown] (else [value]) with a button that copies [value]
class _CopyRow extends StatelessWidget {
  const _CopyRow({super.key, required this.value, this.shown, this.style, this.icon});

  final String value;
  final String? shown;
  final TextStyle? style;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: context.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
        ],
        Expanded(child: SelectableText(shown ?? value, style: style)),
        IconButton(
          icon: const Icon(Icons.copy_rounded, size: 20),
          tooltip: t.copy_to_clipboard,
          onPressed: () async {
            final messenger = ScaffoldMessenger.maybeOf(context);
            final copied = t.copied_to_clipboard;
            await Clipboard.setData(ClipboardData(text: value));
            messenger?.showSnackBar(SnackBar(content: Text(copied)));
          },
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final shade = color ?? context.colorScheme.onSurface.withAlpha(180);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: shade),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: context.textTheme.bodyMedium?.copyWith(color: shade)),
          ),
        ],
      ),
    );
  }
}
