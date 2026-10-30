import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/presentation/widgets/timeline/constants.dart';
import 'package:immich_mobile/presentation/widgets/timeline/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:intl/intl.dart' hide TextDirection;

part 'scrubber.widget.freezed.dart';

/// A widget that will display a BoxScrollView with a ScrollThumb that can be dragged
/// for quick navigation of the BoxScrollView.
class Scrubber extends ConsumerStatefulWidget {
  /// The view that will be scrolled with the scroll thumb
  final CustomScrollView child;

  /// The segments of the timeline
  final List<Segment> layoutSegments;

  final double timelineHeight;

  final double topPadding;

  final double bottomPadding;

  final double? monthSegmentSnappingOffset;

  final bool snapToMonth;

  /// Whether an app bar is present, affects coordinate calculations
  final bool hasAppBar;

  /// The label says the year alone: the timeline shows one block a year
  final bool yearLabels;

  Scrubber({
    super.key,
    required this.layoutSegments,
    required this.timelineHeight,
    this.topPadding = 0,
    this.bottomPadding = 0,
    this.monthSegmentSnappingOffset,
    this.snapToMonth = true,
    this.hasAppBar = true,
    this.yearLabels = false,
    required this.child,
  }) : assert(child.scrollDirection == Axis.vertical);

  @override
  ConsumerState createState() => ScrubberState();
}

/// The label under the finger: the month and the year ("Oct 2024"), the year alone when the timeline shows years
@visibleForTesting
DateFormat scrubberLabelFormat({required bool years}) => years ? DateFormat.y() : DateFormat.yMMM();

/// The thumb slows down once the finger stays still on it ([kScrubberSlowStillDistance]) for [kScrubberSlowHold]
const kScrubberSlowHold = Duration(milliseconds: 300);
const kScrubberSlowStillDistance = 4.0;

/// In slow mode the finger moves some [kScrubberSlowDpPerMonth] dp a month, at most [kScrubberMaxSlowFactor] times
/// slower than the thumb; no slow mode when that is less than [kScrubberMinSlowFactor] times
const kScrubberSlowDpPerMonth = 16.0;
const kScrubberMaxSlowFactor = 16.0;
const kScrubberMinSlowFactor = 2.0;

/// How many times slower the thumb follows the finger in slow mode: the whole library maps to the height of the
/// scrubber, [monthCount] months in [scrubberHeight] dp (240 months on 600 dp: 2.5 dp a month, a millimetre skips
/// months); slow, a month takes some 16 dp of finger
@visibleForTesting
double scrubberSlowFactor({required int monthCount, required double scrubberHeight}) {
  if (scrubberHeight <= 0 || monthCount <= 0) {
    return 1;
  }
  return (monthCount * kScrubberSlowDpPerMonth / scrubberHeight).clamp(1.0, kScrubberMaxSlowFactor);
}

/// Whether the scrubber has a slow mode at [factor]: not for a library that already fits
@visibleForTesting
bool scrubberHasSlowMode(double factor) => factor >= kScrubberMinSlowFactor;

/// The position of the thumb in slow mode: from where it was when the mode began ([anchor], the finger then at
/// [anchorFinger]), the finger's move divided by [factor], kept on the scrubber
@visibleForTesting
double scrubberSlowPosition({
  required double anchor,
  required double anchorFinger,
  required double finger,
  required double factor,
  required double scrubberHeight,
}) => (anchor + (finger - anchorFinger) / math.max(1.0, factor)).clamp(0.0, math.max(0.0, scrubberHeight));

List<_Segment> _buildSegments({
  required List<Segment> layoutSegments,
  required double timelineHeight,
  bool yearLabels = false,
}) {
  const double offsetThreshold = 40.0;

  final segments = <_Segment>[];
  if (layoutSegments.isEmpty || layoutSegments.first.bucket is! TimeBucket) {
    return [];
  }

  final formatter = scrubberLabelFormat(years: yearLabels);
  DateTime? lastDate;
  double lastOffset = -offsetThreshold;
  for (final layoutSegment in layoutSegments) {
    final scrollPercentage = layoutSegment.startOffset / layoutSegments.last.endOffset;
    final startOffset = scrollPercentage * timelineHeight;

    final date = (layoutSegment.bucket as TimeBucket).date;
    final label = formatter.format(date);

    final showSegment = lastOffset + offsetThreshold <= startOffset && (lastDate == null || date.year != lastDate.year);

    segments.add(_Segment(date: date, startOffset: startOffset, scrollLabel: label, showSegment: showSegment));
    lastDate = date;
    if (showSegment) {
      lastOffset = startOffset;
    }
  }

  return segments;
}

