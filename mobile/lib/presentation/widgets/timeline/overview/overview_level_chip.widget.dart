// A short badge, "Months" or "Years", when the timeline enters one of them, gone after [kOverviewLevelChipDuration]

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/timeline_zoom.dart';

/// How long the badge stays
const kOverviewLevelChipDuration = Duration(milliseconds: 1200);

class OverviewLevelChip extends StatefulWidget {
  const OverviewLevelChip({super.key, required this.level});

  final TimelineZoomLevel level;

  @override
  State<OverviewLevelChip> createState() => _OverviewLevelChipState();
}

class _OverviewLevelChipState extends State<OverviewLevelChip> {
  Timer? _timer;
  var _visible = false;
  var _shown = TimelineZoomLevel.grid;

  @override
  void didUpdateWidget(covariant OverviewLevelChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.level == oldWidget.level) {
      return;
    }
    _timer?.cancel();
    if (widget.level == TimelineZoomLevel.grid) {
      _visible = false;
      return;
    }
    _shown = widget.level;
    _visible = true;
    _timer = Timer(kOverviewLevelChipDuration, () {
      if (mounted) {
        setState(() => _visible = false);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = switch (_shown) {
      TimelineZoomLevel.months => context.t.timeline_zoom_months,
      TimelineZoomLevel.years => context.t.timeline_zoom_years,
      TimelineZoomLevel.grid => null,
    };
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: label == null
            ? const SizedBox.shrink()
            : Semantics(
                liveRegion: _visible,
                child: Material(
                  elevation: 2,
                  color: context.colorScheme.secondaryContainer,
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    child: Text(
                      label,
                      key: const Key('timeline_zoom_level_chip'),
                      style: context.textTheme.labelLarge?.copyWith(color: context.colorScheme.onSecondaryContainer),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
