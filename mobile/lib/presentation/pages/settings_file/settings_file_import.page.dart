// Restore settings from a file (issue 16), from the welcome screen or Settings, or when a settings file is shared to
// the app: the file, its passphrase when it holds accounts, a preview of what it holds, merge or replace, then a
// report of what was restored and what was not. Nothing is written before the user taps Restore.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/settings_file/settings_file.dart';
import 'package:immich_mobile/domain/services/settings_file/settings_file_crypto.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/datetime_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/settings_file/settings_file.provider.dart';
import 'package:immich_mobile/providers/settings_file/settings_file_io.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:logging/logging.dart';

final _log = Logger('SettingsFileImport');

/// Opens the import page above [context]; [text] is a file already read (shared to the app)
Future<void> openSettingsFileImport(BuildContext context, {String? text, bool fromWelcome = false}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsFileImportPage(initialText: text, fromWelcome: fromWelcome),
      ),
    );

class SettingsFileImportPage extends HookConsumerWidget {
  const SettingsFileImportPage({super.key, this.initialText, this.fromWelcome = false});

  /// The text of a file shared to the app, read already
  final String? initialText;

  /// Opened from the welcome screen: no session yet
  final bool fromWelcome;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final io = ref.watch(settingsFileIoProvider);
    final file = useState<SettingsFile?>(null);
    final content = useState<SettingsFileContent?>(null);
    final report = useState<SettingsFileReport?>(null);
    final mode = useState(SettingsFileRestoreMode.merge);
    // What went wrong: an exception, told in words at build time (the first effect runs before the page can read its
    // translations)
    final error = useState<Object?>(null);
    final working = useState(false);
    final passphrase = useTextEditingController();

    String messageOf(Object e) {
      final t = context.t;
      return switch (e) {
        SettingsFileException(error: SettingsFileError.notASettingsFile) => t.settings_file_not_a_settings_file,
        SettingsFileException(error: SettingsFileError.newerVersion) => t.settings_file_newer_version,
        SettingsFileException(error: SettingsFileError.damaged) => t.settings_file_damaged,
        SettingsFileException(error: SettingsFileError.wrongPassphrase) => t.settings_file_wrong_passphrase,
        SettingsFileIoException(error: SettingsFileIoError.noPicker) => t.settings_file_no_picker,
        SettingsFileIoException(error: SettingsFileIoError.tooLarge) => t.settings_file_too_large,
        SettingsFileIoException() => t.settings_file_read_failed,
        _ => t.scaffold_body_error_occurred,
      };
    }

    void read(String text) {
      error.value = null;
      content.value = null;
      report.value = null;
      try {
        final parsed = SettingsFile.parse(text);
        file.value = parsed;
        content.value = parsed.content;
      } catch (e) {
        _log.info('A file that does not read as a settings file: $e');
        file.value = null;
        error.value = e;
      }
    }

    useEffect(() {
      final text = initialText;
      if (text != null) {
        read(text);
      }
      return null;
    }, const []);

    Future<void> pick() async {
      error.value = null;
      try {
        final text = await io.pick();
        if (text != null) {
          read(text);
        }
      } catch (e) {
        _log.warning('No settings file picked: $e');
        error.value = e;
      }
    }

    Future<void> open() async {
      final sealed = file.value;
      if (sealed == null) {
        return;
      }
      working.value = true;
      error.value = null;
      try {
        content.value = await openSettingsFile(sealed, passphrase: passphrase.text);
      } catch (e) {
        error.value = e;
      } finally {
        if (context.mounted) {
          working.value = false;
        }
      }
    }

    Future<void> restore() async {
      final chosen = content.value;
      if (chosen == null) {
        return;
      }
      working.value = true;
      error.value = null;
      try {
        report.value = await ref.read(settingsFileServiceProvider).restore(chosen, mode.value);
      } catch (e) {
        _log.warning('The settings file could not be restored: $e');
        error.value = e;
      } finally {
        if (context.mounted) {
          working.value = false;
        }
      }
    }

