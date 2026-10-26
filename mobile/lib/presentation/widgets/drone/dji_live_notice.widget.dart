// The safety notice of the DJI live video (p2/design-ux-phone-2026-10-24.md, 3.2): once per run of the app, before the
// first picture, with the rules of the Diagnostics banner word for word. On a headset the observer rule and "Watching
// only" come first, on a TV the same two rules worded for a TV (p2/design-tv-2026-10-24.md, 7.1). The link starts
// behind it, so reading it costs no time; Back on it leaves the screen it covers. On a TV, and on a phone in the remote
// control layout, the text is one stop of the remote that the arrows scroll, and "I understand" comes after its last
// line.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_scroll_area.widget.dart';

/// The notice was read in this run of the app: in memory only, so that it shows again after the app was closed
final djiLiveNoticeReadProvider = StateProvider<bool>((_) => false);

/// Shows the notice over the current screen; true once "I understand" was tapped, false when Back left it. With
/// [alert], the obstacle ring may show: its "information only" line follows the existing ones. On a TV ([tv]) the
/// two rules come first worded for a TV. In the remote control layout ([remote]) the text scrolls with the arrows, as
/// on a TV.
Future<bool> showDjiLiveNotice(
  BuildContext context, {
  required bool headset,
  bool tv = false,
  bool remote = false,
  bool alert = false,
}) async {
  final read = await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (_) => DjiLiveNotice(headset: headset, tv: tv, remote: remote, alert: alert),
    ),
  );
  return read ?? false;
}

class DjiLiveNotice extends StatelessWidget {
  const DjiLiveNotice({super.key, required this.headset, this.tv = false, this.remote = false, this.alert = false});

  /// The observer rule and "Watching only" first
  final bool headset;

  /// Those two rules worded for a TV
  final bool tv;

  /// The remote control layout: the text is one stop that the arrows scroll, as on a TV
  final bool remote;

  /// The obstacle ring may show: it says it never steers or stops the drone
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final body = context.textTheme.bodyMedium;
    final strong = body?.copyWith(fontWeight: FontWeight.w700, color: context.colorScheme.error);
    final lines = [
      t.dji_link_safety_pilot,
      t.dji_link_safety_authority,
      t.dji_link_safety_no_command,
      t.dji_link_safety_rules,
      t.dji_link_safety_zones,
      t.dji_link_safety_bench,
      t.dji_link_flight_view_fly_note,
      if (alert) t.dji_live_obstacle_info_only,
    ];
    final children = [
      Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: context.colorScheme.error, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              t.dji_link_safety_title,
              style: context.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (tv) ...[
        Text(t.dji_live_tv_observer, key: const Key('dji_live_notice_observer'), style: strong),
        const SizedBox(height: 8),
        Text(t.dji_live_tv_watching, key: const Key('dji_live_notice_watching'), style: strong),
        const SizedBox(height: 8),
      ] else if (headset) ...[
        Text(t.dji_link_observer_note, key: const Key('dji_live_notice_observer'), style: strong),
        const SizedBox(height: 8),
        Text(t.dji_link_observer_watching, key: const Key('dji_live_notice_watching'), style: strong),
        const SizedBox(height: 8),
      ],
      for (final (index, line) in lines.indexed)
        Padding(
          key: index == lines.length - 1 ? const Key('dji_live_notice_last') : null,
          padding: const EdgeInsets.only(top: 8),
          child: Text(line, style: body),
        ),
    ];
    const padding = EdgeInsets.fromLTRB(24, 16, 24, 8);
    // On a TV the arrows scroll the text, which has no stop of its own: a remote without channel keys reaches its
    // last lines, then "I understand". Built whole, so that its last line is there to bring into view.
    final text = tv || remote
        ? RemoteScrollArea(
            key: const Key('dji_live_notice_text'),
            autofocus: true,
            builder: (_, controller) => SingleChildScrollView(
              controller: controller,
              padding: padding,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
            ),
          )
        : ListView(padding: padding, children: children);
    return Scaffold(
      key: const Key('dji_live_notice'),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              children: [
                Expanded(child: text),
                // Always in sight, whatever the height of the window: the notice scrolls above it
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      key: const Key('dji_live_notice_ok'),
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text(t.dji_live_notice_ok),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
