// The two lines a headset always shows on the DJI link page, never dismissible: in the EU open category, flying with
// a headset on needs an observer beside the pilot who keeps the drone in sight (Regulation (EU) 2019/947, Article 4
// and UAS.OPEN.060(4), and EASA's guidance on FPV in the open category), and nothing on the headset reaches the drone.

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_latency.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_receive.widget.dart';

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

/// Over the picture of the full screen route of a device that receives from a phone: where the picture comes from, the
/// red line once it stopped, watching only and the observer note. Nothing hides it there, as nothing hides the strip of
/// the flight view.
class DjiLinkReceiveStrip extends StatelessWidget {
  const DjiLinkReceiveStrip({super.key, required this.receiving});

  final DjiRelayReceiving receiving;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final small = context.textTheme.bodySmall;
    final stale = djiLinkStaleLine(t, receiving);
    return DecoratedBox(
      key: const Key('dji_link_receive_strip'),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              djiRelayReceiveStateText(t, receiving),
              style: small?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
            ),
            if (stale != null)
              Text(
                stale,
                key: const Key('dji_link_receive_strip_stale'),
                style: small?.copyWith(color: const Color(0xFFFF6B6B), fontWeight: FontWeight.w700),
              ),
            Text(t.dji_link_observer_watching, style: small?.copyWith(color: Colors.white)),
            Text(t.dji_link_observer_note, style: small?.copyWith(color: const Color(0xFFFF6B6B))),
          ],
        ),
      ),
    );
  }
}
