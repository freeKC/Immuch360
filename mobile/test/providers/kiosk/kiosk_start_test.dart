// The start of the kiosk mode of the Meta Quest: once per run of the app; nothing with the switch off or nothing
// chosen, without even asking the platform; nothing off a Meta Quest; on a Meta Quest a notice with Cancel first, Cancel
// opening nothing; the asset found on the server or on the device, the file of a share read as its page reads it,
// opened as a kiosk with its texts and without previous or next; a media gone or unreachable told as a failure.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/kiosk_config.dart';
import 'package:immich_mobile/domain/models/kiosk_media.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/kiosk/kiosk_start.provider.dart';

import '../../widget_tester_extensions.dart';

const _film = KioskAssetMedia(remoteId: 'remote-1', localId: 'local-2', name: 'expo_360.mp4', isVideo: true);
const _shareFilm = KioskShareFile(sourceId: 'nas', path: '/Expo/vr180_3d.mp4', name: 'vr180_3d.mp4', isVideo: true);

RemoteAsset _remote({DateTime? deletedAt}) => RemoteAsset(
  id: 'remote-1',
  localId: 'local-2',
  name: 'expo_360.mp4',
  ownerId: 'owner',
  checksum: 'c1',
  type: AssetType.video,
  createdAt: DateTime(2026, 10, 1),
  updatedAt: DateTime(2026, 10, 1),
  isEdited: false,
  deletedAt: deletedAt,
);

LocalAsset _local() => LocalAsset(
  id: 'local-2',
  name: 'expo_360.mp4',
  type: AssetType.video,
  createdAt: DateTime(2026, 10, 1),
  updatedAt: DateTime(2026, 10, 1),
  playbackStyle: AssetPlaybackStyle.video,
  isEdited: false,
);

/// Records what the immersive viewer is asked to open, the kiosk JSON included
class _RecordingImmersiveApi extends ImmersiveApi {
  final List<({String url, bool isVideo, int startPositionMs, int openingId, String? kiosk, bool gaussianSplats})>
  opened = [];
  Exception? failure;

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
  }) async {
    final failure = this.failure;
    if (failure != null) {
      throw failure;
    }
    opened.add((
      url: url,
      isVideo: isVideo,
      startPositionMs: startPositionMs,
      openingId: openingId,
      kiosk: kiosk,
      gaussianSplats: gaussianSplats,
    ));
  }
}

