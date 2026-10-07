import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [url] like launchUrl, except in the remote control layout (Android TV): a TV has no web browser to speak of,
/// and Google Play asks that a TV app never launches one (criterion TV-WB). The address then shows in a dialog, to be
/// opened on a phone or a computer. True when something was launched.
///
/// [tvMode] is the remote control layout when the caller already knows it: [context] is then not read out of it,
/// and may be gone (a menu that closed) by the time a browser opens.
Future<bool> openUrl(
  BuildContext context,
  Uri url, {
  LaunchMode mode = LaunchMode.platformDefault,
  bool? tvMode,
}) async {
  if (!(tvMode ?? await _isTvMode(context))) {
    return launchUrl(url, mode: mode);
  }
  if (!context.mounted) {
    return false;
  }
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.t.tv_open_elsewhere_title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t.tv_open_elsewhere_body),
          const SizedBox(height: 12),
          SelectableText(url.toString(), style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
      actions: [
        TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: Text(context.t.close)),
      ],
    ),
  );
  return false;
}

/// The remote control layout, or, on the screen of a failed start that runs without providers, whether the device
/// is a TV
Future<bool> _isTvMode(BuildContext context) async {
  final UncontrolledProviderScope? scope = context.getInheritedWidgetOfExactType<UncontrolledProviderScope>();
  if (scope != null) {
    return scope.container.read(tvModeProvider);
  }
  return (await readTvDeviceInfo()).isTelevision;
}