    void finish() {
      final done = report.value;
      if (done?.signIn?.result == SettingsFileSignInResult.refused) {
        // The session of the file ended on the server: its sign in form, the address filled in, above the welcome page
        // that its Back leads to, as the start of the app does for a refused token
        unawaited(context.router.replaceAll([const WelcomeRoute(), const LoginRoute()]));
        return;
      }
      if (done?.accountRestored ?? false) {
        // The start screen resumes the session restored, as at any start of the app; an expired one leads to the sign
        // in form, the server filled in
        unawaited(context.router.replaceAll([SplashScreenRoute()]));
        return;
      }
      final router = context.router;
      Navigator.of(context).maybePop();
      final serverRestored = done?.items.any(
        (item) => item.section == SettingsFileSection.server && item.outcome == SettingsFileOutcome.restored,
      );
      if (fromWelcome && (serverRestored ?? false)) {
        // The address of the file's server fills in the sign in form
        unawaited(router.push(const LoginRoute()));
      }
    }

    final List<Widget> children;
    final Widget? action;
    if (report.value != null) {
      children = [SettingsFileReportView(report: report.value!)];
      action = FilledButton(
        key: const Key('settings_file_finish'),
        onPressed: finish,
        child: Text(switch (report.value!) {
          SettingsFileReport(signIn: SettingsFileSignIn(result: SettingsFileSignInResult.refused)) =>
            context.t.settings_file_sign_in_again,
          SettingsFileReport(accountRestored: true) => context.t.settings_file_continue,
          _ => context.t.settings_file_done,
        }),
      );
    } else if (content.value != null) {
      children = [
        SettingsFilePreview(
          file: file.value!,
          content: content.value!,
          signedIn: ref.read(settingsFileServiceProvider).isSignedIn,
          mode: mode.value,
          onMode: working.value ? null : (value) => mode.value = value,
        ),
      ];
      action = FilledButton(
        key: const Key('settings_file_restore'),
        onPressed: working.value ? null : () => unawaited(restore()),
        child: Text(context.t.settings_file_restore),
      );
    } else if (file.value?.isEncrypted ?? false) {
      children = [
        Text(context.t.settings_file_enter_passphrase, style: context.textTheme.bodyLarge),
        const SizedBox(height: 16),
        TextField(
          key: const Key('settings_file_open_passphrase'),
          controller: passphrase,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          autofocus: true,
          onSubmitted: (_) => unawaited(open()),
          decoration: InputDecoration(
            labelText: context.t.settings_file_passphrase,
            border: const OutlineInputBorder(),
          ),
        ),
      ];
      action = FilledButton(
        key: const Key('settings_file_open'),
        onPressed: working.value ? null : () => unawaited(open()),
        child: Text(context.t.settings_file_open),
      );
    } else {
      children = [
        Text(context.t.settings_file_import_subtitle, style: context.textTheme.bodyLarge),
        if (!io.canPick) ...[
          const SizedBox(height: 16),
          Text(context.t.settings_file_ios_open_hint, style: context.textTheme.bodyMedium),
        ],
      ];
      action = io.canPick
          ? FilledButton.icon(
              key: const Key('settings_file_choose'),
              icon: const Icon(Icons.file_open_outlined),
              onPressed: working.value ? null : () => unawaited(pick()),
              label: Text(context.t.settings_file_choose_file),
            )
          : null;
    }

