// The notice of the "This computer" settings while the secrets of this session are kept in memory only: Linux without
// a keyring that answers, or with one that refused them (lib/desktop/platform/linux_secret_storage.dart). The reason
// in full is in the Logs page.

import 'package:flutter/material.dart';
import 'package:immich_mobile/desktop/platform/linux_secret_storage.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';

class SessionSecretsNotice extends StatelessWidget {
  const SessionSecretsNotice({super.key, required this.reason});

  final SessionOnlySecrets reason;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ListTile(
      key: const Key('desktop_settings_session_secrets'),
      leading: Icon(Icons.key_off_outlined, color: context.colorScheme.error),
      title: Text(t.desktop_secrets_session_only_title),
      subtitle: Text(
        reason.keyringRefused
            ? t.desktop_secrets_session_only_keyring_refused
            : t.desktop_secrets_session_only_no_keyring,
      ),
    );
  }
}
