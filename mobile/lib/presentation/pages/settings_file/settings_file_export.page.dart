// Settings, Settings file, Export the settings (issue 16): the level of the file, the passphrase of an accounts level
// file, then Share or Save to a file. Nothing leaves the device until the user shares or saves it.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/settings_file/settings_file.dart';
import 'package:immich_mobile/domain/services/settings_file/settings_file_crypto.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/settings_file/settings_file.provider.dart';
import 'package:immich_mobile/providers/settings_file/settings_file_io.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';

final _log = Logger('SettingsFileExport');

/// The app that writes the file, for its header
final settingsFileOriginProvider = FutureProvider<SettingsFileOrigin>((ref) async {
  var version = '';
  var build = '';
  try {
    final info = await PackageInfo.fromPlatform().timeout(const Duration(seconds: 2));
    version = info.version;
    build = info.buildNumber;
  } catch (error) {
    _log.fine('No package info for the settings file: $error');
  }
  return SettingsFileOrigin(appVersion: version, build: build, platform: Platform.operatingSystem);
});

enum _Action { share, save }

class SettingsFileExportPage extends HookConsumerWidget {
  const SettingsFileExportPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final io = ref.watch(settingsFileIoProvider);
    final level = useState(SettingsFileLevel.settings);
    final passphrase = useTextEditingController();
    final confirm = useTextEditingController();
    final working = useState(false);
    final error = useState<String?>(null);
    useListenable(passphrase);
    useListenable(confirm);
    final shareKey = useMemoized(GlobalKey.new);

    String? passphraseProblem() {
      if (level.value != SettingsFileLevel.accounts) {
        return null;
      }
      if (passphrase.text.length < settingsFileMinPassphraseLength) {
        return context.t.settings_file_passphrase_too_short(count: settingsFileMinPassphraseLength);
      }
      if (passphrase.text != confirm.text) {
        return context.t.settings_file_passphrase_mismatch;
      }
      return null;
    }

    final problem = passphraseProblem();
    final ready = problem == null && !working.value;

    Future<void> run(_Action action) async {
      working.value = true;
      error.value = null;
      final t = context.t;
      final messenger = ScaffoldMessenger.maybeOf(context);
      final box = shareKey.currentContext?.findRenderObject() as RenderBox?;
      final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
      try {
        final text = await ref
            .read(settingsFileServiceProvider)
            .buildFile(
              level: level.value,
              origin: await ref.read(settingsFileOriginProvider.future),
              passphrase: level.value == SettingsFileLevel.accounts ? passphrase.text : null,
            );
        final name = SettingsFile.fileName(DateTime.now());
        if (action == _Action.share) {
          await io.share(text, name, origin: origin);
        } else if (await io.save(text, name)) {
          messenger?.showSnackBar(SnackBar(content: Text(t.settings_file_saved)));
        }
      } on SettingsFileIoException catch (e) {
        _log.warning('The settings file could not be written: $e');
        error.value = e.error == SettingsFileIoError.noPicker
            ? t.settings_file_no_picker
            : t.scaffold_body_error_occurred;
      } catch (e) {
        _log.warning('The settings file could not be made: $e');
        error.value = t.scaffold_body_error_occurred;
      } finally {
        if (context.mounted) {
          working.value = false;
        }
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(context.t.settings_file_export_title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            RadioGroup<SettingsFileLevel>(
              groupValue: level.value,
              onChanged: (value) {
                if (value != null && !working.value) {
                  level.value = value;
                }
              },
              child: Column(
                children: [
                  RadioListTile<SettingsFileLevel>(
                    key: const Key('settings_file_level_settings'),
                    value: SettingsFileLevel.settings,
                    title: Text(context.t.settings_file_level_settings),
                    subtitle: Text(context.t.settings_file_level_settings_description),
                  ),
                  RadioListTile<SettingsFileLevel>(
                    key: const Key('settings_file_level_accounts'),
                    value: SettingsFileLevel.accounts,
                    title: Text(context.t.settings_file_level_accounts),
                    subtitle: Text(context.t.settings_file_level_accounts_description),
                  ),
                ],
              ),
            ),
            if (level.value == SettingsFileLevel.accounts)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    TextField(
                      key: const Key('settings_file_passphrase'),
                      controller: passphrase,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: context.t.settings_file_passphrase,
                        helperText: context.t.settings_file_passphrase_hint(count: settingsFileMinPassphraseLength),
                        helperMaxLines: 4,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    TextField(
                      key: const Key('settings_file_passphrase_confirm'),
                      controller: confirm,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: context.t.settings_file_passphrase_confirm,
                        errorText: passphrase.text.isEmpty && confirm.text.isEmpty ? null : problem,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Text(context.t.settings_file_stays_here, style: context.textTheme.bodyMedium),
                  Text(
                    context.t.settings_file_device_only_note,
                    style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (error.value != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(error.value!, style: TextStyle(color: context.colorScheme.error)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.end,
                children: [
                  if (working.value)
                    const SizedBox.square(dimension: 36, child: Center(child: CircularProgressIndicator())),
                  if (io.canSave)
                    OutlinedButton.icon(
                      key: const Key('settings_file_save'),
                      icon: const Icon(Icons.save_alt_rounded),
                      label: Text(context.t.settings_file_save),
                      onPressed: ready ? () => unawaited(run(_Action.save)) : null,
                    ),
                  if (io.canShare)
                    FilledButton.icon(
                      key: shareKey,
                      icon: const Icon(Icons.share_rounded),
                      label: Text(context.t.settings_file_share),
                      onPressed: ready ? () => unawaited(run(_Action.share)) : null,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