void main() {
  // The session of the viewer registers its events on the messenger of the binding
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KioskStart.run', () {
    late KioskStart start;
    late List<KioskMedia> prepared;
    late int opened;
    late int asked;
    late List<KioskMedia> noticed;
    Exception? openFailure;

    setUp(() {
      start = KioskStart();
      prepared = [];
      opened = 0;
      asked = 0;
      noticed = [];
      openFailure = null;
    });

    /// The notice before the opening ends with [notice]: true without Cancel, false with it
    Future<KioskStartOutcome> run(KioskConfig config, {bool horizonOs = true, Future<bool>? notice}) => start.run(
      config: config,
      isHorizonOs: () async {
        asked++;
        return horizonOs;
      },
      prepare: (media) {
        prepared.add(media);
        return () async {
          final failure = openFailure;
          if (failure != null) {
            throw failure;
          }
          opened++;
        };
      },
      countdown: (media) {
        noticed.add(media);
        return notice ?? Future.value(true);
      },
    );

    test('nothing chosen: the app starts as usual, without a question to the platform', () async {
      expect(await run(const KioskConfig()), KioskStartOutcome.off);
      expect(asked, 0);
      expect(prepared, isEmpty);
      expect(noticed, isEmpty);
    });

    test('the switch off: the media chosen stays where it is', () async {
      expect(await run(KioskConfig(enabled: false, media: _film.encode())), KioskStartOutcome.off);
      expect(asked, 0);
      expect(prepared, isEmpty);
    });

    test('a media chosen that no longer reads counts as nothing chosen', () async {
      expect(await run(const KioskConfig(media: '{"type":"album"}')), KioskStartOutcome.off);
      expect(prepared, isEmpty);
    });

    test('off a Meta Quest, nothing opens, and no notice', () async {
      expect(await run(KioskConfig(media: _film.encode()), horizonOs: false), KioskStartOutcome.notHeadset);
      expect(opened, 0);
      expect(noticed, isEmpty);
    });

    test('on a Meta Quest, the media chosen opens after the notice, once per run of the app', () async {
      final config = KioskConfig(media: _film.encode());

      expect(await run(config), KioskStartOutcome.opened);
      expect(noticed, [_film]);
      expect(prepared, [_film]);
      expect(opened, 1);
      expect(start.ran, isTrue);

      // The tab shell built again (a login): no second kiosk
      expect(await run(config), KioskStartOutcome.ranBefore);
      expect(opened, 1);
      expect(asked, 1);
    });

    test('Cancel on the notice: nothing opens, the app starts as usual, and no second notice in this run', () async {
      final config = KioskConfig(media: _film.encode());

      expect(await run(config, notice: Future.value(false)), KioskStartOutcome.cancelled);
      expect(noticed, [_film]);
      expect(opened, 0);

      expect(await run(config), KioskStartOutcome.ranBefore);
      expect(noticed, [_film]);
      expect(opened, 0);
    });

    test('without Cancel, the media opens only once the notice is over', () async {
      final notice = Completer<bool>();
      final outcome = run(KioskConfig(media: _film.encode()), notice: notice.future);
      await pumpEventQueue();
      expect(noticed, [_film]);
      expect(opened, 0, reason: 'the notice is still on screen');

      notice.complete(true);
      expect(await outcome, KioskStartOutcome.opened);
      expect(opened, 1);
    });

    test('a media that does not open is a failure, and is not tried again in this run', () async {
      openFailure = Exception('gone');
      final config = KioskConfig(media: _shareFilm.encode());

      expect(await run(config), KioskStartOutcome.failed);
      expect(await run(config), KioskStartOutcome.ranBefore);
      expect(prepared, [_shareFilm]);
    });
  });

  group('findKioskAsset', () {
    test('the asset on the server first', () async {
      final asset = await findKioskAsset(
        _film,
        remote: (id) async => id == 'remote-1' ? _remote() : null,
        local: (_) async => fail('the server has it'),
      );

      expect(asset, isA<RemoteAsset>());
      expect(asset.remoteId, 'remote-1');
    });

    test('gone from the server, or in its trash, the copy on the device', () async {
      for (final remote in [null, _remote(deletedAt: DateTime(2026, 10, 20))]) {
        final asset = await findKioskAsset(
          _film,
          remote: (_) async => remote,
          local: (id) async => id == 'local-2' ? _local() : null,
        );

        expect(asset, isA<LocalAsset>());
      }
    });

    test('a photo only on the device is looked for there only', () async {
      const photo = KioskAssetMedia(localId: 'local-2', name: 'PANO.jpg', isVideo: false);
      final asset = await findKioskAsset(
        photo,
        remote: (_) async => fail('not on the server'),
        local: (_) async => _local(),
      );

      expect(asset.localId, 'local-2');
    });

    test('in neither any more: an error', () async {
      await expectLater(
        findKioskAsset(_film, remote: (_) async => null, local: (_) async => null),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('kioskShareRequest', () {
    final bridgeUrl = Uri.parse('http://127.0.0.1:41234/token/nas/Expo/vr180_3d.mp4');
    // A file that reads, whose header declares nothing the detection needs (the detection is replaced)
    Future<Uint8List> noRead(int offset, int length) async => Uint8List(length);

    test('a 3D VR180 film of a share: its bridge URL, and the layout and the coverage its file declares', () async {
      NetworkEntry? read;
      final request = await kioskShareRequest(
        _shareFilm,
        mediaUrl: (sourceId, path) async {
          expect((sourceId, path), ('nas', '/Expo/vr180_3d.mp4'));
          return bridgeUrl;
        },
        reader: (_) => noRead,
        detect: (entry, _) async {
          read = entry;
          return const NetworkMediaInfo(
            probe: SphericalProbe(stereo: StereoLayout.topBottom, halfSphere: true, hasSphericalMetadata: true),
          );
        },
      );

      expect(read?.path, '/Expo/vr180_3d.mp4');
      expect(request.url, bridgeUrl.toString());
      expect(request.isVideo, isTrue);
      expect(request.title, 'vr180_3d.mp4');
      expect(request.view.layout, StereoLayout.topBottom);
      expect(request.view.coverage, SphereCoverage.half);
    });

    test('a photo of a share is read with the size of its listing', () async {
      const photo = KioskShareFile(sourceId: 'nas', path: '/Expo/pano.jpg', name: 'pano.jpg', isVideo: false, size: 42);
      NetworkEntry? read;
      final request = await kioskShareRequest(
        photo,
        mediaUrl: (_, _) async => Uri.parse('http://127.0.0.1:41234/token/nas/Expo/pano.jpg'),
        reader: (_) => noRead,
        detect: (entry, _) async {
          read = entry;
          return null;
        },
      );

      expect(read?.size, 42);
      expect(request.isVideo, isFalse);
      expect(request.view.layout, StereoLayout.mono);
      expect(request.view.coverage, SphereCoverage.full);
    });

    test('a file gone from a share that answers: an error, before any detection', () async {
      // The media bridge answers 404 for a path the share no longer has
      final bridge = MockClient((request) async {
        expect(request.headers['range'], 'bytes=0-0');
        return http.Response('Not found', 404);
      });
      await expectLater(
        kioskShareRequest(
          _shareFilm,
          mediaUrl: (_, _) async => bridgeUrl,
          reader: (url) => httpRangeReader(bridge, url),
          detect: (_, _) async => fail('nothing to detect in a file that is gone'),
        ),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('an empty file on the share: an error', () async {
      await expectLater(
        kioskShareRequest(
          _shareFilm,
          mediaUrl: (_, _) async => bridgeUrl,
          reader: (_) =>
              (_, _) async => Uint8List(0),
          detect: (_, _) async => fail('nothing to detect in an empty file'),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('a share that cannot be reached: an error', () async {
      await expectLater(
        kioskShareRequest(
          _shareFilm,
          mediaUrl: (_, _) async => throw StateError('unreachable'),
          reader: (_) => noRead,
          detect: (_, _) async => fail('nothing to read'),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('openKioskRequest', () {
    const options = KioskOptions(endText: 'Merci pour le voyage', exitHint: 'Maintenez B ou Y une seconde');
    const request = ImmersiveRequest(
      url: 'file:///storage/emulated/0/Movies/expo_360.mp4',
      isVideo: true,
      title: 'expo_360.mp4',
      view: stereoPhotoSphereView,
    );

    test('the viewer gets the kiosk texts, from 0:00, as an opening with no previous or next', () async {
      final api = _RecordingImmersiveApi();
      final session = ImmersiveSession();
      addTearDown(session.dispose);

      await openKioskRequest(api, session, request, options: options, stereoLabels: const {});

      final opened = api.opened.single;
      expect(opened.url, request.url);
      expect(opened.startPositionMs, 0);
      expect(jsonDecode(opened.kiosk!), {
        'endText': 'Merci pour le voyage',
        'exitHint': 'Maintenez B ou Y une seconde',
      });
      expect(session.isCurrent(opened.openingId), isTrue);
      expect(opened.gaussianSplats, isFalse, reason: 'a kiosk shows no splat: the viewer does not start the module');
      expect(
        await session.requestAdjacent(opened.openingId, 1, 1, ImmersiveStereoLayout.mono, ImmersiveSphereCoverage.full),
        isFalse,
        reason: 'a kiosk has no previous or next',
      );
    });

    test('a viewer that does not open leaves no opening behind', () async {
      final api = _RecordingImmersiveApi()..failure = Exception('no headset');
      final session = ImmersiveSession();
      addTearDown(session.dispose);

      await expectLater(
        openKioskRequest(api, session, request, options: options, stereoLabels: const {}),
        throwsA(isA<Exception>()),
      );
      expect(session.isOpen, isFalse);
    });
  });

  group('kioskCountdown', () {
    /// A screen of the app with its messenger, and the notice asked on it; [shownBefore] a message already on screen
    Future<({Future<bool> open, List<bool> done})> showNotice(WidgetTester tester, {bool shownBefore = false}) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.expand())));
      final messenger = tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger));
      if (shownBefore) {
        messenger.showSnackBar(
          SnackBar(
            content: const Text('Backup paused'),
            action: SnackBarAction(label: 'Retry', onPressed: () {}),
          ),
        );
        await tester.pumpAndSettle();
      }
      final done = <bool>[];
      final open = kioskCountdown(
        messenger,
        text: 'Kiosk mode: expo_360.mp4 opens in a few seconds',
        cancelLabel: 'Cancel',
      );
      unawaited(open.then(done.add));
      await tester.pumpAndSettle();
      return (open: open, done: done);
    }

    final notice = find.text('Kiosk mode: expo_360.mp4 opens in a few seconds');

    testWidgets('Cancel: the kiosk does not open, and the notice goes', (tester) async {
      final shown = await showNotice(tester);
      expect(notice, findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await shown.open, isFalse);
      expect(notice, findsNothing);
    });

    testWidgets('no Cancel: the kiosk opens once the notice was on screen for its delay, not before', (tester) async {
      final shown = await showNotice(tester);
      expect(notice, findsOneWidget);

      await tester.pump(kioskCountdownDelay - const Duration(seconds: 1));
      expect(shown.done, isEmpty, reason: 'one second left');
      expect(notice, findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(shown.done, [true]);
      expect(await shown.open, isTrue);
      expect(notice, findsNothing);
    });

    testWidgets('swiped away: the kiosk opens at once, as without Cancel', (tester) async {
      final shown = await showNotice(tester);

      await tester.fling(notice, const Offset(0, 300), 1000);
      await tester.pumpAndSettle();

      expect(notice, findsNothing);
      expect(shown.done, [true]);
    });

    testWidgets('a message on screen before goes, so that the notice and its Cancel show at once', (tester) async {
      final shown = await showNotice(tester, shownBefore: true);

      expect(find.text('Backup paused'), findsNothing);
      expect(notice, findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await shown.open, isFalse);
    });
  });

  testWidgets('the end card says the text typed, else "Thank you for the journey", and the notice how to leave', (
    tester,
  ) async {
    late Translations t;
    await tester.pumpConsumerWidget(
      Builder(
        builder: (context) {
          t = context.t;
          return const SizedBox.shrink();
        },
      ),
    );

    expect(
      kioskOptions(const KioskConfig(), t),
      const KioskOptions(
        endText: 'Thank you for the journey',
        exitHint: 'Kiosk mode: hold B or Y for one second to leave',
      ),
    );
    expect(kioskOptions(const KioskConfig(endText: 'Merci et à bientôt'), t).endText, 'Merci et à bientôt');
    expect(t.kiosk_mode_opening_soon(name: 'expo_360.mp4'), 'Kiosk mode: expo_360.mp4 opens in a few seconds');
  });
}
