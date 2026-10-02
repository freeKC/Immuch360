// The discovery against the test servers of the machine that runs them (IMMUCH_NET_TESTS=1): Samba on 127.0.0.1 port
// 1445 (share "media", user "tester", password "testpass") and WebDAV on port 1880 (Basic, same user). See
// smb_file_system_test.dart for where libsmb2 comes from.

// ignore_for_file: invalid_use_of_internal_member

import 'dart:io';

import 'package:dart_smb2/src/ffi/native_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/infrastructure/network/smb_file_system.dart';

import 'libsmb2_test_path.dart';

void main() {
  final enabled = Platform.environment['IMMUCH_NET_TESTS'] == '1';

  setUpAll(() {
    if (enabled) {
      debugLibSmb2PathOverride = libsmb2TestPath();
    }
  });

  test('Samba answers the SMB2 NEGOTIATE', () async {
    expect(await const ServerConfirmer().isSmb('127.0.0.1', 1445), isTrue);
    expect(await const ServerConfirmer().webDavPath('127.0.0.1', 1880, useTls: false), '/');
    expect(await const ServerConfirmer().isSmb('127.0.0.1', 1880), isFalse, reason: 'the WebDAV server');
  }, skip: !enabled);

  test('discovers the Samba and WebDAV test servers, then lists the shares of Samba', () async {
    final service = createNetworkDiscoveryService(extraPorts: ScanPort.parse('1445:smb,1880:webdav'));

    final lists = await service.discover(hosts: ['127.0.0.1'], timeout: const Duration(seconds: 15)).toList();

    final found = lists.last;
    final smb = found.firstWhere((s) => s.type == NetworkSourceType.smb && s.port == 1445);
    final dav = found.firstWhere((s) => s.type == NetworkSourceType.webdav && s.port == 1880);
    expect(smb.host, '127.0.0.1');
    expect(smb.origin, DiscoveryOrigin.scan);
    expect(smb.displayName, isNotEmpty);
    expect(dav.host, '127.0.0.1');
    expect(dav.useTls, isFalse);

    final shares = await SmbFileSystem.listShares(
      NetworkSource(
        id: 'found',
        type: NetworkSourceType.smb,
        name: smb.displayName,
        host: smb.host,
        port: smb.port,
        username: 'tester',
      ),
      'testpass',
    );
    expect(shares, contains('media'));
    expect(shares.where((name) => name.endsWith(r'$')), isEmpty);
  }, skip: !enabled);
}
