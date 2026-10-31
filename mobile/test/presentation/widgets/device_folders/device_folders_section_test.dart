// The folders of the device on top of On this device: the folders chosen before, Browse a folder and its picker, the
// browser opened on a folder, a folder removed, and where the section shows at all.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/device_folder.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/document_tree_api.g.dart';
import 'package:immich_mobile/presentation/pages/local_album.page.dart';
import 'package:immich_mobile/presentation/widgets/device_folders/device_folders_section.widget.dart';
import 'package:immich_mobile/providers/drone/drone_import.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/device_folders.provider.dart';

import '../../../fixtures/document_tree.fake.dart';
import '../../../providers/network/fakes.dart';
import '../../pages/network/network_test_app.dart';

const _download = 'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FQuest';
const _splats = 'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FImmuch360-splats';
const _usb = 'content://com.android.externalstorage.documents/tree/1A2B-3C4D%3ADCIM';

TreePick _pick(
  String treeUri,
  String folderName, {
  String title = 'Internal shared storage',
  String kind = 'internal',
}) => TreePick(treeUri: treeUri, title: title, folderName: folderName, kind: kind);

/// The system picker: it gives [next] (null: the user went back) or throws [pickError]; a folder answers while it is
/// in [reachable]
class _PickerApi extends FakeDocumentTreeApi {
  _PickerApi() : super({'/beach.jpg': Uint8List(10)}, treeUri: _download);

  TreePick? next;
  Exception? pickError;
  int pickCalls = 0;
  final reachable = <String>{};
  final known = <String, TreePick>{};

  @override
  Future<TreePick?> pickTree(String? startFolder) async {
    pickCalls++;
    pickStarts.add(startFolder);
    final error = pickError;
    if (error != null) {
      throw error;
    }
    final pick = next;
    if (pick != null) {
      known[pick.treeUri] = pick;
      reachable.add(pick.treeUri);
    }
    return pick;
  }

  @override
  Future<TreePick?> reopen(String treeUri) async => reachable.contains(treeUri) ? known[treeUri] : null;
}

class _MemoryStore extends DroneRecentStore {
  _MemoryStore([List<RecentTree> trees = const []]) : trees = [...trees], super(() async => null);

  List<RecentTree> trees;

  @override
  Future<List<RecentTree>> load() async => trees;

  @override
  Future<void> save(List<RecentTree> trees) async => this.trees = trees;
}

