// What the files of the test shares of the development machine declare, read with the real clients: WebDAV and SMB
// straight from the share as the browser reads them, and through the real media bridge with range requests as the
// viewers read them. Only on that machine: IMMUCH_NET_TESTS=1, WebDAV at http://localhost:1880/ and SMB on localhost
// port 1445, share "media", user tester, password testpass (see the SMB file system test for libsmb2). No widget
// binding here: it would answer every HTTP request with an error.

// ignore_for_file: invalid_use_of_internal_member

import 'dart:io';
import 'dart:isolate';

import 'package:dart_smb2/src/ffi/native_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/infrastructure/network/smb_file_system.dart';
import 'package:immich_mobile/infrastructure/network/webdav_file_system.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';

final _enabled = Platform.environment['IMMUCH_NET_TESTS'] == '1';
const _skipReason = 'Set IMMUCH_NET_TESTS=1 to run against the test servers of the development machine';
const _password = 'testpass';

const _webDav = NetworkSource(
  id: 'dav-test',
  type: NetworkSourceType.webdav,
  name: 'Test WebDAV',
  host: 'localhost',
  port: 1880,
  username: 'tester',
);

const _smb = NetworkSource(
  id: 'smb-test',
  type: NetworkSourceType.smb,
  name: 'Test Samba',
  host: '127.0.0.1',
  port: 1445,
  share: 'media',
  username: 'tester',
);

/// What the test files declare
void _expectTestFiles(Map<String, NetworkMediaInfo?> infos) {
  NetworkMediaInfo info(String name) {
    final found = infos[name];
    expect(found, isNotNull, reason: '$name could not be read');
    return found!;
  }

  for (final name in ['mono-photo.jpg', 'stereo-lr-photo.jpg', 'stereo-tb-photo.jpg']) {
    expect(info(name).is360, isTrue, reason: '$name declares an equirectangular projection');
  }
  for (final name in ['flat-test-photo.jpg', 'vr180-photo-sbs-3840x1920.jpg']) {
    expect(info(name).is360, isFalse, reason: '$name has no GPano tags');
  }

  final mono = info('mono-video.mp4');
  expect(mono.is360, isTrue);
  expect(mono.declaresStereo, isFalse);
  expect(mono.sphereView('mono-video.mp4').layout, StereoLayout.mono);

  final topBottom = info('stereo-tb-video.mp4');
  expect(topBottom.is360, isTrue);
  expect(topBottom.declaresStereo, isTrue);
  expect(topBottom.sphereView('stereo-tb-video.mp4').layout, StereoLayout.topBottom);

  final vr180 = info('vr180-sbs-3840x1920-tagged.mp4');
  expect(vr180.is360, isTrue);
  expect(vr180.declaresStereo, isTrue);
  expect(vr180.sphereView('vr180-sbs-3840x1920-tagged.mp4').layout, StereoLayout.leftRight);
  expect(vr180.sphereView('vr180-sbs-3840x1920-tagged.mp4').coverage, SphereCoverage.half);
}

/// What every photo and video of the root of [fileSystem] declares, as [detect] reads it
Future<Map<String, NetworkMediaInfo?>> _detectAll(
  NetworkFileSystem fileSystem,
  Future<NetworkMediaInfo?> Function(NetworkEntry entry) detect,
) async {
  final entries = (await fileSystem.list('/')).where((entry) => entry.isMedia).toList();
  expect(entries, isNotEmpty);
  return {for (final entry in entries) entry.name: await detect(entry)};
}

void main() {
  group('straight from the share, as the browser reads', () {
    for (final (source, open) in <(NetworkSource, NetworkFileSystemOpener)>[
      (_webDav, WebDavFileSystem.open),
      (_smb, SmbFileSystem.open),
    ]) {
      test('${source.type.name}: tells the 360° photos and videos and their layouts', () async {
        if (source.type == NetworkSourceType.smb) {
          debugLibSmb2PathOverride = _libsmb2Path();
        }
        final fileSystem = await open(source, _password);
        addTearDown(fileSystem.close);
        final service = NetworkMediaService();

        final infos = await _detectAll(
          fileSystem,
          (entry) => service.detect(entry, networkFileReader(fileSystem, entry.path)),
        );

        _expectTestFiles(infos);
      }, skip: _enabled ? false : _skipReason);
    }
  });

  test('through the media bridge with range requests, as the viewers read', () async {
    final fileSystem = await WebDavFileSystem.open(_webDav, _password);
    addTearDown(fileSystem.close);
    final bridge = LocalMediaBridge();
    addTearDown(bridge.stop);
    await bridge.start();
    bridge.register(fileSystem);
    final client = http.Client();
    addTearDown(client.close);
    final service = NetworkMediaService();

    final infos = await _detectAll(
      fileSystem,
      (entry) => service.detect(entry, httpRangeReader(client, bridge.urlFor(_webDav.id, entry.path)), thorough: true),
    );

    _expectTestFiles(infos);
  }, skip: _enabled ? false : _skipReason);
}

/// The libsmb2 to load in the tests, as the SMB file system test finds it: null to let the loader find "libsmb2.so"
String? _libsmb2Path() {
  final given = Platform.environment['IMMUCH_LIBSMB2'];
  if (given != null && given.isNotEmpty) {
    return given;
  }
  final home = Platform.environment['HOME'];
  if (home != null) {
    final cached = File('$home/.cache/immuch-net-tests/libsmb2.so');
    if (cached.existsSync()) {
      return cached.path;
    }
  }
  final library = Isolate.resolvePackageUriSync(Uri.parse('package:dart_smb2/dart_smb2.dart'));
  if (library != null) {
    final arch = Platform.version.contains('arm64') ? 'aarch64' : 'x86_64';
    final bundled = File.fromUri(library.resolve('../linux/libs/$arch/libsmb2.so'));
    if (bundled.existsSync()) {
      return bundled.path;
    }
  }
  return null;
}
