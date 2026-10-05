// What the 360° page of the Library lists, and how the user narrows it down: the entries (one per photo or video,
// wherever its copies are), the filters of the bar above the grid, and what the bar offers for them (the facets).

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';

/// Where a media of the 360° page is
enum Panorama360Source { server, device, shared }

/// Photo or video chip
enum Panorama360Kind { photo, video }

/// What the viewers will show, as far as the app knows without reading the file again
enum Panorama360Trait { stereo3d, vr180 }

/// The period chip: a year, a month, or a range of days, both ends included
sealed class Panorama360Period {
  const Panorama360Period();

  /// Whether [day], a local day at midnight, falls in the period
  bool contains(DateTime day);
}

final class Panorama360Year extends Panorama360Period {
  const Panorama360Year(this.year);

  final int year;

  @override
  bool contains(DateTime day) => day.year == year;

  @override
  bool operator ==(Object other) => other is Panorama360Year && other.year == year;

  @override
  int get hashCode => year.hashCode;
}

final class Panorama360Month extends Panorama360Period {
  const Panorama360Month(this.year, this.month);

  final int year;
  final int month;

  @override
  bool contains(DateTime day) => day.year == year && day.month == month;

  @override
  bool operator ==(Object other) => other is Panorama360Month && other.year == year && other.month == month;

  @override
  int get hashCode => Object.hash(year, month);
}

final class Panorama360Range extends Panorama360Period {
  /// [first] and [last] are truncated to their local day
  Panorama360Range(DateTime first, DateTime last)
    : first = DateTime(first.year, first.month, first.day),
      last = DateTime(last.year, last.month, last.day);

  final DateTime first;
  final DateTime last;

  @override
  bool contains(DateTime day) => !day.isBefore(first) && !day.isAfter(last);

  @override
  bool operator ==(Object other) => other is Panorama360Range && other.first == first && other.last == last;

  @override
  int get hashCode => Object.hash(first, last);
}

/// The chips selected in the filter bar of the 360° page. Within one group the chips are OR, between groups AND; an
/// empty group lets everything through.
class Panorama360Filter {
  static const defaultSources = {Panorama360Source.server, Panorama360Source.device};

  const Panorama360Filter({
    this.period,
    this.sources = defaultSources,
    this.kinds = const {},
    this.traits = const {},
    this.cameras = const {},
  });

  final Panorama360Period? period;

  /// Never empty: the filter bar refuses to unselect the last one. Ignored without a server.
  final Set<Panorama360Source> sources;

  final Set<Panorama360Kind> kinds;

  final Set<Panorama360Trait> traits;

  /// Keys of [Panorama360Camera], '' for the unknown camera
  final Set<String> cameras;

  bool get isDefault =>
      period == null && setEquals(sources, defaultSources) && kinds.isEmpty && traits.isEmpty && cameras.isEmpty;

  Panorama360Filter copyWith({
    Panorama360Period? Function()? period,
    Set<Panorama360Source>? sources,
    Set<Panorama360Kind>? kinds,
    Set<Panorama360Trait>? traits,
    Set<String>? cameras,
  }) => Panorama360Filter(
    period: period == null ? this.period : period(),
    sources: sources ?? this.sources,
    kinds: kinds ?? this.kinds,
    traits: traits ?? this.traits,
    cameras: cameras ?? this.cameras,
  );

  @override
  bool operator ==(Object other) =>
      other is Panorama360Filter &&
      other.period == period &&
      setEquals(other.sources, sources) &&
      setEquals(other.kinds, kinds) &&
      setEquals(other.traits, traits) &&
      setEquals(other.cameras, cameras);

  @override
  int get hashCode => Object.hash(
    period,
    const SetEquality<Panorama360Source>().hash(sources),
    const SetEquality<Panorama360Kind>().hash(kinds),
    const SetEquality<Panorama360Trait>().hash(traits),
    const SetEquality<String>().hash(cameras),
  );

  @override
  String toString() =>
      'Panorama360Filter(period: $period, sources: $sources, kinds: $kinds, traits: $traits, cameras: $cameras)';
}

/// A camera chip: [key] groups the media, [label] names it ('' key: unknown camera, label from the translations)
typedef Panorama360Camera = ({String key, String label});

/// One photo or video of the 360° page
class Panorama360Entry {
  Panorama360Entry({
    required this.asset,
    required this.day,
    this.isOwn = true,
    this.make,
    this.model,
    this.flagged = false,
  });

