// The two lines a headset shows on the DJI link pages: in the EU open category, flying with a headset on needs an
// observer beside the pilot who keeps the drone in sight (Regulation (EU) 2019/947, Article 4 and UAS.OPEN.060(4), and
// EASA's guidance on FPV in the open category), and nothing on the headset reaches the drone. A TV shows the same two
// rules worded for a TV (p2/design-tv-2026-10-24.md, 7.1). On the Diagnostics page they always show; on the screens
// that watch the picture they come for five seconds and fade, back with a key or a tap (FreeKC's rule of 25 October,
// dji_live_transient.dart), the safety notice of the session having said them first.

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_latency.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_receive.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_video.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_transient.dart';

class DjiLinkObserverNote extends StatelessWidget {
  const DjiLinkObserverNote({super.key, this.tv = false, this.transient = false});

  /// The rules worded for a TV
  final bool tv;

  /// On a screen that watches the picture: shown five seconds, then gone until a key or a tap
  final bool transient;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final style = context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onErrorContainer);
    final card = Card(
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
                    tv ? t.dji_live_tv_observer : t.dji_link_observer_note,
                    key: const Key('dji_link_observer_note'),
                    style: style?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              tv ? t.dji_live_tv_watching : t.dji_link_observer_watching,
              key: const Key('dji_link_observer_watching'),
              style: style,
            ),
          ],
        ),
      ),
    );
    return transient ? DjiTransient(kind: tv, child: card) : card;
  }
}

/// Over the picture of the watch page of a headset: where the picture comes from, the red line once it stopped, "This
/// device cannot keep up", watching only and the observer note. Each line comes for five seconds when it appears or
/// changes kind and after a tap, then fades, and the plate shrinks with them (dji_live_transient.dart); an error that
/// needs an action stays, and so does the red line while no picture shows.
class DjiLinkReceiveStrip extends StatelessWidget {
  const DjiLinkReceiveStrip({super.key, required this.receiving});

  final DjiRelayReceiving receiving;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final small = context.textTheme.bodySmall;
    final stale = djiLinkStaleLine(t, receiving);
    final cannotKeepUp = djiLinkCannotKeepUpLine(t, receiving);
    final kind = djiRelayReceiveLine(receiving);
    const red = Color(0xFFFF6B6B);
    // Each line brings its own padding: the plate is gone when they all are
    Widget line(Widget child, {double top = 0, double bottom = 0}) =>
        Padding(padding: EdgeInsets.fromLTRB(8, top, 8, bottom), child: child);
    return DecoratedBox(
      key: const Key('dji_link_receive_strip'),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          DjiTransient(
            kind: kind,
            keep: kind.keeps,
            child: line(
              Text(
                djiRelayReceiveStateText(t, receiving),
                key: const Key('dji_link_receive_strip_state'),
                style: small?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
              ),
              top: 8,
            ),
          ),
          if (stale != null)
            DjiTransient(
              kind: 'stale',
              // The picture stopped for longer than the window shows it: the line says why it is black, and stays
              keep: (receiving.lastPictureAgoMs ?? djiLinkPictureTimeoutMs) >= djiLinkPictureTimeoutMs,
              child: line(
                Text(
                  stale,
                  key: const Key('dji_link_receive_strip_stale'),
                  style: small?.copyWith(color: red, fontWeight: FontWeight.w700),
                ),
                top: 2,
              ),
            ),
          if (cannotKeepUp != null)
            DjiTransient(
              kind: 'cannotKeepUp',
              child: line(
                Text(
                  cannotKeepUp,
                  key: const Key('dji_link_receive_strip_cannot_keep_up'),
                  style: small?.copyWith(color: red, fontWeight: FontWeight.w700),
                ),
                top: 2,
              ),
            ),
          DjiTransient(
            kind: 'watching',
            child: line(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.dji_link_observer_watching,
                    key: const Key('dji_link_receive_strip_watching'),
                    style: small?.copyWith(color: Colors.white),
                  ),
                  Text(
                    t.dji_link_observer_note,
                    key: const Key('dji_link_receive_strip_observer'),
                    style: small?.copyWith(color: red),
                  ),
                ],
              ),
              top: 2,
              bottom: 8,
            ),
          ),
        ],
      ),
    );
  }
}
