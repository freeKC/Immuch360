// Immuch360: the assets at some indexes of the main timeline, read in one pass, for its months and years
// (presentation/widgets/timeline/overview/). Their blocks ask for a few assets a month from all over the library. A
// LIMIT/OFFSET read of the merged timeline (mergedAsset) steps through every asset before its offset: 55 ms for one
// asset at 40,000 on a PC, and the first screen of the years made 42 such reads on a library of 52,000. Here the
// timeline is numbered once and only the rows wanted come back: 57 ms on that PC for one asset of each of its 180
// months.
//
// The filters and the order are those of mergedAsset in data/db/main/query/merged_asset.drift; a change there belongs
// here too (timeline_overview_repository_test.dart compares the two on the same library).

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

/// The assets read at the indexes asked for, and the number of assets of the timeline when they were read
typedef TimelineAssetsAt = ({int total, Map<int, BaseAsset> assets});

class TimelineOverviewRepository {
  const TimelineOverviewRepository(this._db);

  final Drift _db;

  /// The most ids in one `IN` list
  static const _chunk = 500;

  /// The assets of the merged timeline of [userIds] (TimelineRepository.main) at [indexes]; those past its end are
  /// left out. The total tells whether the indexes still point where the caller took them.
  Future<TimelineAssetsAt> mergedAssetsAt(List<String> userIds, List<int> indexes) async {
    if (indexes.isEmpty) {
      return (total: 0, assets: const <int, BaseAsset>{});
    }
    final wanted = indexes.toSet();
    final rows = await _db
        .customSelect(
          _numberedMergedSql,
          variables: [Variable.withString(jsonEncode(userIds)), Variable.withString(jsonEncode(wanted.toList()))],
          readsFrom: {
            _db.remoteAssetEntity,
            _db.localAssetEntity,
            _db.stackEntity,
            _db.localAlbumEntity,
            _db.localAlbumAssetEntity,
          },
        )
        .get();

    var total = 0;
    final remoteAt = <String, int>{};
    final localIdOfRemote = <String, String?>{};
    final localAt = <String, int>{};
    for (final row in rows) {
      total = row.read<int>('total');
      final index = row.read<int>('idx');
      if (!wanted.contains(index)) {
        // The first row, read for the total
        continue;
      }
      final remoteId = row.readNullable<String>('remote_id');
      if (remoteId != null) {
        remoteAt[remoteId] = index;
        localIdOfRemote[remoteId] = row.readNullable<String>('remote_local_id');
      } else {
        localAt[row.read<String>('local_id')] = index;
      }
    }

    final assets = <int, BaseAsset>{};
    final remoteIds = remoteAt.keys.toList(growable: false);
    for (var start = 0; start < remoteIds.length; start += _chunk) {
      final ids = remoteIds.sublist(start, (start + _chunk).clamp(0, remoteIds.length));
      final entities = await (_db.remoteAssetEntity.select()..where((row) => row.id.isIn(ids))).get();
      for (final entity in entities) {
        assets[remoteAt[entity.id]!] = entity.toDto(localId: localIdOfRemote[entity.id]);
      }
    }
    final localIds = localAt.keys.toList(growable: false);
    for (var start = 0; start < localIds.length; start += _chunk) {
      final ids = localIds.sublist(start, (start + _chunk).clamp(0, localIds.length));
      final entities = await (_db.localAssetEntity.select()..where((row) => row.id.isIn(ids))).get();
      for (final entity in entities) {
        assets[localAt[entity.id]!] = entity.toDto();
      }
    }
    return (total: total, assets: assets);
  }
}

/// The merged timeline numbered from 0 in its order, its rows at the indexes of ?2 and its first row (for the total).
/// ?1 is the JSON list of the users, ?2 that of the indexes.
const _numberedMergedSql = '''
WITH merged AS (
  SELECT
    rae.id AS remote_id,
    NULL AS local_id,
    rae.checksum AS checksum,
    rae.created_at AS created_at,
    rae.group_date AS group_date
  FROM remote_asset_entity rae
  LEFT JOIN stack_entity se ON rae.stack_id = se.id
  WHERE rae.deleted_at IS NULL
    AND rae.visibility = 0
    AND rae.owner_id IN (SELECT value FROM json_each(?1))
    AND rae.group_date IS NOT NULL
    AND (rae.stack_id IS NULL OR rae.id = se.primary_asset_id)
  UNION ALL
  SELECT
    NULL AS remote_id,
    lae.id AS local_id,
    lae.checksum AS checksum,
    lae.created_at AS created_at,
    lae.group_date AS group_date
  FROM local_asset_entity lae
  WHERE NOT EXISTS (
      SELECT 1 FROM remote_asset_entity rae
      WHERE rae.checksum = lae.checksum AND rae.owner_id IN (SELECT value FROM json_each(?1))
    )
    AND EXISTS (
      SELECT 1 FROM local_album_asset_entity laa
      INNER JOIN local_album_entity la ON laa.album_id = la.id
      WHERE laa.asset_id = lae.id AND la.backup_selection = 0
    )
    AND NOT EXISTS (
      SELECT 1 FROM local_album_asset_entity laa
      INNER JOIN local_album_entity la ON laa.album_id = la.id
      WHERE laa.asset_id = lae.id AND la.backup_selection = 2
    )
    AND lae.group_date IS NOT NULL
),
numbered AS (
  SELECT
    remote_id,
    local_id,
    checksum,
    ROW_NUMBER() OVER (ORDER BY group_date DESC, created_at DESC) - 1 AS idx,
    COUNT(*) OVER () AS total
  FROM merged
)
SELECT
  n.idx AS idx,
  n.total AS total,
  n.remote_id AS remote_id,
  n.local_id AS local_id,
  CASE WHEN n.remote_id IS NOT NULL THEN (
    SELECT lae.id FROM local_asset_entity lae WHERE lae.checksum = n.checksum LIMIT 1
  ) END AS remote_local_id
FROM numbered n
WHERE n.idx = 0 OR n.idx IN (SELECT value FROM json_each(?2))
''';