class ScrubberState extends ConsumerState<Scrubber> with TickerProviderStateMixin {
  String? _lastLabel;
  double _thumbTopOffset = 0.0;
  bool _isDragging = false;
  List<_Segment> _segments = [];
  int _monthCount = 0;

  late AnimationController _thumbAnimationController;
  Timer? _fadeOutTimer;
  late Animation<double> _thumbAnimation;

  late AnimationController _labelAnimationController;
  late Animation<double> _labelAnimation;

  /// The label shows during a fast fling too, until it ends
  bool _flingLabel = false;

  /// The finger on the thumb, and the slow mode it may start by staying still
  int? _thumbPointer;
  double _fingerY = 0;
  double _stillY = 0;
  Timer? _slowTimer;
  bool _slow = false;
  double _slowAnchor = 0;
  double _slowAnchorFinger = 0;
  double? _lastDragPosition;

  double get _scrubberHeight => widget.timelineHeight - widget.topPadding - widget.bottomPadding;

  late ScrollController _scrollController;

  double get _currentOffset {
    if (_scrollController.hasClients != true) {
      return 0.0;
    }

    return _scrollController.offset * _scrubberHeight / _scrollController.position.maxScrollExtent;
  }

  @override
  void initState() {
    super.initState();
    _isDragging = false;
    _segments = _buildSegments(
      layoutSegments: widget.layoutSegments,
      timelineHeight: _scrubberHeight,
      yearLabels: widget.yearLabels,
    );
    _thumbAnimationController = AnimationController(vsync: this, duration: kTimelineScrubberFadeInDuration);
    _thumbAnimation = CurvedAnimation(parent: _thumbAnimationController, curve: Curves.fastEaseInToSlowEaseOut);
    _labelAnimationController = AnimationController(vsync: this, duration: kTimelineScrubberFadeInDuration);
    _monthCount = getMonthCount();

    _labelAnimation = CurvedAnimation(parent: _labelAnimationController, curve: Curves.fastOutSlowIn);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scrollController = PrimaryScrollController.of(context);
  }

  @override
  void didUpdateWidget(covariant Scrubber oldWidget) {
    super.didUpdateWidget(oldWidget);

    // The months and the years bring other segments, which may end at the same offset by chance
    if (oldWidget.layoutSegments.lastOrNull?.endOffset != widget.layoutSegments.lastOrNull?.endOffset ||
        oldWidget.layoutSegments.length != widget.layoutSegments.length ||
        oldWidget.yearLabels != widget.yearLabels) {
      _segments = _buildSegments(
        layoutSegments: widget.layoutSegments,
        timelineHeight: _scrubberHeight,
        yearLabels: widget.yearLabels,
      );
      _monthCount = getMonthCount();
    }
  }

  @override
  void dispose() {
    _thumbAnimationController.dispose();
    _labelAnimationController.dispose();
    _fadeOutTimer?.cancel();
    _slowTimer?.cancel();
    super.dispose();
  }

  void _resetThumbTimer() {
    _fadeOutTimer?.cancel();
    _fadeOutTimer = Timer(kTimelineScrubberFadeOutDuration, () {
      unawaited(_thumbAnimationController.reverse());
      _fadeOutTimer = null;
    });
  }

