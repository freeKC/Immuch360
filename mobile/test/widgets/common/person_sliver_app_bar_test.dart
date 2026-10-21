// The header of a person's page: on a TV or in the read only mode (no edit hooks given) it has no options button, the
// name and the birthday are plain text, and no "Add a name" nor "Add a birthday" invites an edit; elsewhere it keeps
// them. A TV reaches this page from the read only details of a photo, and the options button led to a text field and
// the TV keyboard.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/person.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/widgets/common/person_sliver_app_bar.dart';

import '../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  Future<void> pumpHeader(WidgetTester tester, Person person, {required bool editable}) async {
    final timeline = TimelineService((
      assetSource: (index, count) async => const [],
      bucketSource: () => Stream.value(const []),
      origin: TimelineOrigin.main,
    ));
    addTearDown(timeline.dispose);
    await tester.pumpTestWidget(
      context,
      CustomScrollView(
        slivers: [
          PersonSliverAppBar(
            person: person,
            onNameTap: editable ? () {} : null,
            onBirthdayTap: editable ? () {} : null,
            onShowOptions: editable ? () {} : null,
          ),
        ],
      ),
      overrides: [timelineServiceProvider.overrideWithValue(timeline)],
      expectSettle: false,
    );
    await tester.pump(const Duration(seconds: 1));
    // The face of the person does not load in a test
    tester.takeException();
  }

  const unnamed = Person(id: 'person-1', name: '');

  testWidgets('without edit hooks: no options button, no "Add a name", no "Add a birthday"', (tester) async {
    await pumpHeader(tester, unnamed, editable: false);

    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(find.text('Add a name'), findsNothing);
    expect(find.text('Add a birthday'), findsNothing);
    expect(find.byIcon(Icons.cake_rounded), findsNothing, reason: 'no birthday to show');
  });

  testWidgets('without edit hooks a known name and birthday still show', (tester) async {
    await pumpHeader(tester, Person(id: 'person-2', name: 'Anne', birthDate: DateTime(1990, 5, 4)), editable: false);

    expect(find.text('Anne'), findsOneWidget);
    expect(find.byIcon(Icons.cake_rounded), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsNothing);
  });

  testWidgets('with edit hooks the options button and the invitations stay', (tester) async {
    await pumpHeader(tester, unnamed, editable: true);

    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    expect(find.text('Add a name'), findsOneWidget);
    expect(find.text('Add a birthday'), findsOneWidget);
  });
}
