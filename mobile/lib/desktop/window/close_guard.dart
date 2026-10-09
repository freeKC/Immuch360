// The close guard of the window on a computer (design 1.8). Closing the window quits the app, which stops the uploads
// under way (they go on at the next start) and the share of the computer on the network. The window tells the app of
// every close instead of closing (DesktopWindow.setPreventClose, set once by DesktopShell): the app asks first when
// one of those runs, and closes at once otherwise. Deciding at the moment of the close, rather than switching the
// prevention on and off with the uploads, keeps the providers below untouched until then: one that was never created
// has nothing running.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
import 'package:immich_mobile/providers/backup/asset_upload_progress.provider.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// What closing the window would stop
enum DesktopCloseReason {
  /// The backup, an upload chosen by hand, or an upload from a network share
  uploads,

  /// "Share this computer on the network"
  computerShare,
}

/// Whether the backup is sending a file: a failed one stays in the list until the next run, and stops nothing
bool _backupSends(BackupState state) => state.uploadItems.values.any((item) => item.isFailed != true);

/// What closing the window would stop now, read when the window is asked to close
final desktopCloseReasonsProvider = Provider<Set<DesktopCloseReason> Function()>((ref) {
  bool runs<T>(ProviderListenable<T> provider, bool Function(T) running) => running(ref.read(provider));
  return () => {
    if ((ref.exists(backupProvider) && runs(backupProvider, _backupSends)) ||
        (ref.exists(manualUploadCancelTokenProvider) &&
            runs(manualUploadCancelTokenProvider, (token) => token != null)) ||
        (ref.exists(networkUploadProvider) && runs(networkUploadProvider, (state) => state.isRunning)))
      DesktopCloseReason.uploads,
    if (ref.exists(phoneShareProvider) && runs(phoneShareProvider, (state) => state.isEnabled))
      DesktopCloseReason.computerShare,
  };
});

/// The navigator the close dialog shows in: the root one of the app, above the shell's own context
final desktopNavigatorKeyProvider = Provider<GlobalKey<NavigatorState>>(
  (ref) => ref.watch(appRouterProvider).navigatorKey,
);

/// Asks whether to quit while [reasons] run: true to quit. Cancel has the focus, so that Enter never quits by surprise.
Future<bool> confirmDesktopClose(BuildContext context, Set<DesktopCloseReason> reasons) async {
  final quit = await showDialog<bool>(
    context: context,
    builder: (context) => DesktopCloseDialog(reasons: reasons),
  );
  return quit ?? false;
}

/// Under the focus ring of the remote control layout, as the "This computer" settings: Cancel and Quit are reached
/// with Tab, and Material only tints a focused button (design 4.7)
class DesktopCloseDialog extends StatelessWidget {
  const DesktopCloseDialog({super.key, required this.reasons});

  final Set<DesktopCloseReason> reasons;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return TvFocusRing(
      child: AlertDialog(
        title: Text(t.desktop_close_title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            if (reasons.contains(DesktopCloseReason.uploads)) Text(t.desktop_close_uploads_running),
            if (reasons.contains(DesktopCloseReason.computerShare)) Text(t.desktop_close_share_running),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('desktop_close_cancel'),
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.cancel),
          ),
          TextButton(
            key: const Key('desktop_close_quit'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.desktop_close_quit),
          ),
        ],
      ),
    );
  }
}
