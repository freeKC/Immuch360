// The rules of the DJI link page, as a banner that cannot be dismissed. It is the first thing on the page in every
// state, including the state where this device cannot read a remote controller at all.

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';

class DjiLinkSafetyBanner extends StatelessWidget {
  const DjiLinkSafetyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final lines = [
      t.dji_link_safety_pilot,
      t.dji_link_safety_authority,
      t.dji_link_safety_no_command,
      t.dji_link_safety_rules,
      t.dji_link_safety_zones,
      t.dji_link_safety_bench,
    ];
    return Card(
      key: const Key('dji_link_safety'),
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      color: context.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: context.colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.dji_link_safety_title,
                    style: context.textTheme.titleMedium?.copyWith(
                      color: context.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  line,
                  style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onErrorContainer),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
