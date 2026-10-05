import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/panorama_360.model.dart';
import 'package:immich_mobile/presentation/widgets/panorama_360/panorama_360_filter_bar.widget.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/panorama_360.provider.dart';

import '../../../unit/presentation/presentation_context.dart';

Panorama360Entry _entry(String id) => Panorama360Entry(
  asset: RemoteAsset(
    id: id,
    name: '$id.jpg',
    ownerId: 'me',
    checksum: 'checksum-$id',
    type: AssetType.image,
    createdAt: DateTime(2024, 9, 14, 12),
    updatedAt: DateTime(2024, 9, 14, 12),
    isEdited: false,
  ),
  day: DateTime(2024, 9, 14),
);

Panorama360View _view({
  int entries = 3,
  int? total,
  List<Panorama360CameraCount> cameras = const [(key: 'insta360 x3', label: 'Insta360 X3', count: 3)],
  Set<Panorama360Source> sources = const {Panorama360Source.server, Panorama360Source.device},
}) => Panorama360View(
  entries: [for (var index = 0; index < entries; index++) _entry('a$index')],
  facets: Panorama360Facets(
    total: total ?? entries,
    cameras: cameras,
    months: const {
      2024: {9: 2, 8: 1},
      2023: {5: 1},
    },
    firstDay: DateTime(2023, 5, 5),
    lastDay: DateTime(2024, 9, 14),
    availableSources: sources,
  ),
);

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  /// Pumps the bar over [view], from a new tree: the providers and the filter start afresh
  Future<void> pumpBar(WidgetTester tester, {Panorama360View? view, bool hasServer = true}) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpTestWidget(
      context,
      const CustomScrollView(slivers: [Panorama360FilterBar()]),
      overrides: [
        panorama360ViewProvider.overrideWith((ref) => Stream.value(view ?? _view())),
        hasServerProvider.overrideWithValue(hasServer),
      ],
    );
  }

  Panorama360Filter filterOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(Panorama360FilterBar))).read(panorama360FilterProvider);

  Future<void> tapChip(WidgetTester tester, String label) async {
    final chip = find.text(label);
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();
  }

  testWidgets('shows the source chips only with a server', (tester) async {
    await pumpBar(tester);
    expect(find.text('On the server'), findsOneWidget);
    expect(find.text('On this device'), findsOneWidget);
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Videos'), findsOneWidget);
    expect(find.text('3D'), findsOneWidget);
    expect(find.text('VR180'), findsOneWidget);
    expect(find.text('Date'), findsOneWidget);

    await pumpBar(tester, hasServer: false);
    expect(find.text('On the server'), findsNothing);
    expect(find.text('On this device'), findsNothing);
    expect(find.text('Photos'), findsOneWidget);
  });

  testWidgets('shows Shared with me only when shared media exist', (tester) async {
    await pumpBar(tester);
    expect(find.text('Shared with me'), findsNothing);

    await pumpBar(tester, view: _view(sources: {Panorama360Source.server, Panorama360Source.shared}));
    expect(find.text('Shared with me'), findsOneWidget);
    await tapChip(tester, 'Shared with me');
    expect(filterOf(tester).sources, {Panorama360Source.server, Panorama360Source.device, Panorama360Source.shared});
  });

  testWidgets('toggles Videos and VR180 into the filter', (tester) async {
    await pumpBar(tester);

    await tapChip(tester, 'Videos');
    await tapChip(tester, 'VR180');

    expect(filterOf(tester).kinds, {Panorama360Kind.video});
    expect(filterOf(tester).traits, {Panorama360Trait.vr180});
    expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Videos')).selected, isTrue);
    expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Photos')).selected, isFalse);

    await tapChip(tester, 'Videos');
    expect(filterOf(tester).kinds, isEmpty);
  });

  testWidgets('keeps at least one source selected', (tester) async {
    await pumpBar(tester);

    await tapChip(tester, 'On the server');
    expect(filterOf(tester).sources, {Panorama360Source.device});

    await tapChip(tester, 'On this device');
    expect(filterOf(tester).sources, {Panorama360Source.device});
    expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'On this device')).selected, isTrue);
  });

  testWidgets('shows the cameras with their counts when there are two or more', (tester) async {
    await pumpBar(tester);
    expect(find.text('Insta360 X3 (3)'), findsNothing);

    await pumpBar(
      tester,
      view: _view(
        cameras: const [(key: 'insta360 x3', label: 'Insta360 X3', count: 3), (key: '', label: '', count: 1)],
      ),
    );
    expect(find.text('Insta360 X3 (3)'), findsOneWidget);
    expect(find.text('Unknown camera (1)'), findsOneWidget);

    await tapChip(tester, 'Unknown camera (1)');
    expect(filterOf(tester).cameras, {''});
  });

  testWidgets('shows Clear once a filter is set, and Clear resets it', (tester) async {
    await pumpBar(tester);
    expect(find.text('Clear'), findsNothing);

    await tapChip(tester, 'Photos');
    expect(find.text('Clear'), findsOneWidget);

    await tapChip(tester, 'Clear');
    expect(filterOf(tester).isDefault, isTrue);
    expect(find.text('Clear'), findsNothing);
  });

  testWidgets('picks a month in the period sheet and shows it on the chip', (tester) async {
    await pumpBar(tester);

    await tapChip(tester, 'Date');
    expect(find.text('All'), findsOneWidget);
    expect(find.text('2024'), findsOneWidget);
    expect(find.text('2023'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);

    await tester.tap(find.text('2024'));
    await tester.pumpAndSettle();
    expect(find.text('Whole year'), findsOneWidget);
    await tester.tap(find.text('September 2024'));
    await tester.pumpAndSettle();

    expect(filterOf(tester).period, const Panorama360Month(2024, 9));
    expect(find.text('All'), findsNothing, reason: 'the sheet is closed');
    expect(find.text('September 2024'), findsOneWidget);
    expect(find.text('Date'), findsNothing);

    await tapChip(tester, 'September 2024');
    expect(find.text('September 2024'), findsNWidgets(2), reason: 'its year opens on it');
    await tester.tap(find.text('2023'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.widgetWithText(ExpansionTile, '2023'), matching: find.text('Whole year')),
    );
    await tester.pumpAndSettle();
    expect(filterOf(tester).period, const Panorama360Year(2023));
    expect(find.text('2023'), findsOneWidget);
  });

  testWidgets('removes the period from its chip', (tester) async {
    await pumpBar(tester);
    ProviderScope.containerOf(
      tester.element(find.byType(Panorama360FilterBar)),
    ).read(panorama360FilterProvider.notifier).setPeriod(const Panorama360Year(2024));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(of: find.byType(InputChip), matching: find.byIcon(Icons.clear)));
    await tester.pumpAndSettle();

    expect(filterOf(tester).period, isNull);
    expect(find.text('Date'), findsOneWidget);
  });

  testWidgets('tells when no media matches the filters', (tester) async {
    await pumpBar(tester, view: _view(entries: 0, total: 3));
    expect(find.text('No 360° photo or video matches these filters'), findsOneWidget);

    await pumpBar(tester, view: _view(entries: 0, total: 0));
    expect(find.text('No 360° photo or video matches these filters'), findsNothing);
  });
}
