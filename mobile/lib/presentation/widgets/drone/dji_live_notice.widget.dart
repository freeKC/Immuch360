// The safety notice of the DJI live video (p2/design-ux-phone-2026-10-24.md, 3.2): once per run of the app, before the
// first picture, with the rules of the Diagnostics banner word for word. On a headset the observer rule and "Watching
// only" come first. The link starts behind it, so reading it costs no time; Back on it leaves the screen it covers.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// The notice was read in this run of the app: in memory only, so that it shows again after the app was closed
final djiLiveNoticeReadProvider = StateProvider<bool>((_) => false);

/// Shows the notice over the current screen; true once "I understand" was tapped, false when Back left it
Future<bool> showDjiLiveNotice(BuildContext context, {required bool headset}) async {
  final read = await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(fullscreenDialog: true, builder: (_) => DjiLiveNotice(headset: headset)),
  );
  return read ?? false;
}

class DjiLiveNotice extends StatelessWidget {
  const DjiLiveNotice({super.key, required this.headset});

  /// The observer rule and "Watching only" first
  final bool headset;

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
    ];
    return Scaffold(
      key: const Key('dji_live_notice'),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              children: [
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
                if (headset) ...[
                  Text(t.dji_link_observer_note, key: const Key('dji_live_notice_observer'), style: strong),
                  const SizedBox(height: 8),
                  Text(t.dji_link_observer_watching, key: const Key('dji_live_notice_watching'), style: strong),
                  const SizedBox(height: 8),
                ],
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(line, style: body),
                  ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    key: const Key('dji_live_notice_ok'),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(t.dji_live_notice_ok),
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