  /// A RemoteAsset (its localId set when a copy is on the device) or a LocalAsset that is on the device only
  final BaseAsset asset;

  /// Local calendar day at midnight, the day of its bucket
  final DateTime day;

  /// False for a remote asset of another user
  final bool isOwn;

  final String? make;
  final String? model;

  /// The server exif says EQUIRECTANGULAR
  final bool flagged;

  late final Panorama360Camera camera = panorama360CameraOf(make: make, model: model, fileName: asset.name);

  late final Set<Panorama360Source> sources = {
    if (asset.remoteId != null && isOwn) Panorama360Source.server,
    if (asset.localId != null) Panorama360Source.device,
    if (asset.remoteId != null && !isOwn) Panorama360Source.shared,
  };

  @override
  String toString() => 'Panorama360Entry(${asset.name}, $day, own: $isOwn, camera: ${camera.label})';
}

// Makers whose exif name is not the brand people know
const _makeAliases = {'arashi vision': 'Insta360'};

/// The camera chip of a media: its exif make and model, a make alias ("Arashi Vision" is Insta360), the model alone
/// when it already starts with the make. Without exif, a raw file is named after the brand its extension belongs to
/// (Insta360 .insp and .insv, GoPro .360, DJI .osv), and anything else is the unknown camera (key '').
Panorama360Camera panorama360CameraOf({String? make, String? model, required String fileName}) {
  final cleanMake = make?.trim();
  final cleanModel = model?.trim();
  final shownMake = (cleanMake == null || cleanMake.isEmpty)
      ? null
      : (_makeAliases[cleanMake.toLowerCase()] ?? cleanMake);
  final shownModel = (cleanModel == null || cleanModel.isEmpty) ? null : cleanModel;
  final String? label = switch ((shownMake, shownModel)) {
    (null, null) => _rawBrandOf(fileName),
    (final String make, null) => make,
    (null, final String model) => model,
    (final String make, final String model) =>
      model.toLowerCase().startsWith(make.toLowerCase()) ? model : '$make $model',
  };
  return label == null ? (key: '', label: '') : (key: label.toLowerCase(), label: label);
}

// The brand of a raw 360° file by its name: the server keeps no make for those it cannot read, and the device none
String? _rawBrandOf(String fileName) {
  if (isRawPhotoName(fileName)) {
    return 'Insta360';
  }
  return switch (rawMediaKindOfName(fileName, isVideo: true)) {
    RawMediaKind.insta360Photo || RawMediaKind.insta360Video => 'Insta360',
    RawMediaKind.goProVideo => 'GoPro',
    RawMediaKind.djiVideo => 'DJI',
    null => null,
  };
}

typedef Panorama360CameraCount = ({String key, String label, int count});

/// What the filter bar offers, from the candidates of the page
class Panorama360Facets {
  const Panorama360Facets({
    this.total = 0,
    this.cameras = const [],
    this.months = const {},
    this.firstDay,
    this.lastDay,
    this.availableSources = const {},
  });

  /// Candidates before any filter
  final int total;

  /// Cameras of the candidates that pass every filter but the camera one, most media first, the unknown camera last;
  /// a selected camera is listed even with no media left
  final List<Panorama360CameraCount> cameras;

  /// Year, then month, then count, of the candidates that pass every filter but the period one, newest first
  final Map<int, Map<int, int>> months;

  /// Oldest and newest day of all the candidates, for the date range picker
  final DateTime? firstDay;
  final DateTime? lastDay;

  /// Sources that hold at least one candidate
  final Set<Panorama360Source> availableSources;

  static const _equality = DeepCollectionEquality();

  @override
  bool operator ==(Object other) =>
      other is Panorama360Facets &&
      other.total == total &&
      other.firstDay == firstDay &&
      other.lastDay == lastDay &&
      const ListEquality<Panorama360CameraCount>().equals(other.cameras, cameras) &&
      _equality.equals(other.months, months) &&
      setEquals(other.availableSources, availableSources);

  @override
  int get hashCode => Object.hash(
    total,
    firstDay,
    lastDay,
    const ListEquality<Panorama360CameraCount>().hash(cameras),
    _equality.hash(months),
    const SetEquality<Panorama360Source>().hash(availableSources),
  );
}

/// What the 360° page shows: the entries that pass the filter, in order, their buckets, and the facets
class Panorama360View {
  const Panorama360View({this.entries = const [], this.buckets = const [], this.facets = const Panorama360Facets()});

  final List<Panorama360Entry> entries;
  final List<Bucket> buckets;
  final Panorama360Facets facets;
}