  int getMonthCount() {
    return _segments.map((e) => "${e.date.month}_${e.date.year}").toSet().length;
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (_isDragging) {
      // If the user is dragging the thumb, we don't want to update the position
      return false;
    }

    if (notification is ScrollStartNotification || notification is ScrollUpdateNotification) {
      ref.read(timelineStateProvider.notifier).setScrolling(true);
    } else if (notification is ScrollEndNotification) {
      ref.read(timelineStateProvider.notifier).setScrolling(false);
    }

    setState(() {
      if (notification is ScrollUpdateNotification) {
        _thumbTopOffset = _currentOffset;
        // A fast fling shows the label until it ends: where the list is going; a slow scroll by the finger does not
        final fling =
            notification.depth == 0 &&
            _scrollController.hasClients &&
            _scrollController.position.recommendDeferredLoading(context);
        if (fling) {
          _flingLabel = true;
          if (_labelAnimationController.status != AnimationStatus.forward &&
              _labelAnimationController.status != AnimationStatus.completed) {
            unawaited(_labelAnimationController.forward());
          }
        } else if (!_flingLabel && _labelAnimation.status != AnimationStatus.reverse) {
          unawaited(_labelAnimationController.reverse());
        }
        if (_thumbAnimationController.status != AnimationStatus.forward) {
          unawaited(_thumbAnimationController.forward());
        }
      } else if (notification is ScrollEndNotification && _flingLabel) {
        _flingLabel = false;
        unawaited(_labelAnimationController.reverse());
      }
      _resetThumbTimer();
    });

    return false;
  }

  void _onDragStart(DragStartDetails _) {
    setState(() {
      _isDragging = true;
      _flingLabel = false;
      unawaited(_labelAnimationController.forward());
      _fadeOutTimer?.cancel();
      _lastLabel = null;
    });
  }

  double get _slowFactor => scrubberSlowFactor(monthCount: _monthCount, scrubberHeight: _scrubberHeight);

  void _onThumbPointerDown(PointerDownEvent event) {
    if (_thumbPointer != null) {
      return;
    }
    _thumbPointer = event.pointer;
    _fingerY = event.position.dy;
    _stillY = _fingerY;
    _lastDragPosition = null;
    _restartSlowTimer();
  }

  void _onThumbPointerMove(PointerMoveEvent event) {
    if (event.pointer != _thumbPointer) {
      return;
    }
    _fingerY = event.position.dy;
    if (!_slow && (_fingerY - _stillY).abs() >= kScrubberSlowStillDistance) {
      _stillY = _fingerY;
      _restartSlowTimer();
    }
  }

  void _onThumbPointerEnd(PointerEvent event) {
    if (event.pointer != _thumbPointer) {
      return;
    }
    _thumbPointer = null;
    _slowTimer?.cancel();
    final wasSlow = _slow;
    _slow = false;
    if (wasSlow && !_isDragging) {
      // Held still and let go without a drag: the label the slow mode showed goes
      unawaited(_labelAnimationController.reverse());
      _resetThumbTimer();
    }
    if (wasSlow && mounted) {
      setState(() {});
    }
  }

  void _restartSlowTimer() {
    _slowTimer?.cancel();
    if (!scrubberHasSlowMode(_slowFactor)) {
      return;
    }
    _slowTimer = Timer(kScrubberSlowHold, _enterSlowMode);
  }

