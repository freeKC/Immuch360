// Opening the scene of a splat photo (plan of 3 November 2026, lots L3 and L4): taken out of the original on the
// server into the splat viewer's cache, then the splat viewer of a phone opens the cache file under the name of its SPZ,
// or the immersive viewer of a Meta Quest gets it in the unchanged gaussianSplat request with its up; nothing
// downloaded at the second opening; a large scene over a metered network is asked first.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/splat/splat_gate.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_scenes.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_tail_fetch.dart';
import 'package:immich_mobile/domain/services/splat_viewer_files.dart';
import 'package:immich_mobile/domain/services/splat_viewer_service.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_photo_launch.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/splat/splat_viewer.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../domain/splat_photo/splat_photo_fixtures.dart';
import '../../../infrastructure/repository.mock.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../widget_tester_extensions.dart';

class _Viewings implements SplatViewerService {
  final shown = <({SplatViewerSource source, SplatHead head, int fileBytes, int cap})>[];

  @override
  Future<SplatViewerOutcome> show({
    required SplatViewerSource source,
    required SplatHead head,
    required int fileBytes,
    required int cap,
    required SplatViewerLook look,
    void Function(SplatPrepareStep step, double done)? progress,
    SplatPrepareCancel? cancel,
    void Function()? onOpening,
    bool watchFrames = false,
  }) async {
    shown.add((source: source, head: head, fileBytes: fileBytes, cap: cap));
    onOpening?.call();
    return const SplatViewerOutcome(SplatViewerEnd.closed);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingImmersiveApi extends ImmersiveApi {
  final opened = <({String url, String title, String? stereoPair})>[];

  @override
  Future<bool> isHorizonOs() async => true;

  @override
  Future<void> open(
    String url,
    Map<String, String> headers,
    bool isVideo,
    String title,
    ImmersiveStereoLayout stereoLayout,
    Map<String, String> stereoLabels,
    ImmersiveSphereCoverage coverage,
    int startPositionMs,
    int openingId,
    String? fallbackUrl,
    String? rawProjection,
    String? stereoPair,
    bool reverseThumbstickTurn,
    bool sharpFlatScreens, {
    String? kiosk,
    String? sourceNotice,
    String? sourceRefusal,
    bool gaussianSplats = true,
    int watchMinDurationMs = -1,
    String? startNotice,
  }) async {
    opened.add((url: url, title: title, stereoPair: stereoPair));
  }
}

void main() {
  late Directory dir;
  late List<http.BaseRequest> requests;
  late Uint8List served;
  late _Viewings viewings;
  late _RecordingImmersiveApi immersiveApi;
  late MockStorageRepository storage;
  var metered = false;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('splat_photo_launch');
    requests = [];
    served = splatPhotoFixture('ok_v2.jpg');
    viewings = _Viewings();
    immersiveApi = _RecordingImmersiveApi();
    storage = MockStorageRepository();
    metered = false;
  });

  tearDown(() => dir.deleteSync(recursive: true));

  // The server answers the suffix range with 206
  http.Client server() => MockClient((request) async {
    requests.add(request);
    final range = request.headers['range'];
    final suffix = int.tryParse(RegExp(r'bytes=-(\d+)').firstMatch(range ?? '')?.group(1) ?? '');
    if (suffix == null) {
      return http.Response.bytes(served, 200);
    }
    final start = served.length - suffix;
    return http.Response.bytes(
      served.sublist(start),
      206,
      headers: {'content-range': 'bytes $start-${served.length - 1}/${served.length}'},
    );
  });

  List<Override> overrides({SplatDeviceClass device = SplatDeviceClass.phone}) => [
    appConfigProvider.overrideWithValue(const AppConfig()),
    splatDeviceClassProvider.overrideWithValue(device),
    splatViewerServiceProvider.overrideWithValue(viewings),
    immersiveApiProvider.overrideWithValue(immersiveApi),
    storageRepositoryProvider.overrideWithValue(storage),
    splatFreeBytesProvider.overrideWithValue(null),
    splatPhotoScenesProvider.overrideWithValue(SplatPhotoScenes(SplatViewerCache(() async => dir))),
    splatPhotoServerSourceProvider.overrideWithValue(
      (remoteId) =>
          SplatTailFromServer(client: server(), url: Uri.parse('https://media.example/api/assets/$remoteId/original')),
    ),
    splatPhotoMeteredProvider.overrideWithValue(() async => metered),
  ];

  /// A button that opens the scene of [asset] told by [xmp] with [request]
  Widget opener(BaseAsset asset, SplatPhotoXmp xmp, GaussianSplatRequest request) => Scaffold(
    body: Consumer(
      builder: (context, ref, _) =>
          TextButton(onPressed: () => openSplatPhoto(context, ref, asset, xmp, request), child: const Text('open')),
    ),
  );

  GaussianSplatRequest requestOf(SplatPhotoXmp xmp, {int cap = 150000}) => GaussianSplatRequest(
    format: 'spz',
    formatVersion: xmp.splatVersion!,
    gaussians: xmp.splatGaussians!,
    shDegree: xmp.splatShDegree!,
    fileBytes: xmp.splatLength!,
    maxGaussians: cap,
    name: xmp.splatName!,
  );

