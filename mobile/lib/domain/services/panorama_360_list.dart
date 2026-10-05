// The list of the 360° page of the Library, computed in memory from the candidates the database gives (see
// Panorama360Repository): one entry per photo or video wherever its copies are, in timeline order, narrowed down by
// the filter bar. SQL cannot do it: the copies merge by checksum across the server and the device, a split recording
// shows once, and the 3D and VR180 traits come from stores and guesses the database does not hold.

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/panorama_360.model.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

/// Newest day first, then newest instant, then hero tag
int comparePanorama360Entries(Panorama360Entry a, Panorama360Entry b) {
  final byDay = b.day.compareTo(a.day);
  if (byDay != 0) {
    return byDay;
  }
  final byInstant = b.asset.createdAt.compareTo(a.asset.createdAt);
  if (byInstant != 0) {
    return byInstant;
  }
  return b.asset.heroTag.compareTo(a.asset.heroTag);
}

// Which copy of a file stands for it: the own one on the server, whose localId tells of a copy on the device, then the
// one on the device, then one shared by another user
int _rank(Panorama360Entry entry) => entry.asset.remoteId == null ? 1 : (entry.isOwn ? 0 : 2);

// Whose file it is, for the split recordings: a pair is kept together by one owner, the device being one
String _ownerOf(Panorama360Entry entry) {
  final asset = entry.asset;
  return asset is RemoteAsset ? asset.ownerId : 'device';
}

/// One entry per asset and per file, sorted (see [comparePanorama360Entries]):
/// - per checksum (null checksums never merge): an own remote entry first, then a device entry, then a shared one,
///   the first of each kind in input order;
/// - the second lens file of a split Insta360 recording (_10_) is left out when the first lens file (_00_) of the
///   same owner (owner id, or 'device') is listed: the player opens the pair from the first one.
List<Panorama360Entry> mergePanorama360Candidates(Iterable<Panorama360Entry> candidates) {
  final byChecksum = <String, Panorama360Entry>{};
  final merged = <Panorama360Entry>[];
  for (final entry in candidates) {
    final checksum = entry.asset.checksum;
    if (checksum == null) {
      merged.add(entry);
      continue;
    }
    final kept = byChecksum[checksum];
    if (kept == null || _rank(entry) < _rank(kept)) {
      byChecksum[checksum] = entry;
    }
  }
  merged.addAll(byChecksum.values);

  final names = {for (final entry in merged) (_ownerOf(entry), entry.asset.name.toLowerCase())};
  bool isSecondLensOfListedPair(Panorama360Entry entry) {
    final firstLens = splitFirstLensName(entry.asset.name);
    return firstLens != null && names.contains((_ownerOf(entry), firstLens.toLowerCase()));
  }

  return merged.where((entry) => !isSecondLensOfListedPair(entry)).toList()..sort(comparePanorama360Entries);
}

/// Buckets of [sorted] entries: one per local day, or per month (first day of the month), or a single one for
/// GroupAssetsBy.none; empty for no entry. GroupAssetsBy.auto counts as day.
List<Bucket> panorama360Buckets(List<Panorama360Entry> sorted, GroupAssetsBy groupBy) {
  if (sorted.isEmpty) {
    return const [];
  }
  if (groupBy == GroupAssetsBy.none) {
    return [Bucket(assetCount: sorted.length)];
  }
  DateTime dateOf(DateTime day) =>
      groupBy == GroupAssetsBy.month ? DateTime(day.year, day.month) : DateTime(day.year, day.month, day.day);

  final buckets = <Bucket>[];
  DateTime? current;
  var count = 0;
  for (final entry in sorted) {
    final date = dateOf(entry.day);
    if (date != current) {
      if (current != null) {
        buckets.add(TimeBucket(date: current, assetCount: count));
      }
      current = date;
      count = 0;
    }
    count++;
  }
  buckets.add(TimeBucket(date: current!, assetCount: count));
  return buckets;
}

/// 3D and VR180 as the viewers will show the media, from what is at hand: the coverage the user picked
/// ([chosenCoverage]), what the device scan read ([recordHalfSphere], [recordRaw]), the probe already in memory
/// ([probe]), else the guesses of resolveSphereView from the name and the frame shape. A raw file is neither: the
/// stitch fills the whole sphere with one picture.
Set<Panorama360Trait> panorama360TraitsOf(
  Panorama360Entry entry, {
  SphereCoverage? chosenCoverage,
  bool? recordHalfSphere,
  bool recordRaw = false,
  SphericalProbe? probe,
}) {
  final asset = entry.asset;
  if (recordRaw || isRaw360FileName(asset.name)) {
    return const {};
  }
  final view = resolveSphereView(
    fileName: asset.name,
    width: asset.width,
    height: asset.height,
    probe: probe,
    chosenCoverage:
        chosenCoverage ??
        switch (recordHalfSphere) {
          true => SphereCoverage.half,
          false => SphereCoverage.full,
          null => null,
        },
  );
  return {
    if (view.layout != StereoLayout.mono) Panorama360Trait.stereo3d,
    if (view.coverage == SphereCoverage.half) Panorama360Trait.vr180,
  };
}

