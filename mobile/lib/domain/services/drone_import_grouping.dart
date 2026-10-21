// How the DJI drone page shows the files of a drone, a controller or a card: the photos and videos by day, the newest
// first, with the files a camera writes beside them attached rather than listed (see NetworkEntry.companionExtensions),
// and the source shots of a sphere grouped with the sphere stitched from them.
//
// DJI names: DJI_YYYYMMDDHHMMSS_NNNN_D.JPG (local time of the drone, then a sequence number), older DJI_NNNN.JPG. A
// video DJI_..._0002_D.MP4 has its proxy DJI_..._0002_D.LRF, its flight data DJI_..._0002_D.SRT and, when the phone
// recorded its sound, DJI_..._0002_D.m4a. The source shots of a sphere sit in DCIM/PANORAMA/<nnn>_<seq>/ when the user
// keeps them, <seq> being the sequence number of the sphere (DJI_..._0042_D.JPG and PANORAMA/001_0042). GoPro:
// GX010042.MP4 with GL010042.LRV and GX010042.THM. Insta360: its LRV_ proxies are named apart and only hidden.
//
// Pure Dart: the page lists the files, this tells how to show them.

import 'package:collection/collection.dart';
import 'package:immich_mobile/domain/models/network_source.dart';

/// A photo or a video of the drone page, with what was found beside it
class DroneMedia {
  const DroneMedia({
    required this.entry,
    required this.takenAt,
    this.proxy,
    this.flightData,
    this.soundApart,
    this.cameraThumbnail,
    this.sphereSources = const [],
  });

  final NetworkEntry entry;

  /// When it was taken: from a DJI name (local time), else the date of the file, in local time
  final DateTime takenAt;

  /// The low resolution copy of a video (.LRF, .LRV), for a quick frame
  final NetworkEntry? proxy;

  /// The .SRT of a DJI video, which places it on the map (see dji_srt.dart)
  final NetworkEntry? flightData;

  /// The sound of a DJI video recorded by the phone apart (.m4a): the video itself is silent
  final NetworkEntry? soundApart;

  /// The thumbnail a GoPro writes beside its videos (.THM)
  final NetworkEntry? cameraThumbnail;

  /// The source shots of a sphere stitched from them, never ticked by "Select all new"
  final List<NetworkEntry> sphereSources;

  /// Whether the server refuses it (DJI .osv, GoPro .360): shown, kept on the device, never sent
  bool get isRefused => entry.isRefusedByServer;
}

/// The source shots of a sphere that was not stitched on the drone (DJI Fly stitches the Mini 2 ones on the phone), or
/// whose sphere is not in the folder
class DroneSourceGroup {
  const DroneSourceGroup({required this.folder, required this.sources, required this.takenAt});

  /// The folder of the shots, "/DCIM/PANORAMA/001_0042"
  final String folder;
  final List<NetworkEntry> sources;
  final DateTime takenAt;
}

/// The media of one day, the newest first, and the source groups without a sphere of that day
class DroneDay {
  const DroneDay({required this.day, required this.media, this.unstitched = const []});

  /// Local midnight
  final DateTime day;
  final List<DroneMedia> media;
  final List<DroneSourceGroup> unstitched;
}

/// What the drone page shows, see [groupDroneFiles]
class DroneImportListing {
  const DroneImportListing({required this.days});

  final List<DroneDay> days;

  /// Every photo and video shown, the sources of the spheres included, in the order of the page
  Iterable<NetworkEntry> get allMedia => days.expand(
    (day) => [
      for (final media in day.media) ...[media.entry, ...media.sphereSources],
      for (final group in day.unstitched) ...group.sources,
    ],
  );

  /// The media of the page by path, sources included
  Map<String, DroneMedia> get byPath => {
    for (final day in days)
      for (final media in day.media) media.entry.path: media,
  };

  bool get isEmpty => days.isEmpty;
}