  /// The finger stayed still on the thumb: from here the thumb follows it [_slowFactor] times slower, until it lets go
  void _enterSlowMode() {
    if (!mounted || _thumbPointer == null || _slow) {
      return;
    }
    ref.read(hapticFeedbackProvider.notifier).mediumImpact();
    setState(() {
      _slow = true;
      _slowAnchor = _lastDragPosition ?? _thumbTopOffset;
      _slowAnchorFinger = _fingerY;
      _fadeOutTimer?.cancel();
      unawaited(_labelAnimationController.forward());
      if (_thumbAnimationController.status != AnimationStatus.forward) {
        unawaited(_thumbAnimationController.forward());
      }
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_isDragging) {
      return;
    }

    if (_scrubberHeight <= 0) {
      return;
    }

    if (_thumbAnimationController.status != AnimationStatus.forward) {
      unawaited(_thumbAnimationController.forward());
    }

    final dragPosition = _slow
        ? scrubberSlowPosition(
            anchor: _slowAnchor,
            anchorFinger: _slowAnchorFinger,
            finger: details.globalPosition.dy,
            factor: _slowFactor,
            scrubberHeight: _scrubberHeight,
          )
        : _calculateDragPosition(details);
    _lastDragPosition = dragPosition;
    final nearestMonthSegment = _findNearestMonthSegment(dragPosition);

    if (nearestMonthSegment != null) {
      final label = nearestMonthSegment.scrollLabel;
      if (_lastLabel != label) {
        ref.read(hapticFeedbackProvider.notifier).selectionClick();
        _lastLabel = label;
      }
    }

    if (_monthCount < kMinMonthsToEnableScrubberSnap || !widget.snapToMonth) {
      // If there are less than kMinMonthsToEnableScrubberSnap months, we don't need to snap to segments
      setState(() {
        _thumbTopOffset = dragPosition;
        _scrollController.jumpTo((dragPosition / _scrubberHeight) * _scrollController.position.maxScrollExtent);
      });
    } else if (nearestMonthSegment != null) {
      _snapToSegment(nearestMonthSegment);
    }
  }

  /// Calculate the drag position relative to the scrubber area
  ///
  /// This method converts the global drag coordinates from the gesture detector
  /// into a position relative to the scrubber's active area (excluding padding).
  ///
  /// The scrubber has padding at the top and bottom, so we need to:
  /// 1. Calculate the actual draggable area (timelineHeight - topPadding - bottomPadding)
  /// 2. Convert the global Y position to a position within this draggable area
  /// 3. Clamp the result to ensure it stays within bounds (0 to dragAreaHeight)
  ///
  /// Example:
  /// - If timelineHeight = 800, topPadding = 50, bottomPadding = 50
  /// - Then dragAreaHeight = 700 (the actual scrubber area)
  /// - If user drags to global Y position that's 100 pixels from the top
  /// - The relative position would be 100 - 50 = 50 (50 pixels into the scrubber area)
  double _calculateDragPosition(DragUpdateDetails details) {
    if (widget.hasAppBar) {
      final dragAreaTop = widget.topPadding;
      final dragAreaBottom = widget.timelineHeight - widget.bottomPadding;
      final dragAreaHeight = dragAreaBottom - dragAreaTop;

      final relativePosition = details.globalPosition.dy - dragAreaTop;

      // Make sure the position stays within the scrubber's bounds
      return relativePosition.clamp(0.0, dragAreaHeight);
    }

    // Get the local position relative to the gesture detector
    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox != null) {
      final localPosition = renderBox.globalToLocal(details.globalPosition);
      return localPosition.dy.clamp(0.0, _scrubberHeight);
    }

    // Fallback to current logic if render box is not available
    final dragAreaTop = widget.topPadding;
    final relativePosition = details.globalPosition.dy - dragAreaTop;
    return relativePosition.clamp(0.0, _scrubberHeight);
  }

  /// Find the segment closest to the given position
  _Segment? _findNearestMonthSegment(double position) {
    _Segment? nearestSegment;
    double minDistance = double.infinity;

    for (final segment in _segments) {
      final distance = (segment.startOffset - position).abs();
      if (distance < minDistance) {
        minDistance = distance;
        nearestSegment = segment;
      }
    }

    return nearestSegment;
  }

  /// Snap the scrubber thumb and scroll view to the given segment
  void _snapToSegment(_Segment segment) {
    setState(() {
      _thumbTopOffset = segment.startOffset;

      final layoutSegmentIndex = _findLayoutSegmentIndex(segment);

      if (layoutSegmentIndex >= 0) {
        _scrollToLayoutSegment(layoutSegmentIndex);
      }
    });
  }

  int _findLayoutSegmentIndex(_Segment segment) {
    return widget.layoutSegments.indexWhere((layoutSegment) {
      final bucket = layoutSegment.bucket as TimeBucket;
      return bucket.date.year == segment.date.year && bucket.date.month == segment.date.month;
    });
  }