    return Scaffold(
      appBar: AppBar(title: Text(context.t.settings_file_import_title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ...children,
            if (error.value != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  messageOf(error.value!),
                  key: const Key('settings_file_error'),
                  style: TextStyle(color: context.colorScheme.error),
                ),
              ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 12,
              children: [
                if (working.value) const SizedBox.square(dimension: 32, child: CircularProgressIndicator()),
                ?action,
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _typeName(Object? type) => switch (type) {
  'smb' => 'SMB',
  'webdav' => 'WebDAV',
  'dlna' => 'DLNA',
  'plex' => 'Plex',
  'tapo' => 'Tapo',
  final String other => other,
  _ => '',
};

/// What a file holds, before anything is written, with the choice of merge or replace
class SettingsFilePreview extends StatelessWidget {
  const SettingsFilePreview({
    super.key,
    required this.file,
    required this.content,
    required this.signedIn,
    required this.mode,
    required this.onMode,
  });

  final SettingsFile file;
  final SettingsFileContent content;

  /// This install is signed in to a server: the file's account is not used
  final bool signedIn;
  final SettingsFileRestoreMode mode;
  final ValueChanged<SettingsFileRestoreMode>? onMode;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final muted = context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant);
    final date = DateFormat.yMMMd(resolvedDateTimeLocale()).add_jm().format(file.createdAt.toLocal());
    final server = content.server;
    final settingsCount = content.settings.length + content.store.length;
    final title = context.textTheme.titleSmall;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t.settings_file_made_by(
            version: file.origin.appVersion.isEmpty ? '?' : file.origin.appVersion,
            platform: file.origin.platform.isEmpty ? '?' : file.origin.platform,
            date: date,
          ),
          style: muted,
        ),
        const SizedBox(height: 4),
        Text(
          file.level == SettingsFileLevel.accounts ? t.settings_file_level_accounts : t.settings_file_level_settings,
          style: context.textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        if (server != null) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.dns_outlined),
            title: Text(t.settings_file_server(url: server.url)),
            subtitle: server.hasAccount
                ? Text(
                    signedIn ? t.settings_file_account_signed_in : t.settings_file_account_shared_session,
                    style: signedIn ? TextStyle(color: context.colorScheme.error) : null,
                  )
                : null,
            trailing: server.hasAccount
                ? Tooltip(message: t.settings_file_account_included, child: const Icon(Icons.key_rounded))
                : null,
          ),
        ],
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.tune_rounded),
          title: Text(t.settings_file_settings_count(count: settingsCount)),
        ),
        if (content.sources.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(t.settings_file_sources, style: title),
          ),
          for (final source in content.sources)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.lan_outlined),
              title: Text(switch (source['name']) {
                final String name => name,
                _ => '?',
              }),
              subtitle: Text(
                [
                  _typeName(source['type']),
                  if (source['host'] case final String host when host.isNotEmpty) host,
                  if (!(content.sourceSecrets[source['id']]?.isEmpty ?? true)) t.settings_file_password_included,
                ].join(' · '),
              ),
            ),
        ],
        if (content.backupAlbums.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(t.settings_file_backup_albums, style: title),
          ),
          for (final album in content.backupAlbums)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                album.choice == SettingsFileAlbumChoice.selected ? Icons.cloud_upload_outlined : Icons.block_rounded,
              ),
              title: Text(album.name),
              subtitle: Text(
                album.choice == SettingsFileAlbumChoice.selected
                    ? t.settings_file_album_selected
                    : t.settings_file_album_excluded,
              ),
            ),
        ],
        const Divider(height: 24),
        RadioGroup<SettingsFileRestoreMode>(
          groupValue: mode,
          onChanged: (value) {
            if (value != null) {
              onMode?.call(value);
            }
          },
          child: Column(
            children: [
              RadioListTile<SettingsFileRestoreMode>(
                key: const Key('settings_file_merge'),
                value: SettingsFileRestoreMode.merge,
                enabled: onMode != null,
                contentPadding: EdgeInsets.zero,
                title: Text(t.settings_file_merge),
                subtitle: Text(t.settings_file_merge_description),
              ),
              RadioListTile<SettingsFileRestoreMode>(
                key: const Key('settings_file_replace'),
                value: SettingsFileRestoreMode.replace,
                enabled: onMode != null,
                contentPadding: EdgeInsets.zero,
                title: Text(t.settings_file_replace),
                subtitle: Text(t.settings_file_replace_description),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// What was restored and what was not, with the reason
class SettingsFileReportView extends StatelessWidget {
  const SettingsFileReportView({super.key, required this.report});

  final SettingsFileReport report;

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    String labelOf(SettingsFileReportItem item) => switch (item.section) {
      SettingsFileSection.account => t.settings_file_report_account(url: item.label),
      SettingsFileSection.server => t.settings_file_report_server(url: item.label),
      SettingsFileSection.pairing => t.settings_file_report_pairing,
      SettingsFileSection.settings when int.tryParse(item.label) != null => t.settings_file_report_settings(
        count: int.parse(item.label),
      ),
      SettingsFileSection.backupAlbums when item.outcome == SettingsFileOutcome.waiting =>
        t.settings_file_report_waiting_albums(count: int.tryParse(item.label) ?? 0),
      _ => item.label,
    };

    String reasonOf(SettingsFileSkipReason? reason) => switch (reason) {
      SettingsFileSkipReason.signedIn => t.settings_file_reason_signed_in,
      SettingsFileSkipReason.otherServer => t.settings_file_reason_other_server,
      SettingsFileSkipReason.alreadyHere => t.settings_file_reason_already_here,
      SettingsFileSkipReason.unknownToThisBuild => t.settings_file_reason_unknown,
      SettingsFileSkipReason.unreadable => t.settings_file_reason_unreadable,
      SettingsFileSkipReason.notOnThisDevice => t.settings_file_reason_not_on_device,
      SettingsFileSkipReason.sessionRefused => t.settings_file_reason_session_refused,
      null => '',
    };

    final signIn = report.signIn;

    final restored = [...report.where(SettingsFileOutcome.restored), ...report.where(SettingsFileOutcome.waiting)];
    final skipped = report.where(SettingsFileOutcome.skipped).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (signIn != null) ...[SettingsFileSignInView(signIn: signIn), const SizedBox(height: 12)],
        Text(t.settings_file_restored_title, style: context.textTheme.titleMedium),
        for (final item in restored)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              item.outcome == SettingsFileOutcome.waiting ? Icons.schedule_rounded : Icons.check_circle_outline,
              color: item.outcome == SettingsFileOutcome.waiting ? null : context.colorScheme.primary,
            ),
            title: Text(labelOf(item)),
          ),
        if (skipped.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(t.settings_file_not_restored, style: context.textTheme.titleMedium),
          for (final item in skipped)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.remove_circle_outline),
              title: Text(labelOf(item)),
              subtitle: Text(reasonOf(item.reason)),
            ),
        ],
      ],
    );
  }
}

/// What the server said of the session the file put in place: signed in as its user, or why not
class SettingsFileSignInView extends StatelessWidget {
  const SettingsFileSignInView({super.key, required this.signIn});

  final SettingsFileSignIn signIn;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final scheme = context.colorScheme;
    final (icon, color, title, subtitle) = switch (signIn.result) {
      SettingsFileSignInResult.signedIn => (
        Icons.verified_user_outlined,
        scheme.primary,
        t.settings_file_signed_in_as(name: signIn.name ?? '', email: signIn.email ?? ''),
        null,
      ),
      SettingsFileSignInResult.unreachable => (
        Icons.cloud_off_outlined,
        scheme.onSurfaceVariant,
        t.settings_file_server_unreachable,
        t.settings_file_server_unreachable_description,
      ),
      SettingsFileSignInResult.refused => (
        Icons.lock_reset_rounded,
        scheme.error,
        t.settings_file_session_refused,
        t.settings_file_session_refused_description,
      ),
    };
    return Card(
      key: const Key('settings_file_sign_in'),
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
      ),
    );
  }
}
