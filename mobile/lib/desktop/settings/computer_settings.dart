// The "This computer" section of the settings, on the computers only (settings.page.dart): what a computer needs that a
// phone has from its system. Each group comes from the part of the app it sets: the folders of the library (the
// folders page), the download folder (files), the network adapter for discovery and sharing, the trusted certificates
// (network), and on Linux the notice of secrets kept for the session only (platform/linux_secret_storage.dart).
//
// The section is drawn under one focus ring (design 4.7): Material only tints a focused tile, which is hard to follow
// on a computer screen, so the control that has the keyboard focus gets the ring of the remote control layout, the
// same for every group whatever widget it is made of.

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/desktop/files/download_folder_tile.dart';
import 'package:immich_mobile/desktop/network/network_choice.dart';
import 'package:immich_mobile/desktop/network/trusted_certificates_settings.dart';
import 'package:immich_mobile/desktop/platform/linux_secret_storage.dart';
import 'package:immich_mobile/desktop/settings/session_secrets_notice.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_ui/immich_ui.dart';

class ComputerSettings extends StatelessWidget {
  const ComputerSettings({super.key, this.sessionSecrets});

  /// Why the secrets of this session are kept in memory only, when they are: the store installed on Linux by default
  final ValueListenable<SessionOnlySecrets?>? sessionSecrets;

  @override
  Widget build(BuildContext context) {
    final secrets = sessionSecrets ?? LinuxSecretStorage.installed?.sessionOnly;
    if (secrets == null) {
      return _build(context, null);
    }
    return ValueListenableBuilder(valueListenable: secrets, builder: (context, reason, _) => _build(context, reason));
  }

  Widget _build(BuildContext context, SessionOnlySecrets? sessionOnly) {
    final t = context.t;
    return TvFocusRing(
      child: SettingsSubPageScaffold(
        settings: [
          if (sessionOnly != null) SessionSecretsNotice(reason: sessionOnly),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingGroupTitle(title: t.folders, icon: Icons.folder_outlined),
              ListTile(
                key: const Key('desktop_settings_folders'),
                leading: const Icon(Icons.photo_library_outlined),
                title: Text(t.desktop_folders_title),
                subtitle: Text(t.desktop_folders_choose_title),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.pushRoute(const FoldersRoute()),
              ),
              const DownloadFolderTile(),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingGroupTitle(title: t.networking_settings, icon: Icons.lan_outlined),
              const DesktopNetworkAdapterTile(),
            ],
          ),
          const TrustedCertificatesSettings(),
        ],
      ),
    );
  }
}