  void _scrollToLayoutSegment(int layoutSegmentIndex) {
    final layoutSegment = widget.layoutSegments[layoutSegmentIndex];
    final maxScrollExtent = _scrollController.position.maxScrollExtent;
    final viewportHeight = _scrollController.position.viewportDimension;

    final targetScrollOffset = layoutSegment.startOffset;
    final centeredOffset = targetScrollOffset - (viewportHeight / 4) + 100 + (widget.monthSegmentSnappingOffset ?? 0.0);

    _scrollController.jumpTo(centeredOffset.clamp(0.0, maxScrollExtent));
  }

  void _onDragEnd(DragEndDetails _) {
    unawaited(_labelAnimationController.reverse());
    setState(() {
      _isDragging = false;
      _lastDragPosition = null;
    });

    _resetThumbTimer();
  }

  @override
  Widget build(BuildContext ctx) {
    Text? label;
    if (_scrollController.hasClients == true) {
      // Cache to avoid multiple calls to [_currentOffset]
      final scrollOffset = _currentOffset;
      final labelText =
          _segments.lastWhereOrNull((segment) => segment.startOffset <= scrollOffset)?.scrollLabel ??
          _segments.firstOrNull?.scrollLabel;
      label = labelText != null
          ? Text(
              labelText,
              style: ctx.textTheme.bodyLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
            )
          : null;
    }

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: Stack(
        children: [
          RepaintBoundary(child: widget.child),
          // Scroll Segments - wrapped in RepaintBoundary for better performance
          RepaintBoundary(
            child: _SegmentsLayer(
              key: ValueKey('segments_${_isDragging}_${_segments.length}'),
              segments: _segments,
              topPadding: widget.topPadding,
              isDragging: _isDragging,
            ),
          ),
          if (_scrollController.hasClients && _scrollController.position.maxScrollExtent > 0)
            PositionedDirectional(
              top: _thumbTopOffset + widget.topPadding,
              end: 0,
              child: RepaintBoundary(
                // The finger on the thumb, held still or not, for the slow mode
                child: Listener(
                  onPointerDown: _onThumbPointerDown,
                  onPointerMove: _onThumbPointerMove,
                  onPointerUp: _onThumbPointerEnd,
                  onPointerCancel: _onThumbPointerEnd,
                  child: RawGestureDetector(
                    gestures: {
                      _ThumbDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<_ThumbDragGestureRecognizer>(
                        _ThumbDragGestureRecognizer.new,
                        (recognizer) => recognizer
                          ..onStart = _onDragStart
                          ..onUpdate = _onDragUpdate
                          ..onEnd = _onDragEnd,
                      ),
                    },
                    child: _Scrubber(
                      thumbAnimation: _thumbAnimation,
                      labelAnimation: _labelAnimation,
                      label: label,
                      slow: _slow,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SegmentsLayer extends StatelessWidget {
  final List<_Segment> segments;
  final double topPadding;
  final bool isDragging;

  const _SegmentsLayer({super.key, required this.segments, required this.topPadding, required this.isDragging});

  @override
  Widget build(BuildContext context) {
    return Visibility(
      visible: isDragging,
      child: Stack(
        children: segments
            .where((segment) => segment.showSegment)
            .map(
              (segment) => PositionedDirectional(
                key: ValueKey('segment_${segment.date.millisecondsSinceEpoch}'),
                top: topPadding + segment.startOffset,
                end: 100,
                child: RepaintBoundary(child: _SegmentWidget(segment)),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _SegmentWidget extends StatelessWidget {
  final _Segment _segment;

  const _SegmentWidget(this._segment);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        margin: const EdgeInsets.only(right: 36.0),
        child: Material(
          color: context.colorScheme.surface,
          borderRadius: const BorderRadius.all(Radius.circular(16.0)),
          child: Container(
            constraints: const BoxConstraints(maxHeight: 28),
            padding: const EdgeInsets.symmetric(horizontal: 10.0),
            alignment: Alignment.center,
            child: Text(
              _segment.date.year.toString(),
              style: context.textTheme.labelMedium?.copyWith(fontFamily: "GoogleSansCode", fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScrollLabel extends StatelessWidget {
  final Text label;
  final Color backgroundColor;
  final Animation<double> animation;
  final bool slow;

  const _ScrollLabel({required this.label, required this.backgroundColor, required this.animation, this.slow = false});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: FadeTransition(
        opacity: animation,
        child: Container(
          margin: const EdgeInsets.only(right: 12.0),
          child: Material(
            elevation: 4.0,
            color: backgroundColor,
            borderRadius: const BorderRadius.all(Radius.circular(16.0)),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 28),
              padding: const EdgeInsets.symmetric(horizontal: 10.0),
              alignment: Alignment.center,
              child: slow
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // The thumb follows the finger slowly
                        const Icon(
                          Icons.slow_motion_video_rounded,
                          key: kScrubberSlowIconKey,
                          size: 16,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 6),
                        label,
                      ],
                    )
                  : label,
            ),
          ),
        ),
      ),
    );
  }
}

/// The icon the label shows in slow mode
const kScrubberSlowIconKey = Key('scrubber_slow_icon');

/// The drag of the thumb, which wins as soon as the finger touches it. A finger held still on the thumb waits for the
/// slow mode ([kScrubberSlowHold]); a plain drag would win only once the finger moved, and after 500 ms the long press
/// of the drag selection (TimelineDragRegion) won instead and the thumb stayed frozen until the finger let go.
class _ThumbDragGestureRecognizer extends VerticalDragGestureRecognizer {
  _ThumbDragGestureRecognizer();

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolvePointer(event.pointer, GestureDisposition.accepted);
  }
}

class _Scrubber extends StatelessWidget {
  final Text? label;
  final Animation<double> thumbAnimation;
  final Animation<double> labelAnimation;
  final bool slow;

  const _Scrubber({this.label, required this.thumbAnimation, required this.labelAnimation, this.slow = false});

  @override
  Widget build(BuildContext context) {
    final backgroundColor = context.isDarkTheme
        ? context.colorScheme.primary.darken(amount: .5)
        : context.colorScheme.primary;

    return _SlideFadeTransition(
      animation: thumbAnimation,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (label != null)
            _ScrollLabel(label: label!, backgroundColor: backgroundColor, animation: labelAnimation, slow: slow),
          _CircularThumb(backgroundColor),
        ],
      ),
    );
  }
}

class _CircularThumb extends StatelessWidget {
  final Color backgroundColor;

  const _CircularThumb(this.backgroundColor);

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: const _ArrowPainter(Colors.white),
      child: Material(
        elevation: 4.0,
        color: backgroundColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(kScrubberThumbHeight),
          bottomLeft: Radius.circular(kScrubberThumbHeight),
          topRight: Radius.circular(4.0),
          bottomRight: Radius.circular(4.0),
        ),
        child: Container(
          constraints: BoxConstraints.tight(const Size(kScrubberThumbHeight * 0.6, kScrubberThumbHeight)),
        ),
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  final Color color;

  const _ArrowPainter(this.color);

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const width = 12.0;
    const height = 8.0;
    final baseX = size.width / 2;
    final baseY = size.height / 2;

    canvas.drawPath(_trianglePath(Offset(baseX, baseY - 2.0), width, height, true), paint);
    canvas.drawPath(_trianglePath(Offset(baseX, baseY + 2.0), width, height, false), paint);
  }

  static Path _trianglePath(Offset o, double width, double height, bool isUp) {
    return Path()
      ..moveTo(o.dx, o.dy)
      ..lineTo(o.dx + width, o.dy)
      ..lineTo(o.dx + (width / 2), isUp ? o.dy - height : o.dy + height)
      ..close();
  }
}

class _SlideFadeTransition extends StatelessWidget {
  final Animation<double> _animation;
  final Widget _child;

  const _SlideFadeTransition({required this._animation, required this._child});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) => _animation.value == 0.0 ? const SizedBox() : child!,
      child: SlideTransition(
        position: Tween(begin: const Offset(0.3, 0.0), end: Offset.zero).animate(_animation),
        child: FadeTransition(opacity: _animation, child: _child),
      ),
    );
  }
}

@freezed
abstract class _Segment with _$Segment {
  const factory _Segment({
    required DateTime date,
    required double startOffset,
    required String scrollLabel,
    @Default(false) bool showSegment,
  }) = __Segment;
}
