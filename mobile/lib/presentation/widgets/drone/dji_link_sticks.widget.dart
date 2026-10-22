// The sticks of a gamepad or of the headset controllers, drawn. Reading them is all this does: nothing leaves the
// device, the send path is off in this build, and the reasons the sticks are held at neutral are shown as they are.

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_texts.dart';

class DjiLinkSticksDisplay extends StatelessWidget {
  const DjiLinkSticksDisplay({super.key, required this.sticks});

  final DjiLinkSticks sticks;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final nothingRead = sticks.sampleAgeMs == null;
    return Column(
      key: const Key('dji_link_sticks'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.dji_link_sticks_note, style: context.textTheme.bodySmall),
        const SizedBox(height: 8),
        if (nothingRead)
          Text(t.dji_link_sticks_none, style: context.textTheme.bodySmall)
        else
          Row(
            children: [
              _Pad(horizontal: sticks.yaw, vertical: sticks.throttle, label: t.dji_link_sticks_yaw_throttle),
              const SizedBox(width: 16),
              _Pad(horizontal: sticks.roll, vertical: sticks.pitch, label: t.dji_link_sticks_roll_pitch),
            ],
          ),
        const SizedBox(height: 8),
        if (sticks.reasons.isNotEmpty)
          Text(
            t.dji_link_sticks_neutral(reasons: sticks.reasons.map((r) => djiLinkSignalText(t, r)).join(', ')),
            style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error),
          ),
      ],
    );
  }
}

class _Pad extends StatelessWidget {
  const _Pad({required this.horizontal, required this.vertical, required this.label});

  final double horizontal;
  final double vertical;
  final String label;

  @override
  Widget build(BuildContext context) {
    const size = 88.0;
    return Column(
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            border: Border.all(color: context.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(
            children: [
              Align(
                alignment: Alignment(horizontal.clamp(-1.0, 1.0), -vertical.clamp(-1.0, 1.0)),
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(color: context.primaryColor, shape: BoxShape.circle),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: context.textTheme.labelSmall),
      ],
    );
  }
}
