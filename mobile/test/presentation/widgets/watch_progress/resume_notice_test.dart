import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/widgets/watch_progress/resume_notice.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

import '../../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;
  final notice = find.byKey(const Key('resume_notice'));

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  double opacity(WidgetTester tester) => tester
      .widget<FadeTransition>(find.ancestor(of: notice, matching: find.byType(FadeTransition)).first)
      .opacity
      .value;

  testWidgets('says where the film resumed, then fades after 5 s and goes', (tester) async {
    await tester.pumpTestWidget(
      context,
      const Center(child: ResumeNotice(notice: ResumeNoticeEvent(Duration(minutes: 42, seconds: 10), 1))),
      overrides: [tvModeProvider.overrideWithValue(false)],
      expectSettle: false,
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Resumed at 42:10'), findsOneWidget);
    expect(opacity(tester), 1);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 400));
    expect(opacity(tester), lessThan(1));

    await tester.pump(const Duration(seconds: 1));
    expect(notice, findsNothing);
  });

  testWidgets('an hour and more reads with the hours', (tester) async {
    await tester.pumpTestWidget(
      context,
      const Center(child: ResumeNotice(notice: ResumeNoticeEvent(Duration(hours: 1, minutes: 2, seconds: 3), 1))),
      overrides: [tvModeProvider.overrideWithValue(false)],
      expectSettle: false,
    );

    expect(find.text('Resumed at 01:02:03'), findsOneWidget);
  });

  testWidgets('larger on a TV', (tester) async {
    await tester.pumpTestWidget(
      context,
      const Center(child: ResumeNotice(notice: ResumeNoticeEvent(Duration(minutes: 5), 1))),
      overrides: [tvModeProvider.overrideWithValue(true)],
      expectSettle: false,
    );

    expect(tester.widget<Text>(find.text('Resumed at 05:00')).style?.fontSize, 22);
  });

  testWidgets('nothing without a resume', (tester) async {
    await tester.pumpTestWidget(
      context,
      const ResumeNotice(notice: null),
      overrides: [tvModeProvider.overrideWithValue(false)],
    );

    expect(notice, findsNothing);
  });

  testWidgets('a second resume shows it again', (tester) async {
    Widget noticeOf(int serial) =>
        Center(child: ResumeNotice(notice: ResumeNoticeEvent(const Duration(minutes: 5), serial)));
    await tester.pumpTestWidget(
      context,
      noticeOf(1),
      overrides: [tvModeProvider.overrideWithValue(false)],
      expectSettle: false,
    );
    await tester.pump(const Duration(seconds: 7));
    expect(notice, findsNothing);

    await tester.pumpTestWidget(
      context,
      noticeOf(2),
      overrides: [tvModeProvider.overrideWithValue(false)],
      expectSettle: false,
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(notice, findsOneWidget);
  });

  testWidgets('takes no touch: a swipe over it still goes to the next page', (tester) async {
    final pages = PageController();
    addTearDown(pages.dispose);
    await tester.pumpTestWidget(
      context,
      Stack(
        children: [
          PageView(controller: pages, children: const [Text('page 1'), Text('page 2')]),
          const Positioned.fill(
            child: Center(child: ResumeNotice(notice: ResumeNoticeEvent(Duration(minutes: 5), 1))),
          ),
        ],
      ),
      overrides: [tvModeProvider.overrideWithValue(false)],
      expectSettle: false,
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.flingFrom(tester.getCenter(notice), const Offset(-600, 0), 2000);
    await tester.pumpAndSettle();

    expect(pages.page, 1);
  });

  test('each resume of a screen gets the next serial, so that the same position shows again', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final shown = <ResumeNoticeEvent?>[];
    container.listen(resumeNoticeProvider, (_, notice) => shown.add(notice));

    container.read(resumeNoticeProvider.notifier).show(const Duration(minutes: 5));
    container.read(resumeNoticeProvider.notifier).show(const Duration(minutes: 5));

    expect(shown, const [ResumeNoticeEvent(Duration(minutes: 5), 1), ResumeNoticeEvent(Duration(minutes: 5), 2)]);
  });
}
