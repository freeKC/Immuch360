import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/phone_gallery.repository.dart';

LocalAsset _asset(String id, DateTime createdAt, {AssetType type = AssetType.image}) => LocalAsset(
  id: id,
  name: '$id.${type == AssetType.video ? 'mp4' : 'jpg'}',
  type: type,
  createdAt: createdAt,
  updatedAt: createdAt,
  playbackStyle: type == AssetType.video ? AssetPlaybackStyle.video : AssetPlaybackStyle.image,
  isEdited: false,
);

void main() {
  late Drift db;
  late LocalAlbumRepository albums;
  late PhoneGalleryRepository gallery;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    albums = LocalAlbumRepository(db);
    gallery = PhoneGalleryRepository(db, albums);

    // Mid-month dates in local time, whatever the time zone of the machine running the tests
    await albums.upsert(
      LocalAlbum(id: 'camera', name: 'Camera', updatedAt: DateTime.utc(2026, 9, 30)),
      toUpsert: [
        _asset('1', DateTime(2026, 9, 4, 10)),
        _asset('2', DateTime(2026, 9, 20, 10), type: AssetType.video),
        _asset('3', DateTime(2026, 8, 15, 10)),
        _asset('4', DateTime(2026, 9, 21, 10), type: AssetType.audio),
      ],
    );
    await albums.upsert(
      LocalAlbum(id: 'downloads', name: 'Downloads', updatedAt: DateTime.utc(2026, 9, 1)),
      toUpsert: [_asset('5', DateTime(2025, 12, 24, 18))],
    );
  });

  tearDown(() => db.close());

  test('lists the albums by name', () async {
    expect([for (final album in await gallery.albums()) album.name], ['Camera', 'Downloads']);
  });

  test('the assets of an album are its photos and videos', () async {
    expect([for (final asset in await gallery.albumAssets('camera')) asset.id]..sort(), ['1', '2', '3']);
  });

  test('counts the photos and videos per month in local time, the newest month first', () async {
    expect(await gallery.months(), [
      (year: 2026, month: 9, count: 2),
      (year: 2026, month: 8, count: 1),
      (year: 2025, month: 12, count: 1),
    ]);
  });

  test('the assets of a month are the ones its count tells, the newest first', () async {
    expect([for (final asset in await gallery.monthAssets(2026, 9)) asset.id], ['2', '1']);
    expect([for (final asset in await gallery.monthAssets(2025, 12)) asset.id], ['5']);
    expect(await gallery.monthAssets(2024, 1), isEmpty);
  });

  test('finds assets by id, photos and videos only, the newest first', () async {
    final found = await gallery.assetsByIds(['3', '1', '4', 'unknown', '1']);

    expect([for (final asset in found) asset.id], ['1', '3']);
  });

  test('finds more assets than one query may name', () async {
    await albums.upsert(
      LocalAlbum(id: 'many', name: 'Many', updatedAt: DateTime.utc(2026)),
      toUpsert: [for (var i = 0; i < 1200; i++) _asset('m$i', DateTime(2026, 1, 1).add(Duration(minutes: i)))],
    );

    final found = await gallery.assetsByIds([for (var i = 0; i < 1200; i++) 'm$i']);

    expect(found, hasLength(1200));
    expect(found.first.id, 'm1199');
  });
}