// DJI_20261021143000_0001_D.JPG: the local time of the drone, then the sequence number
final _djiName = RegExp(r'^DJI_(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})_(\d{3,4})', caseSensitive: false);
// DJI_0042.JPG, the older names
final _olderDjiName = RegExp(r'^DJI_(\d{4})\.', caseSensitive: false);
// PANORAMA/001_0042
final _panoramaFolder = RegExp(r'^(\d+)_(\d+)$');
// GoPro: GL010042.LRV is the proxy of GX010042.MP4 (or GH010042.MP4)
final _goProProxy = RegExp(r'^GL(\d{6})$', caseSensitive: false);

/// How long before its sphere the source shots of a sphere may be taken
const sphereSourcesWindow = Duration(minutes: 10);

/// The local time a DJI name tells ("DJI_20261021143000_0001_D.JPG" gives 21 October 2026 at 14:30:00), null for
/// another name
DateTime? djiNameTime(String name) {
  final match = _djiName.firstMatch(name);
  if (match == null) {
    return null;
  }
  int part(int group) => int.parse(match.group(group)!);
  final time = DateTime(part(1), part(2), part(3), part(4), part(5), part(6));
  // A clock never set gives no date
  return time.year < 2010 || time.month != part(2) || time.day != part(3) ? null : time;
}

/// The sequence number of a DJI photo by its name ("_0042_" or "DJI_0042."), null for another name
int? djiSequenceNumber(String name) {
  final match = _djiName.firstMatch(name);
  if (match != null) {
    return int.parse(match.group(7)!);
  }
  final older = _olderDjiName.firstMatch(name);
  return older == null ? null : int.parse(older.group(1)!);
}

/// When [entry] was taken: the time of its DJI name, else the date of the file in local time, else [fallback]
DateTime droneTakenAt(NetworkEntry entry, {DateTime? fallback}) =>
    djiNameTime(entry.name) ?? entry.modified?.toLocal() ?? fallback ?? DateTime.fromMillisecondsSinceEpoch(0);

String _stemOf(String name) {
  final dot = name.lastIndexOf('.');
  return (dot < 0 ? name : name.substring(0, dot)).toLowerCase();
}

String _folderOf(String path) {
  final slash = path.lastIndexOf('/');
  return slash <= 0 ? '/' : path.substring(0, slash);
}

