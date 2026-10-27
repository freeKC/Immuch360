// The installation of the AI components a feature needs, asked once (design-final 2026-10-26, sections 2.2, 3.5 and
// 5): each missing component with its name, its sizes and its licence (a link to its text), the promise (downloaded
// once, runs on this device and works offline afterwards, no photo leaves it), then Download, a bar per component and
// Cancel. Nothing is downloaded before the tap on Download. Shared by the computers (the conversion dialog, lot A5c)
// and the Meta Quest (before its first relief, lot A9b): AiInstallPanel is the body, which a dialog can hold, and
// showAiInstallSheet shows it as a bottom sheet and tells whether everything got installed.
//
// Also here, for the tile of the components: the licence link and its dialog (the licence copied at the
// installation, else the text the app keeps, and the notices of the libraries inside ONNX Runtime), and the text of
// each download failure.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_licences.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/open_url.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:logging/logging.dart';

final _log = Logger('AiInstallSheet');

/// The components of [components] that are not installed and intact
List<AiComponent> aiMissingComponents(AiComponentsService service, Iterable<AiComponent> components) => [
  for (final component in components)
    if (service.statusOf(component).state != AiComponentState.installed) component,
];

/// What a failed download tells the user; the detail goes to the log
String aiDownloadFailureText(Translations t, AiDownloadException error) => switch (error.failure) {
  AiDownloadFailure.damaged => t.ai_immersive_download_damaged,
  AiDownloadFailure.diskFull => t.ai_immersive_failed_disk_full,
  AiDownloadFailure.cancelled => t.ai_immersive_state_cancelled,
  AiDownloadFailure.notFound => t.ai_immersive_download_not_found,
  AiDownloadFailure.network => t.ai_immersive_download_network,
  AiDownloadFailure.writeFailed => t.ai_immersive_download_write_failed,
  AiDownloadFailure.incomplete ||
  AiDownloadFailure.insecureAddress => t.ai_immersive_download_failed(reason: error.failure.name),
};

/// "6.0 MiB to download, 16.5 MiB on disk", from the catalogue, the notices included
String aiComponentSizes(Translations t, AiComponent component) => t.ai_immersive_component_sizes(
  download: formatBytes(AiComponentsService.downloadBytesOf([component])),
  disk: formatBytes(AiComponentsService.diskBytesOf([component])),
);

/// Shows the install sheet for [components]; true when every one of them is installed when it closes
Future<bool> showAiInstallSheet(BuildContext context, List<AiComponent> components) async {
  final done = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: AiInstallPanel(components: components, onInstalled: () => Navigator.of(context).pop(true)),
      ),
    ),
  );
  return done ?? false;
}

/// See the top of this file. [components] are those the feature needs, in the order of aiComponentsFor (the runtime
/// first); those already installed are left out. [onInstalled] is called once all are installed, at once when none
/// is missing.
class AiInstallPanel extends ConsumerStatefulWidget {
  const AiInstallPanel({super.key, required this.components, this.onInstalled});

  final List<AiComponent> components;
  final VoidCallback? onInstalled;

  @override
  ConsumerState<AiInstallPanel> createState() => _AiInstallPanelState();
}

class _AiInstallPanelState extends ConsumerState<AiInstallPanel> {
  late final AiComponentsService _service = ref.read(aiComponentsServiceProvider);

