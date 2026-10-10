import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/folder_library_sync_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_apis.dart';
import 'package:immich_mobile/desktop/platform/desktop_background_worker_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_connectivity_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_local_image_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_network_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_permission_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_remote_image_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_share_files_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_spatial_video_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_spherical_video_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_video_decoder_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_video_thumbnail_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_view_intent_api.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/platform/permission_api.g.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('CurrentPlatform', () {
    test('tells the computers from the phones', () {
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        final desktop = const {TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS}.contains(platform);
        expect(CurrentPlatform.isDesktop, desktop, reason: platform.name);
        expect(CurrentPlatform.isWindows, platform == TargetPlatform.windows);
        expect(CurrentPlatform.isLinux, platform == TargetPlatform.linux);
        expect(CurrentPlatform.isMacOS, platform == TargetPlatform.macOS);
      }
    });
  });

  group('PlatformApis', () {
    test('gives the generated classes on the phones', () {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        debugDefaultTargetPlatformOverride = platform;
        final apis = <Object>[
          PlatformApis.nativeSync(),
          PlatformApis.permission(),
          PlatformApis.connectivity(),
          PlatformApis.backgroundWorkerFg(),
          PlatformApis.backgroundWorkerBg(),
          PlatformApis.backgroundWorkerLock(),
          PlatformApis.sphericalVideo(),
          PlatformApis.spatialVideo(),
          PlatformApis.videoDecoder(),
          PlatformApis.videoThumbnail(),
          PlatformApis.localImage(),
          PlatformApis.remoteImage(),
          PlatformApis.network(),
          PlatformApis.phoneShare(),
          PlatformApis.viewIntent(),
        ];
        for (final api in apis) {
          // The generated classes live in lib/platform; no desktop class on a phone
          expect(api.runtimeType.toString().startsWith('Desktop'), isFalse, reason: '$platform $api');
          expect(api, isNot(isA<FolderLibrarySyncApi>()));
        }
      }
    });

    test('gives a new generated object per call on the phones, as before', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(identical(PlatformApis.nativeSync(), PlatformApis.nativeSync()), isFalse);
      expect(identical(PlatformApis.network(), PlatformApis.network()), isFalse);
    });

    test('gives the desktop implementations on the three computers', () {
      for (final platform in [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(PlatformApis.nativeSync(), isA<FolderLibrarySyncApi>());
        expect(PlatformApis.permission(), isA<DesktopPermissionApi>());
        expect(PlatformApis.connectivity(), isA<DesktopConnectivityApi>());
        expect(PlatformApis.backgroundWorkerFg(), isA<DesktopBackgroundWorkerFgHostApi>());
        expect(PlatformApis.backgroundWorkerBg(), isA<DesktopBackgroundWorkerBgHostApi>());
        expect(PlatformApis.backgroundWorkerLock(), isA<DesktopBackgroundWorkerLockApi>());
        expect(PlatformApis.sphericalVideo(), isA<DesktopSphericalVideoApi>());
        expect(PlatformApis.spatialVideo(), isA<DesktopSpatialVideoApi>());
        expect(PlatformApis.videoDecoder(), isA<DesktopVideoDecoderApi>());
        expect(PlatformApis.videoThumbnail(), isA<DesktopVideoThumbnailApi>());
        expect(PlatformApis.localImage(), isA<DesktopLocalImageApi>());
        expect(PlatformApis.remoteImage(), isA<DesktopRemoteImageApi>());
        expect(PlatformApis.network(), isA<DesktopNetworkApi>());
        expect(PlatformApis.phoneShare(), isA<DesktopShareFilesApi>());
        expect(PlatformApis.viewIntent(), isA<DesktopViewIntentHostApi>());
      }
    });

    test('keeps one desktop object for the APIs that hold state', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(identical(PlatformApis.nativeSync(), PlatformApis.nativeSync()), isTrue);
      expect(identical(PlatformApis.network(), PlatformApis.network()), isTrue);
      expect(identical(PlatformApis.localImage(), PlatformApis.localImage()), isTrue);
      expect(identical(PlatformApis.remoteImage(), PlatformApis.remoteImage()), isTrue);
      expect(identical(PlatformApis.phoneShare(), PlatformApis.phoneShare()), isTrue);
    });
  });

  group('desktop answers', () {
    test('an unmetered network, every permission granted, never started by a scheduler', () async {
      expect(await DesktopConnectivityApi().getCapabilities(), [NetworkCapability.wifi, NetworkCapability.unmetered]);
      expect(await DesktopPermissionApi().isIgnoringBatteryOptimizations(), PermissionStatus.granted);
      expect(await DesktopPermissionApi().hasManageMediaPermission(), isTrue);
      expect(await DesktopBackgroundWorkerFgHostApi().wasLaunchedInBackground(), isFalse);
    });

    test('nothing in the folder library before it is indexed, and every hash refused', () async {
      // An index of its own (the support folder of the app needs path_provider, which unit tests do not have)
      final folder = Directory.systemTemp.createTempSync('desktop_library_');
      addTearDown(() => folder.deleteSync(recursive: true));
      final api = FolderLibrarySyncApi(
        indexPath: () async => '${folder.path}/index.sqlite',
        freshScan: (_, _) async {},
      );
      // Closed before the folder goes (tear downs run in reverse): Windows does not delete an open file
      addTearDown(api.close);
      expect(await api.getAlbums(), isEmpty);
      expect((await api.getMediaChanges()).hasChanges, isFalse);
      final hashes = await api.hashAssets(['a', 'b']);
      expect(hashes.map((result) => result.assetId), ['a', 'b']);
      expect(hashes.every((result) => result.hash == null && result.error != null), isTrue);
      expect(await api.getTrashedAssets(), isEmpty);
      expect(await api.getCloudIdForAssetIds(['a']), isEmpty);
    });

    test('Spatial and 360 video players unsupported until they exist', () async {
      expect((await DesktopSpatialVideoApi().capabilities()).supported, isFalse);
      expect(DesktopSpatialVideoApi().open, isNotNull);
      expect(await DesktopVideoThumbnailApi().thumbnailForUrl('http://127.0.0.1/v', const {}, 0, 320), isEmpty);
    });

    test('the static decoder answer: up to 8K', () async {
      // Without the probe of the GPU (the tests, Linux and macOS): software up to 8192 x 8192, one row per codec
      final api = DesktopVideoDecoderApi();
      expect((await api.canDecode('video/hevc', null, 7680, 3840, 30, 10, 16)).supported, isTrue);
      expect((await api.canDecode('video/hevc', null, 16384, 8192, 30, 8, 1)).supported, isFalse);
      final rows = await api.listDecoders();
      expect(rows.every((row) => !row.hardware), isTrue);
      expect(rows.map((row) => row.codec), containsAll(DesktopVideoDecoderApi.softwareCodecs));
    });

    test('command line files come out one by one, with a type from their extension', () async {
      DesktopViewIntentHostApi.addLaunchPaths([r'C:\photos\VID_1.insv', '', r'C:\photos\IMG_2.jpg']);
      final api = DesktopViewIntentHostApi();
      final first = await api.consumeViewIntent();
      final second = await api.consumeViewIntent();
      expect(first?.path, r'C:\photos\VID_1.insv');
      expect(first?.mimeType, 'video/mp4');
      expect(second?.mimeType, 'image/jpeg');
      expect(await api.consumeViewIntent(), isNull);
    });

    test('the client certificate is kept by the network API', () async {
      final api = DesktopNetworkApi();
      expect(await api.hasCertificate(), isFalse);
      expect(await api.getAppGroupId(), '');
      expect(await api.getClientPointer(), 0);
    });
  });
}