void main() {
  final t = StaticTranslations.instance;
  late _PickerApi api;
  late _MemoryStore folders;
  final chosenAt = DateTime.utc(2026, 10, 31, 8);

  RecentTree tree(TreePick pick) => RecentTree.of(pick, chosenAt);

  setUp(() {
    api = _PickerApi();
    folders = _MemoryStore();
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  List<Override> overrides({int sdk = 34, bool tvMode = false}) => [
    documentTreeApiProvider.overrideWithValue(api),
    documentTreeEventsSetUpProvider.overrideWithValue((_) {}),
    deviceFolderStoreProvider.overrideWithValue(folders),
    droneRecentStoreProvider.overrideWithValue(_MemoryStore()),
    androidSdkIntProvider.overrideWith((ref) async => sdk),
    mediaBridgeProvider.overrideWithValue(FakeMediaBridge()),
    localAlbumProvider.overrideWith((ref) => Stream.value(const <LocalAlbum>[])),
    appConfigProvider.overrideWithValue(const AppConfig()),
    if (tvMode) tvModeProvider.overrideWithValue(true),
  ];

  Future<void> pumpPage(WidgetTester tester, {int sdk = 34, bool tvMode = false}) async {
    await pumpNetworkTestApp(
      tester,
      home: const LocalAlbumsPage(),
      overrides: overrides(sdk: sdk, tvMode: tvMode),
    );
  }

  Finder rowOf(String treeUri) => find.byKey(ValueKey('device_folder:$treeUri'));
  final browse = find.byKey(const Key('device_folder_browse'));

  group('On this device', () {
    testWidgets('lists the folders chosen before with where they are, then Browse a folder, above the albums', (
      tester,
    ) async {
      folders.trees = [tree(_pick(_download, 'Quest')), tree(_pick(_usb, 'DCIM', title: 'SanDisk', kind: 'usb'))];
      api
        ..known[_download] = _pick(_download, 'Quest')
        ..reachable.add(_download);
      await pumpPage(tester);

      expect(find.byKey(const Key('device_folders_header')), findsOneWidget);
      expect(find.text(t.folders), findsOneWidget);
      expect(find.descendant(of: rowOf(_download), matching: find.text('Quest')), findsOneWidget);
      expect(
        find.descendant(of: rowOf(_download), matching: find.text('Download/Quest · Internal shared storage')),
        findsOneWidget,
      );
      expect(find.descendant(of: rowOf(_usb), matching: find.text('DCIM')), findsOneWidget);
      expect(
        find.descendant(of: rowOf(_usb), matching: find.text(t.device_folder_unavailable)),
        findsOneWidget,
        reason: 'unplugged',
      );
      expect(find.descendant(of: rowOf(_usb), matching: find.byIcon(Icons.folder_off_outlined)), findsOneWidget);
      expect(find.text(t.device_folder_browse), findsOneWidget);
      expect(find.text(t.device_folder_browse_subtitle), findsOneWidget);
      expect(find.byKey(const Key('device_folder_picker_hint')), findsOneWidget);
      expect(find.text(t.device_folder_picker_hint), findsOneWidget);
      double top(Finder finder) => tester.getTopLeft(finder).dy;
      expect(top(rowOf(_download)), lessThan(top(rowOf(_usb))), reason: 'in the order chosen');
      expect(top(rowOf(_usb)), lessThan(top(browse)));
      expect(top(browse), lessThan(top(find.text(t.no_albums_yet))), reason: 'above the albums of the device');
    });

    testWidgets('Browse a folder opens the picker, then the browser on the folder chosen, which stays listed', (
      tester,
    ) async {
      api.next = _pick(_splats, 'Immuch360-splats');
      await pumpPage(tester);

      await tester.tap(browse);
      await tester.pumpAndSettle();

      expect(api.pickCalls, 1);
      expect(find.text('browse ${deviceFolderSourceId(_splats)} /'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.descendant(of: rowOf(_splats), matching: find.text('Immuch360-splats')), findsOneWidget);
      expect(folders.trees.map((folder) => folder.treeUri), [_splats]);
    });

    testWidgets('back from the picker: still on the page, nothing added', (tester) async {
      await pumpPage(tester);

      await tester.tap(browse);
      await tester.pumpAndSettle();

      expect(api.pickCalls, 1);
      expect(find.text(t.device_folder_browse), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> && (widget.key! as ValueKey<String>).value.startsWith('device_folder:'),
        ),
        findsNothing,
      );
    });

    testWidgets('a picker that cannot open says so', (tester) async {
      api.pickError = PlatformException(code: 'no_picker', message: 'This device has no folder picker');
      await pumpPage(tester);

      await tester.tap(browse);
      await tester.pumpAndSettle();

      expect(find.text(t.device_folder_picker_failed), findsOneWidget);
    });

    testWidgets('a folder chosen before opens the browser; one that cannot be read now says so', (tester) async {
      folders.trees = [tree(_pick(_download, 'Quest')), tree(_pick(_usb, 'DCIM', title: 'SanDisk', kind: 'usb'))];
      api
        ..known[_download] = _pick(_download, 'Quest')
        ..reachable.add(_download);
      await pumpPage(tester);

      await tester.tap(rowOf(_download));
      await tester.pumpAndSettle();
      expect(find.text('browse ${deviceFolderSourceId(_download)} /'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(rowOf(_usb));
      await tester.pumpAndSettle();
      expect(find.text(t.device_folder_gone), findsOneWidget);
      expect(find.textContaining('browse'), findsNothing);
    });

    testWidgets('the cross takes a folder out of the list, offers Undo, then gives its grant back', (tester) async {
      folders.trees = [tree(_pick(_download, 'Quest')), tree(_pick(_splats, 'Immuch360-splats'))];
      api.reachable.addAll([_download, _splats]);
      await pumpPage(tester);

      await tester.tap(find.descendant(of: rowOf(_download), matching: find.byTooltip(t.remove)));
      await tester.pumpAndSettle();

      expect(rowOf(_download), findsNothing);
      expect(rowOf(_splats), findsOneWidget);
      expect(folders.trees.map((folder) => folder.treeUri), [_splats]);
      expect(find.text(t.device_folder_removed(name: 'Quest')), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, t.undo), findsOneWidget);
      expect(api.released, isEmpty, reason: 'while Undo is offered');
      expect(find.textContaining('browse'), findsNothing, reason: 'nothing opened');

      // The snack bar fades by itself, an action in it or not
      await tester.pump(deviceFolderUndoDuration);
      await tester.pumpAndSettle();

      expect(find.text(t.device_folder_removed(name: 'Quest')), findsNothing);
      expect(api.released, [_download]);
      expect(rowOf(_download), findsNothing);
    });

    testWidgets('Undo puts the folder back at its place, its grant kept', (tester) async {
      folders.trees = [tree(_pick(_download, 'Quest')), tree(_pick(_splats, 'Immuch360-splats'))];
      api.reachable.addAll([_download, _splats]);
      await pumpPage(tester);

      await tester.tap(find.descendant(of: rowOf(_download), matching: find.byTooltip(t.remove)));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SnackBarAction, t.undo));
      await tester.pumpAndSettle();
      await tester.pump(deviceFolderUndoDuration);
      await tester.pumpAndSettle();

      expect(rowOf(_download), findsOneWidget);
      expect(tester.getTopLeft(rowOf(_download)).dy, lessThan(tester.getTopLeft(rowOf(_splats)).dy));
      expect(folders.trees.map((folder) => folder.treeUri), [_download, _splats]);
      expect(api.released, isEmpty);
    });

    testWidgets('no word on the Download folder before Android 11, whose picker offers it', (tester) async {
      await pumpPage(tester, sdk: 29);

      expect(browse, findsOneWidget);
      expect(find.byKey(const Key('device_folder_picker_hint')), findsNothing);
    });
  });

  group('where the section shows', () {
    testWidgets('not in the TV layout', (tester) async {
      await pumpPage(tester, tvMode: true);

      expect(browse, findsNothing);
      expect(find.byKey(const Key('device_folders_header')), findsNothing);
      expect(api.pickCalls, 0);
    });

    testWidgets('not on iOS, nor on the computers', (tester) async {
      for (final platform in [TargetPlatform.iOS, TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux]) {
        debugDefaultTargetPlatformOverride = platform;
        await pumpNetworkTestApp(
          tester,
          home: const Scaffold(body: DeviceFoldersSection()),
          overrides: overrides(),
        );

        expect(browse, findsNothing, reason: platform.name);
        expect(find.byKey(const Key('device_folders_header')), findsNothing, reason: platform.name);
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
