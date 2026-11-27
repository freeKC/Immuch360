// The phone's sheet of "Add (server) to (screen)": the check number the screen shows too, and the warning, before
// any token leaves the phone

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_handover.sheet.dart';

import '../../../test_utils.dart';
import 'play_on_test_app.dart';

void main() {
  setUpAll(TestUtils.init);

  Future<void> open(WidgetTester tester, void Function(bool) answered) async {
    playOnPhoneScreen(tester);
    await pumpPlayOn(
      tester,
      playOnOpener(
        (context) async => answered(
          await showPlayHandoverSheet(context, screen: 'Living room TV', server: 'Home Plex', check: '048213'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('names the server and the screen, the number to check, and the warning', (tester) async {
    await open(tester, (_) {});
    expect(find.text('Add Home Plex to Living room TV?'), findsOneWidget);
    expect(find.text('048 213'), findsOneWidget);
    expect(find.text('Check that Living room TV shows the same number. Cancel if it does not.'), findsOneWidget);
    expect(
      find.text(
        'Living room TV gets the same full access to your Plex server Home Plex as this phone. Remove the server on '
        'Living room TV to forget it there; the access stays valid on the server.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Add gives true, Cancel false', (tester) async {
    final answers = <bool>[];
    await open(tester, answers.add);
    await tester.tap(find.byKey(const Key('play_handover_confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(answers, [true, false]);
  });

  testWidgets('Sign (screen) in: who it is signed in as, the number to check, the warning of the sign in', (
    tester,
  ) async {
    final answers = <bool>[];
    playOnPhoneScreen(tester);
    await pumpPlayOn(
      tester,
      playOnOpener(
        (context) async => answers.add(
          await showPlaySignInSheet(
            context,
            screen: 'Living room TV',
            server: 'photos.example.org',
            user: 'Fred',
            check: '048213',
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Sign Living room TV in?'), findsOneWidget);
    expect(find.text('Living room TV will be signed in to photos.example.org as Fred.'), findsOneWidget);
    expect(find.text('048 213'), findsOneWidget);
    expect(find.textContaining('It stays signed in while this phone is.'), findsOneWidget);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(answers, [true]);
  });

  testWidgets('a sheet dragged away is no answer: false', (tester) async {
    final answers = <bool>[];
    await open(tester, answers.add);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(answers, [false]);
  });
}