  testWidgets('a phone downloads the scene once, then opens the cache file under the name of its SPZ', (tester) async {
    final asset = RemoteAssetFactory.create(name: 'axes_splat.jpg', width: 48, height: 32);
    final xmp = SplatPhotoXmp.findIn(served)!;
    await tester.pumpConsumerWidget(opener(asset, xmp, requestOf(xmp)), overrides: overrides());

    await tester.runAsync(() async {
      await tester.tap(find.text('open'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    expect(requests.single.url.toString(), 'https://media.example/api/assets/${asset.id}/original');
    expect(requests.single.headers['range'], 'bytes=-913');
    expect(viewings.shown, hasLength(1));
    final shown = viewings.shown.single;
    expect(shown.source.name, 'axes_v2.spz');
    expect(shown.source.sourceId, isNull);
    expect(File(shown.source.path).readAsBytesSync(), splatFixture('axes_v2.spz'));
    expect(shown.fileBytes, 913);
    expect(shown.head.gaussians, 686);
    expect(shown.cap, 150000);

    // The second opening reads nothing of the server
    await tester.runAsync(() async {
      await tester.tap(find.text('open'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(viewings.shown, hasLength(2));
    expect(viewings.shown.last.source.path, shown.source.path);
  });

  testWidgets('the orientation chosen before the save goes with the scene', (tester) async {
    served = splatPhotoFixture('ok_v4.jpg');
    final asset = RemoteAssetFactory.create(name: 'axes_splat.jpg', width: 48, height: 32);
    final xmp = SplatPhotoXmp.findIn(served)!;
    await tester.pumpConsumerWidget(opener(asset, xmp, requestOf(xmp)), overrides: overrides());

    await tester.runAsync(() async {
      await tester.tap(find.text('open'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(viewings.shown.single.source.up, 'yUp');
    expect(viewings.shown.single.source.name, 'axes_v4.spz');
  });

  testWidgets('a Meta Quest gets the cache file in the request of version 1, with its name, size and up', (
    tester,
  ) async {
    served = splatPhotoFixture('ok_v4.jpg');
    final asset = RemoteAssetFactory.create(name: 'axes_splat.jpg', width: 48, height: 32);
    final xmp = SplatPhotoXmp.findIn(served)!;
    await tester.pumpConsumerWidget(
      opener(asset, xmp, requestOf(xmp, cap: 50000)),
      overrides: overrides(device: SplatDeviceClass.quest),
    );

    await tester.runAsync(() async {
      await tester.tap(find.text('open'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(viewings.shown, isEmpty);
    final opened = immersiveApi.opened.single;
    expect(opened.url, startsWith('file://'));
    expect(opened.url, endsWith('.spz'));
    expect(File(Uri.parse(opened.url).toFilePath()).readAsBytesSync(), splatFixture('axes_v4.spz'));
    expect(jsonDecode(opened.stereoPair!), {
      'kind': 'gaussianSplat',
      'version': 1,
      'format': 'spz',
      'formatVersion': 4,
      'gaussians': 686,
      'shDegree': 0,
      'fileBytes': 954,
      'maxGaussians': 50000,
      'tool': null,
      'name': 'axes_v4.spz',
      'up': 'yUp',
    });
  });

  testWidgets('a large scene over a metered network is asked first; Cancel downloads nothing', (tester) async {
    metered = true;
    final asset = RemoteAssetFactory.create(name: 'big_splat.jpg', width: 48, height: 32);
    final real = SplatPhotoXmp.findIn(served)!;
    final xmp = SplatPhotoXmp(
      splatVersion: real.splatVersion,
      splatGaussians: real.splatGaussians,
      splatShDegree: real.splatShDegree,
      splatLength: 20 * 1000 * 1000,
      splatSha256: real.splatSha256,
      splatName: 'big.spz',
    );
    await tester.pumpConsumerWidget(opener(asset, xmp, requestOf(xmp)), overrides: overrides());

    // The kept scenes are looked for on the disk first: real time for it
    await tester.runAsync(() async {
      await tester.tap(find.text('open'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('Download 19.1 MiB over mobile data?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(viewings.shown, isEmpty);
  });

  testWidgets('a copy on the device that lost its scene gives way to the server', (tester) async {
    final copy = File('${dir.path}/../trailer_${DateTime.now().microsecondsSinceEpoch}.jpg')
      ..writeAsBytesSync(splatPhotoFixture('trailer.jpg'));
    addTearDown(() => copy.deleteSync());
    when(() => storage.getFileForAsset('local-1')).thenAnswer((_) async => copy);
    final asset = RemoteAssetFactory.create(name: 'axes_splat.jpg', localId: 'local-1', width: 48, height: 32);
    final xmp = SplatPhotoXmp.findIn(served)!;
    await tester.pumpConsumerWidget(opener(asset, xmp, requestOf(xmp)), overrides: overrides());

    await tester.runAsync(() async {
      await tester.tap(find.text('open'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(requests, hasLength(1), reason: 'the server, once the copy failed');
    expect(File(viewings.shown.single.source.path).readAsBytesSync(), splatFixture('axes_v2.spz'));
  });
}