  /// Fixed once the service has read its folder, so that a component stays in the list with its bar once installed
  List<AiComponent>? _missing;
  bool _running = false;
  bool _stopping = false;
  AiDownloadException? _failure;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMissing());
  }

  Future<void> _loadMissing() async {
    try {
      await _service.load();
    } catch (error, stack) {
      // Every component is then shown as missing, and the download says what is wrong
      _log.warning('the components folder could not be read', error, stack);
    }
    if (!mounted) {
      return;
    }
    final missing = aiMissingComponents(_service, widget.components);
    setState(() => _missing = missing);
    if (missing.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onInstalled?.call());
    }
  }

  Future<void> _download() async {
    final missing = _missing ?? const [];
    setState(() {
      _running = true;
      _stopping = false;
      _failure = null;
    });
    try {
      for (final component in missing) {
        if (_stopping) {
          return;
        }
        await _service.install(component);
      }
      if (mounted && !_stopping) {
        widget.onInstalled?.call();
      }
    } on AiDownloadException catch (error) {
      _log.warning('the components were not installed: $error');
      if (mounted) {
        setState(() => _failure = error.failure == AiDownloadFailure.cancelled ? null : error);
      }
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  void _cancel() {
    setState(() => _stopping = true);
    for (final component in _missing ?? const <AiComponent>[]) {
      _service.cancel(component);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final missing = _missing;
    if (missing == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final failure = _failure;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.ai_immersive_components, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              t.ai_immersive_install_prompt(size: formatBytes(AiComponentsService.downloadBytesOf(missing))),
              key: const Key('ai_install_prompt'),
            ),
            for (final component in missing) _InstallRow(component: component, status: _service.statusOf(component)),
            if (failure != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  aiDownloadFailureText(t, failure),
                  key: const Key('ai_install_failure'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: _running
                  ? TextButton(
                      key: const Key('ai_install_cancel'),
                      onPressed: _stopping ? null : _cancel,
                      child: Text(t.cancel),
                    )
                  : FilledButton(
                      key: const Key('ai_install_download'),
                      onPressed: missing.isEmpty ? null : () => unawaited(_download()),
                      child: Text(t.ai_immersive_download),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _InstallRow extends StatelessWidget {
  const _InstallRow({required this.component, required this.status});

  final AiComponent component;
  final AiComponentStatus status;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final downloading = status.state == AiComponentState.downloading;
    final total = status.total;
    final fraction = total == null || total == 0 ? null : (status.received / total).clamp(0.0, 1.0);
    return Padding(
      key: Key('ai_install_row_${component.id}'),
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(component.title, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(aiComponentSizes(t, component)),
          AiLicenceLink(component: component),
          if (downloading) ...[
            LinearProgressIndicator(value: fraction),
            Text(t.ai_immersive_downloading(name: component.title, percent: ((fraction ?? 0) * 100).floor())),
          ],
          if (status.state == AiComponentState.installed) const Icon(Icons.check_circle_outline, size: 18),
        ],
      ),
    );
  }
}

/// "Licence: MIT", which opens the licence of [component]
class AiLicenceLink extends StatelessWidget {
  const AiLicenceLink({super.key, required this.component});

  final AiComponent component;

  @override
  Widget build(BuildContext context) => TextButton(
    key: Key('ai_licence_${component.id}'),
    style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
    onPressed: () => unawaited(showAiLicenceDialog(context, component)),
    child: Text(context.t.ai_immersive_licence(licence: component.licence)),
  );
}

/// The licence of [component]: the copy written at its installation when there is one (what was installed, from
/// where, when), else the text the app keeps; with the notices of the libraries inside ONNX Runtime once downloaded,
/// and the page of the licence
Future<void> showAiLicenceDialog(BuildContext context, AiComponent component) async {
  final service = ProviderScope.containerOf(context, listen: false).read(aiComponentsServiceProvider);
  final copy = await service.licenceOf(component);
  final notices = await service.noticesOf(component);
  if (!context.mounted) {
    return;
  }
  final text = _readOr(
    copy,
    () => 'Licence: ${component.licence}, ${component.licenceUrl}\n\n${aiLicenceText(component)}',
  );
  await showDialog<void>(
    context: context,
    builder: (context) => _TextDialog(
      title: component.title,
      text: text,
      actions: [
        if (notices != null && notices.existsSync())
          TextButton(
            key: const Key('ai_licence_notices'),
            onPressed: () {
              final text = _readOr(notices, () => '');
              unawaited(
                showDialog<void>(
                  context: context,
                  builder: (context) => _TextDialog(title: component.title, text: text),
                ),
              );
            },
            child: Text(context.t.ai_immersive_licence_notices),
          ),
        TextButton(
          onPressed: () => unawaited(openUrl(context, Uri.parse(component.licenceUrl))),
          child: Text(context.t.open_in_browser),
        ),
      ],
    ),
  );
}

/// The text of [file], or [fallback] when there is none or it cannot be read
Future<String> _readOr(File file, String Function() fallback) async {
  if (!file.existsSync()) {
    return fallback();
  }
  try {
    return await file.readAsString();
  } on FileSystemException {
    return fallback();
  }
}

class _TextDialog extends StatelessWidget {
  const _TextDialog({required this.title, required this.text, this.actions = const []});

  final String title;
  final Future<String> text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(title),
    content: SizedBox(
      // A fixed width: the dialog measures its content, which a list cannot answer
      width: double.maxFinite,
      child: FutureBuilder<String>(
        future: text,
        builder: (context, snapshot) {
          final value = snapshot.data;
          if (value == null) {
            return const Center(child: CircularProgressIndicator());
          }
          // Line by line: the notices of ONNX Runtime are more than 300 KB of text
          final lines = value.split('\n');
          return Scrollbar(
            child: ListView.builder(
              key: const Key('ai_licence_text'),
              shrinkWrap: true,
              itemCount: lines.length,
              itemBuilder: (context, index) =>
                  Text(lines[index], style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
          );
        },
      ),
    ),
    actions: [
      ...actions,
      TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: Text(context.t.close)),
    ],
  );
}
