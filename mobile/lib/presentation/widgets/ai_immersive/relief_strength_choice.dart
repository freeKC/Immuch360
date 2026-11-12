// "Relief strength": Subtle, Normal or Strong (release 46, lot I1), the same choice in the "Make 3D (AI)" dialog of the
// computers and in the AI settings of the Meta Quest, and the "Relief: Strong" line of the details of a 3D photo. The
// values are in relief_strength.dart.

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/ai_immersive/relief_strength.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// "Subtle", "Normal" or "Strong"
String reliefStrengthText(Translations t, ReliefStrength strength) => switch (strength) {
  ReliefStrength.subtle => t.ai_immersive_relief_strength_subtle,
  ReliefStrength.normal => t.ai_immersive_relief_strength_normal,
  ReliefStrength.strong => t.ai_immersive_relief_strength_strong,
};

/// "Relief: Strong", the line of the details of a 3D photo made with that strength
String reliefStrengthInfo(Translations t, ReliefStrength strength) =>
    t.ai_immersive_relief_strength_info(strength: reliefStrengthText(t, strength));

/// The key of the segment of [strength], for the tests
Key reliefStrengthSegmentKey(ReliefStrength strength) => Key('ai_relief_strength_${strength.name}');

/// "Relief strength", what it does, and the three strengths side by side; greyed when [onChanged] is null
class ReliefStrengthChoice extends StatelessWidget {
  const ReliefStrengthChoice({super.key, required this.value, required this.onChanged});

  final ReliefStrength value;
  final ValueChanged<ReliefStrength>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final changed = onChanged;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(t.ai_immersive_relief_strength, style: context.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(t.ai_immersive_relief_strength_subtitle, style: context.textTheme.bodySmall),
        const SizedBox(height: 8),
        SegmentedButton<ReliefStrength>(
          key: const Key('ai_relief_strength'),
          showSelectedIcon: false,
          segments: [
            for (final strength in ReliefStrength.values)
              ButtonSegment(
                value: strength,
                label: Text(reliefStrengthText(t, strength), key: reliefStrengthSegmentKey(strength)),
              ),
          ],
          selected: {value},
          onSelectionChanged: changed == null ? null : (selected) => changed(selected.first),
        ),
      ],
    );
  }
}