/// Groups [files], the files found on a drone, a controller or a card (folders left out), for the drone page: the
/// photos and videos by day, the newest first; their companions attached by name in the same folder and never listed;
/// the folders `PANORAMA/<nnn>_<seq>` matched with the sphere of the same sequence number taken at most
/// [sphereSourcesWindow] after them, else shown as source shots not stitched. Files of other kinds are left out.
DroneImportListing groupDroneFiles(Iterable<NetworkEntry> files) {
  final media = <NetworkEntry>[];
  // Companions by folder and stem
  final companions = <(String, String), List<NetworkEntry>>{};
  // The source shots by their PANORAMA folder
  final panoramaFolders = <String, List<NetworkEntry>>{};
  for (final file in files) {
    if (file.isDirectory) {
      continue;
    }
    final folder = _folderOf(file.path);
    if (file.isCompanion) {
      var stem = _stemOf(file.name);
      final goPro = _goProProxy.firstMatch(stem);
      if (goPro != null) {
        stem = 'gx${goPro.group(1)}';
      }
      companions.putIfAbsent((folder, stem), () => []).add(file);
      continue;
    }
    if (!file.isMedia) {
      continue;
    }
    final parent = folder.split('/').last;
    final grandParent = _folderOf(folder).split('/').last;
    if (file.isImage && grandParent.toUpperCase() == 'PANORAMA' && _panoramaFolder.hasMatch(parent)) {
      panoramaFolders.putIfAbsent(folder, () => []).add(file);
      continue;
    }
    media.add(file);
  }

  NetworkEntry? companion(NetworkEntry file, Set<String> extensions) {
    final folder = _folderOf(file.path);
    var stem = _stemOf(file.name);
    // GoPro: GH010042.MP4 and GX010042.MP4 share the proxy GL010042.LRV
    if (RegExp(r'^g[hx]\d{6}$').hasMatch(stem)) {
      stem = 'gx${stem.substring(2)}';
    }
    return companions[(folder, stem)]?.firstWhereOrNull((entry) => extensions.contains(entry.extension));
  }

  // The spheres by sequence number, to match the source folders with
  final spheresBySequence = <int, List<NetworkEntry>>{};
  for (final file in media) {
    final sequence = file.isImage ? djiSequenceNumber(file.name) : null;
    if (sequence != null) {
      spheresBySequence.putIfAbsent(sequence, () => []).add(file);
    }
  }
  final sourcesOf = <String, List<NetworkEntry>>{};
  final unstitched = <DroneSourceGroup>[];
  for (final MapEntry(key: folder, value: sources) in panoramaFolders.entries) {
    sources.sortBy((entry) => entry.name.toLowerCase());
    final sequence = int.parse(_panoramaFolder.firstMatch(folder.split('/').last)!.group(2)!);
    final lastShot = sources.map(droneTakenAt).max;
    final sphere = spheresBySequence[sequence]?.firstWhereOrNull((candidate) {
      final taken = droneTakenAt(candidate);
      // The sphere comes after its shots, within the window; a file date may be a little earlier than the last shot
      return !taken.isBefore(lastShot.subtract(const Duration(minutes: 1))) &&
          taken.difference(lastShot) <= sphereSourcesWindow;
    });
    if (sphere == null) {
      unstitched.add(DroneSourceGroup(folder: folder, sources: sources, takenAt: lastShot));
    } else {
      (sourcesOf[sphere.path] ??= []).addAll(sources);
    }
  }

  final items = [
    for (final file in media)
      DroneMedia(
        entry: file,
        takenAt: droneTakenAt(file),
        proxy: file.isVideo ? companion(file, const {'lrf', 'lrv'}) : null,
        flightData: file.isVideo ? companion(file, const {'srt'}) : null,
        soundApart: file.isVideo ? companion(file, const {'m4a'}) : null,
        cameraThumbnail: file.isVideo ? companion(file, const {'thm'}) : null,
        sphereSources: sourcesOf[file.path] ?? const [],
      ),
  ];

  DateTime dayOf(DateTime time) => DateTime(time.year, time.month, time.day);
  final byDay = <DateTime, List<DroneMedia>>{};
  for (final item in items) {
    byDay.putIfAbsent(dayOf(item.takenAt), () => []).add(item);
  }
  final unstitchedByDay = <DateTime, List<DroneSourceGroup>>{};
  for (final group in unstitched) {
    unstitchedByDay.putIfAbsent(dayOf(group.takenAt), () => []).add(group);
  }
  final days = {...byDay.keys, ...unstitchedByDay.keys}.toList()..sort((a, b) => b.compareTo(a));
  return DroneImportListing(
    days: [
      for (final day in days)
        DroneDay(
          day: day,
          // The newest first; the same time by name
          media: (byDay[day] ?? [])
            ..sort((a, b) {
              final byTime = b.takenAt.compareTo(a.takenAt);
              return byTime != 0 ? byTime : b.entry.name.compareTo(a.entry.name);
            }),
          unstitched: (unstitchedByDay[day] ?? [])..sort((a, b) => b.takenAt.compareTo(a.takenAt)),
        ),
    ],
  );
}

/// The files "Select all new" ticks among [listing]: every photo and video not sent before ([wasSent]), the source
/// shots of spheres excepted, and the files the server refuses
List<NetworkEntry> droneNewFiles(DroneImportListing listing, bool Function(NetworkEntry entry) wasSent) => [
  for (final day in listing.days)
    for (final media in day.media)
      if (!media.isRefused && !wasSent(media.entry)) media.entry,
];
