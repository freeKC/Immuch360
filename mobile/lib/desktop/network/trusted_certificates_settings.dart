import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/desktop/network/certificate_files.dart';
import 'package:immich_mobile/desktop/network/trusted_certificates.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/datetime_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';

/// "Trusted certificates", a group of the "This computer" settings: the certificate authorities (or self signed
/// certificates) of the user's own servers, trusted by every HTTPS client of the app on top of the system's roots.
/// Each one shows its name, the end of its validity and its SHA-256 fingerprint, the value to compare with the
/// server's before trusting it.
class TrustedCertificatesSettings extends StatefulWidget {
  const TrustedCertificatesSettings({super.key, this.certificates, this.pickFile = pickCertificateFile});

  /// The app's list when null
  final TrustedCertificates? certificates;
  final PickFileBytes pickFile;

  @override
  State<TrustedCertificatesSettings> createState() => _TrustedCertificatesSettingsState();
}

class _TrustedCertificatesSettingsState extends State<TrustedCertificatesSettings> {
  static final _log = Logger('TrustedCertificatesSettings');

  TrustedCertificates get _certificates => widget.certificates ?? TrustedCertificates.instance;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _certificates.addListener(_changed);
  }

  @override
  void didUpdateWidget(TrustedCertificatesSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.certificates ?? TrustedCertificates.instance;
    if (previous != _certificates) {
      previous.removeListener(_changed);
      _certificates.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _certificates.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _add() async {
    setState(() => _busy = true);
    try {
      final bytes = await widget.pickFile();
      if (bytes == null) {
        return;
      }
      await _certificates.add(bytes);
    } catch (error) {
      // A file without a certificate, or one the TLS library refuses
      _log.warning('A trusted certificate was not added: $error');
      if (mounted) {
        context.showSnackBar(SnackBar(content: Text(context.t.desktop_trusted_certificates_invalid)));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _remove(TrustedCertificate certificate) async {
    try {
      await _certificates.remove(certificate);
    } catch (error) {
      _log.warning('A trusted certificate was not removed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final certificates = _certificates.certificates;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingGroupTitle(
          title: context.t.desktop_trusted_certificates,
          subtitle: context.t.desktop_trusted_certificates_subtitle,
          icon: Icons.verified_user_outlined,
        ),
        if (certificates.isEmpty)
          ListTile(
            key: const Key('desktop_trusted_certificates_empty'),
            title: Text(context.t.desktop_trusted_certificates_empty),
          ),
        for (final certificate in certificates)
          ListTile(
            key: ValueKey('desktop_trusted_certificate_${certificate.fingerprint}'),
            leading: const Icon(Icons.verified_outlined),
            title: Text(certificate.subject ?? certificate.displayFingerprint.substring(0, 23)),
            subtitle: Text(
              [
                if (certificate.notAfter case final notAfter?)
                  DateFormat.yMMMd(resolvedDateTimeLocale()).format(notAfter),
                certificate.displayFingerprint,
              ].join('\n'),
            ),
            isThreeLine: certificate.notAfter != null,
            trailing: IconButton(
              tooltip: context.t.remove,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _remove(certificate),
            ),
          ),
        ListTile(
          key: const Key('desktop_trusted_certificates_add'),
          leading: const Icon(Icons.add),
          title: Text(context.t.desktop_trusted_certificates_add),
          enabled: !_busy,
          onTap: _add,
        ),
      ],
    );
  }
}
