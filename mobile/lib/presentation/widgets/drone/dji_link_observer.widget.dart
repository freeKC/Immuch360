// The two lines a headset always shows on the DJI link page, never dismissible: in the EU open category, flying with
// a headset on needs an observer beside the pilot who keeps the drone in sight (Regulation (EU) 2019/947, Article 4
// and UAS.OPEN.060(4), and EASA's guidance on FPV in the open category), and nothing on the headset reaches the drone.

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';

class DjiLinkObserverNote extends StatelessWidget {
  const DjiLinkObserverNote({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final style = context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onErrorContainer);
    return Card(
      key: const Key('dji_link_observer'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      color: context.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.visibility_rounded, color: context.colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.dji_link_observer_note,
                    key: const Key('dji_link_observer_note'),
                    style: style?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(t.dji_link_observer_watching, key: const Key('dji_link_observer_watching'), style: style),
          ],
        ),
      ),
    );
  }
}