/// Whether [entry], whose traits are [traits], passes [filter]. Without a server ([hasServer] false) every entry is
/// on this device, and the sources are ignored. The facets count without the period ([ignorePeriod]) or without the
/// cameras ([ignoreCameras]), so that the bar still offers the other choices of the group the user picked in.
bool matchesPanorama360Filter(
  Panorama360Entry entry,
  Panorama360Filter filter, {
  required bool hasServer,
  required Set<Panorama360Trait> traits,
  bool ignorePeriod = false,
  bool ignoreCameras = false,
}) {
  final period = filter.period;
  if (!ignorePeriod && period != null && !period.contains(entry.day)) {
    return false;
  }
  if (hasServer && !entry.sources.any(filter.sources.contains)) {
    return false;
  }
  if (filter.kinds.isNotEmpty &&
      !filter.kinds.contains(entry.asset.isVideo ? Panorama360Kind.video : Panorama360Kind.photo)) {
    return false;
  }
  if (filter.traits.isNotEmpty && !traits.any(filter.traits.contains)) {
    return false;
  }
  if (!ignoreCameras && filter.cameras.isNotEmpty && !filter.cameras.contains(entry.camera.key)) {
    return false;
  }
  return true;
}

/// The page for [candidates] (merged and sorted) under [filter]: the entries that pass, their buckets, and the facets
Panorama360View buildPanorama360View(
  List<Panorama360Entry> candidates,
  Panorama360Filter filter, {
  required bool hasServer,
  required Set<Panorama360Trait> Function(Panorama360Entry entry) traitsOf,
  required GroupAssetsBy groupBy,
}) {
  final entries = <Panorama360Entry>[];
  final cameraCounts = <String, int>{};
  final cameraLabels = <String, String>{};
  final months = <int, Map<int, int>>{};
  final availableSources = <Panorama360Source>{};
  DateTime? firstDay;
  DateTime? lastDay;

  for (final entry in candidates) {
    final camera = entry.camera;
    cameraLabels.putIfAbsent(camera.key, () => camera.label);
    availableSources.addAll(entry.sources);
    final day = entry.day;
    if (firstDay == null || day.isBefore(firstDay)) {
      firstDay = day;
    }
    if (lastDay == null || day.isAfter(lastDay)) {
      lastDay = day;
    }

    // Guessed once per entry, the guesses reading names and stores
    final entryTraits = traitsOf(entry);
    bool matches({bool ignorePeriod = false, bool ignoreCameras = false}) => matchesPanorama360Filter(
      entry,
      filter,
      hasServer: hasServer,
      traits: entryTraits,
      ignorePeriod: ignorePeriod,
      ignoreCameras: ignoreCameras,
    );
    if (matches()) {
      entries.add(entry);
    }
    if (matches(ignoreCameras: true)) {
      cameraCounts[camera.key] = (cameraCounts[camera.key] ?? 0) + 1;
    }
    if (matches(ignorePeriod: true)) {
      final year = months.putIfAbsent(day.year, () => {});
      year[day.month] = (year[day.month] ?? 0) + 1;
    }
  }

  for (final key in filter.cameras) {
    cameraCounts.putIfAbsent(key, () => 0);
  }
  final cameras = [
    for (final MapEntry(:key, :value) in cameraCounts.entries)
      (key: key, label: cameraLabels[key] ?? key, count: value),
  ]..sort(_compareCameras);

  final sortedMonths = <int, Map<int, int>>{
    for (final year in months.keys.toList()..sort((a, b) => b.compareTo(a)))
      year: {
        for (final month in months[year]!.keys.toList()..sort((a, b) => b.compareTo(a))) month: months[year]![month]!,
      },
  };

  return Panorama360View(
    entries: entries,
    buckets: panorama360Buckets(entries, groupBy),
    facets: Panorama360Facets(
      total: candidates.length,
      cameras: cameras,
      months: sortedMonths,
      firstDay: firstDay,
      lastDay: lastDay,
      availableSources: availableSources,
    ),
  );
}

// Most media first, then by name; the unknown camera last
int _compareCameras(Panorama360CameraCount a, Panorama360CameraCount b) {
  final aUnknown = a.key.isEmpty;
  final bUnknown = b.key.isEmpty;
  if (aUnknown != bUnknown) {
    return aUnknown ? 1 : -1;
  }
  final byCount = b.count.compareTo(a.count);
  if (byCount != 0) {
    return byCount;
  }
  final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
  return byLabel != 0 ? byLabel : a.key.compareTo(b.key);
}
