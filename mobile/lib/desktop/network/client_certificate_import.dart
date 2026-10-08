import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/network/certificate_files.dart';
import 'package:immich_mobile/platform/network_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';

/// "Import" of the client certificate on a computer, where NetworkApi.selectCertificate opens the system picker of a
/// phone: a PKCS #12 file chosen with the system's file dialog, its password asked with [prompt]'s texts (as the iOS
/// importer of NetworkApiImpl.swift asks it), then given to NetworkApi.addCertificate, which checks both. Ends with a
/// PlatformException whose code holds "cancel" when the user gives up, as the phone pickers do; any other error means
/// the file or the password was refused.
Future<void> importClientCertificate(
  BuildContext context,
  ClientCertPrompt prompt, {
  PickFileBytes pickFile = pickPkcs12File,
  NetworkApi? api,
}) async {
  final bytes = await pickFile();
  if (bytes == null || !context.mounted) {
    throw PlatformException(code: 'cancelled');
  }
  final password = await showDialog<String>(context: context, builder: (_) => _PasswordDialog(prompt));
  if (password == null) {
    throw PlatformException(code: 'cancelled');
  }
  await (api ?? networkApi).addCertificate(ClientCertData(data: bytes, password: password));
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog(this.prompt);

  final ClientCertPrompt prompt;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    final prompt = widget.prompt;
    return AlertDialog(
      title: Text(prompt.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(prompt.message),
          const SizedBox(height: 12),
          TextField(
            key: const Key('client_certificate_password'),
            controller: _controller,
            autofocus: true,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(labelText: prompt.title),
            onSubmitted: (_) => _confirm(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(prompt.cancel)),
        TextButton(onPressed: _confirm, child: Text(prompt.confirm)),
      ],
    );
  }
}
