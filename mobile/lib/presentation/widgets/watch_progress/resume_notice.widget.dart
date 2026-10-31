import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/duration_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_transient.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

/// A film that resumed where it was left: at [position], the [serial]th of its screen, so that a second resume shows the
/// notice again
class ResumeNoticeEvent {
  const ResumeNoticeEvent(this.position, this.serial);

  final Duration position;
  final int serial;

  @override
  bool operator ==(Object other) => other is ResumeNoticeEvent && other.position == position && other.serial == serial;

  @override
  int get hashCode => Object.hash(position, serial);
}

/// The last film the asset viewer resumed, for its [ResumeNotice]; gone with the viewer
class ResumeNotices extends AutoDisposeNotifier<ResumeNoticeEvent?> {
  @override
  ResumeNoticeEvent? build() => null;

  /// A film resumed at [position]
  void show(Duration position) => state = ResumeNoticeEvent(position, (state?.serial ?? 0) + 1);
}

final resumeNoticeProvider = NotifierProvider.autoDispose<ResumeNotices, ResumeNoticeEvent?>(ResumeNotices.new);

/// "Resumed at 42:10" on a dark pill, for a few seconds once a film resumed where it was left ([notice]), then it fades
/// (the app's rule for the words over a picture, see DjiTransient: 5 s, then 0.8 s out). No button, no popup: it takes
/// no touch, so that the swipes and the taps go to the viewer under it, and no focus. Larger on a TV.
class ResumeNotice extends ConsumerWidget {
  const ResumeNotice({super.key, required this.notice});

  final ResumeNoticeEvent? notice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notice = this.notice;
    if (notice == null) {
      return const SizedBox.shrink();
    }
    final tv = ref.watch(tvModeProvider);
    return IgnorePointer(
      child: ExcludeFocus(
        child: DjiTransient(
          kind: notice.serial,
          child: DecoratedBox(
            key: const Key('resume_notice'),
            decoration: const BoxDecoration(
              color: Color.fromRGBO(0, 0, 0, 0.7),
              borderRadius: BorderRadius.all(Radius.circular(24)),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: tv ? 28 : 18, vertical: tv ? 14 : 9),
              child: Text(
                context.t.video_resumed_at(position: notice.position.format()),
                style: TextStyle(color: Colors.white, fontSize: tv ? 22 : 15, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
