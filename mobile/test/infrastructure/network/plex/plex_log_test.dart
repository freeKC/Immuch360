// A whole Plex session with every log record kept: the token, the address outside home the server tells, the titles
// and the server paths of the library appear in no record and no exception message.

import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_pairing.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/providers/network/plex_learned_addresses.provider.dart';
import 'package:logging/logging.dart';

import 'fake_plex_server.dart';

void main() {
  test('the token, the public address, titles and paths stay out of logs and errors', () async {
    final records = <LogRecord>[];
    final errors = <Object>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await subscription.cancel();
      Logger.root.level = previousLevel;
    });

    final db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    final store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    addTearDown(() async {
      await store.dispose();
      await db.close();
    });
    final learned = PlexLearnedAddressStore(store);
    final home = await FakePlexServer.start();
    final outside = await FakePlexServer.start();
    addTearDown(outside.close);

    Future<void> expectFailure(Future<Object?> action) async {
      try {
        await action;
      } catch (error) {
        errors.add(error);
      }
    }

    const source = NetworkSource(
      id: '0123456789abcdef',
      type: NetworkSourceType.plex,
      name: 'Test Plex',
      host: '192.0.2.20',
      useTls: true,
      discoveryId: plexTestMachine,
      plex: PlexServerInfo(hash: plexTestHash),
    );

    // Pairing: a refused token, then the right one
    final pairing = PlexPairing(
      probeHash: (_, _) async => plexTestHash,
      clientFor: (_) => IOClient(HttpClient()),
      baseOf: (_) => home.base,
      clientIdentifier: () async => 'client-test-0000',
    );
    final found = await pairing.lookUp(parsePlexAddress('192.168.1.20'));
    await expectFailure(pairing.testToken(found, 'WRONG-TOKEN-000000000'));
    await pairing.testToken(found, plexTestToken);

    // A session at home, its folders, reads, sizes, pictures, a rescan, a refusal, then the switch outside home
    final plex = await PlexFileSystem.open(
      source,
      plexTestToken,
      baseOverride: home.base,
      publicBaseOverride: outside.base,
      clientIdentifier: 'client-test-0000',
      learned: learned,
    );
    await plex.list('/');
    final holidays = await plex.list('/Movies/Holidays');
    await plex.stat('/Movies/Holidays/beach (2).mp4');
    await plex.readRange('/Movies/Holidays/beach.mp4', 0, 100);
    await plex.thumbnail(holidays.firstWhere((e) => e.name == 'beach.mp4'), 256);
    await plex.list('/Photos');
    home.statuses['/library/sections/1/folder?parent=101'] = 404;
    await expectFailure(plex.list('/Movies/Holidays'));
    home.forbidden = true;
    await expectFailure(plex.readRange('/Movies/a.mp4', 0, 10));
    home.forbidden = false;
    await home.close();
    await plex.readRange('/Movies/a.mp4', 0, 10);
    outside.token = 'REVOKED';
    await expectFailure(plex.list('/Movies'));
    await plex.close();
    await expectFailure(
      PlexFileSystem.open(source, 'WRONG-TOKEN-000000000', baseOverride: outside.base, clientIdentifier: 'c'),
    );

    expect(records, isNotEmpty);
    expect(errors, hasLength(5));
    final told = [
      for (final record in records) ...[record.message, '${record.error ?? ''}', '${record.stackTrace ?? ''}'],
      for (final error in errors) '$error',
    ].join('\n');
    for (final secret in [
      plexTestToken,
      'WRONG-TOKEN-000000000',
      'TEST-ACCOUNT-TOKEN-0000',
      'test-user',
      '203.0.113.7',
      'Holidays',
      'beach',
      '/data/',
      'metadata/21',
    ]) {
      expect(told, isNot(contains(secret)), reason: secret);
    }
  });
}
