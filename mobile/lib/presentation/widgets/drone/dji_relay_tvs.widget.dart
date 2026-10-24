// "TVs" in Send, on the phone (p2/design-tv-2026-10-24.md, 2.4): the TVs added on this phone, each with the name it
// gave once it connected, "Watching" while it does, and Remove; "Add a TV" scans the code its Drone page shows, or the
// phone's keyboard types it. Eight at most, kept on this phone only. A TV only watches: nothing it does reaches the
// remote or the drone.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/dji_watch_code.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/platform/qr_scan_api.g.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';
import 'package:immich_mobile/providers/pairing/phone_pairing.provider.dart';

/// What a scanned or typed TV code gave, in words; null when the TV was added or was in the list already
String? djiRelayAddScreenText(Translations t, DjiRelayAddScreen outcome) => switch (outcome) {
  DjiRelayAddScreen.added || DjiRelayAddScreen.already => null,
  DjiRelayAddScreen.full => t.dji_live_send_tv_full,
  DjiRelayAddScreen.invalid => t.dji_live_send_tv_not_watch_code,
};

class DjiRelayTvsSection extends ConsumerStatefulWidget {
  const DjiRelayTvsSection({super.key});

  @override
  ConsumerState<DjiRelayTvsSection> createState() => _DjiRelayTvsSectionState();
}

class _DjiRelayTvsSectionState extends ConsumerState<DjiRelayTvsSection> {
  /// What the last scan or typed code gave, when it added nothing
  String? _message;

  @override
  void initState() {
    super.initState();
    // After the first frame, which a change of the providers must not reach
    unawaited(Future.microtask(() => ref.read(djiRelayProvider.notifier).loadScreens()));
  }

  Future<void> _scan() async {
    final t = context.t;
    setState(() => _message = null);
    final QrScanResult result;
    try {
      result = await ref.read(qrScanApiProvider).scan(t.dji_live_send_tv_scan, t.cancel);
    } catch (_) {
      _say(t.pairing_err_no_camera);
      return;
    }
    if (!mounted) {
      return;
    }
    switch (result.status) {
      case QrScanStatus.scanned:
        // The text holds the TV's code: it goes to the parser only, never to a log
        await _scanned(t, result.text ?? '');
      case QrScanStatus.permissionDenied:
        _say(t.pairing_err_camera_denied);
      case QrScanStatus.noCamera:
        _say(t.pairing_err_no_camera);
      case QrScanStatus.cancelled || QrScanStatus.failed:
        break;
    }
  }

  Future<void> _scanned(Translations t, String text) async {
    switch (parseDjiWatchQrText(text)) {
      case DjiWatchCode(:final code):
        await _add(t, code);
      case DjiWatchSignInCode():
        _say(t.dji_live_send_tv_sign_in_code);
      case DjiWatchNotACode():
        _say(t.dji_live_send_tv_not_watch_code);
    }
  }

  Future<void> _add(Translations t, String code) async {
    final outcome = await ref.read(djiRelayProvider.notifier).addScreen(code);
    _say(djiRelayAddScreenText(t, outcome));
  }

  Future<void> _type() async {
    final t = context.t;
    setState(() => _message = null);
    final code = await showDialog<String>(context: context, builder: (_) => const DjiRelayTvCodeDialog());
    if (code != null && mounted) {
      await _add(t, code);
    }
  }

  void _say(String? message) {
    if (mounted) {
      setState(() => _message = message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final screens = ref.watch(djiRelayProvider.select((relay) => relay.screens));
    final rows = ref.watch(djiLinkProvider.select((state) => state.snapshot?.relaySending?.headsets));
    final watching = <String>{for (final row in rows ?? const <DjiRelayHeadsetRow>[]) ?row.screenCodeId};
    final small = context.textTheme.bodySmall;
    final message = _message;
    return Column(
      key: const Key('dji_live_send_tvs'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.dji_live_send_tv_title, style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        if (screens.isEmpty)
          Text(t.dji_live_send_tv_none, key: const Key('dji_live_send_tv_none'), style: small)
        else
          for (final screen in screens)
            ListTile(
              key: ValueKey('dji_live_send_tv_${screen.id}'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.tv_rounded),
              title: Text(screen.name ?? t.dji_live_send_tv_unnamed),
              subtitle: watching.contains(screen.id) ? Text(t.dji_live_send_tv_watching) : null,
              trailing: TextButton(
                key: ValueKey('dji_live_send_tv_remove_${screen.id}'),
                onPressed: () => unawaited(ref.read(djiRelayProvider.notifier).removeScreen(screen.id)),
                child: Text(t.dji_live_send_tv_remove),
              ),
            ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.tonalIcon(
              key: const Key('dji_live_send_tv_add'),
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: Text(t.dji_live_send_tv_add),
              onPressed: () => unawaited(_scan()),
            ),
            TextButton(
              key: const Key('dji_live_send_tv_type'),
              onPressed: () => unawaited(_type()),
              child: Text(t.dji_live_send_tv_type),
            ),
          ],
        ),
        if (message != null)
          Text(
            message,
            key: const Key('dji_live_send_tv_message'),
            style: small?.copyWith(color: context.colorScheme.error),
          ),
      ],
    );
  }
}

/// The code a TV's Drone page shows, typed with the phone's keyboard: the pairing alphabet, normalised; "Add a TV"
/// closes the dialog with the code, Cancel with nothing
class DjiRelayTvCodeDialog extends StatefulWidget {
  const DjiRelayTvCodeDialog({super.key});

  @override
  State<DjiRelayTvCodeDialog> createState() => _DjiRelayTvCodeDialogState();
}

class _DjiRelayTvCodeDialogState extends State<DjiRelayTvCodeDialog> {
  final _code = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _submit() {
    final code = normalizePairingCode(_code.text);
    if (code == null) {
      setState(() => _error = context.t.dji_live_send_tv_code_invalid);
      return;
    }
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final error = _error;
    return AlertDialog(
      key: const Key('dji_live_send_tv_dialog'),
      title: Text(t.dji_live_send_tv_type),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('dji_live_send_tv_code'),
            controller: _code,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [LengthLimitingTextInputFormatter(14)],
            style: const TextStyle(fontFamily: 'GoogleSansCode', fontSize: 22, letterSpacing: 2),
            decoration: const InputDecoration(hintText: 'K7M2Q 9XRTH', border: OutlineInputBorder()),
            onSubmitted: (_) => _submit(),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error,
                key: const Key('dji_live_send_tv_code_error'),
                style: context.textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.cancel)),
        FilledButton(
          key: const Key('dji_live_send_tv_dialog_add'),
          onPressed: _submit,
          child: Text(t.dji_live_send_tv_add),
        ),
      ],
    );
  }
}
