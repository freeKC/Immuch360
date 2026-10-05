// The 360° page of the Library: its filter, kept while the app runs, and its list, which reads the database and the
// stores of the device (forced assets, scan results, coverages picked) through listeners rather than rebuilds.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/panorama_360.model.dart';
import 'package:immich_mobile/domain/models/spatial_media.dart';
import 'package:immich_mobile/domain/services/panorama_360_list.dart';
import 'package:immich_mobile/domain/services/panorama_360_list.service.dart';
import 'package:immich_mobile/infrastructure/repositories/panorama_360.repository.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';

/// The chips selected in the filter bar of the 360° page, kept while the app runs (not stored): coming back to the
/// page finds the list as the user left it
class Panorama360FilterNotifier extends Notifier<Panorama360Filter> {
  @override
  Panorama360Filter build() => const Panorama360Filter();

  void setPeriod(Panorama360Period? period) => state = state.copyWith(period: () => period);

  /// Refuses to unselect the last source: no source would list nothing
  void toggleSource(Panorama360Source source) {
    final sources = _toggled(state.sources, source);
    if (sources.isNotEmpty) {
      state = state.copyWith(sources: sources);
    }
  }

  void toggleKind(Panorama360Kind kind) => state = state.copyWith(kinds: _toggled(state.kinds, kind));

  void toggleTrait(Panorama360Trait trait) => state = state.copyWith(traits: _toggled(state.traits, trait));

  void toggleCamera(String key) => state = state.copyWith(cameras: _toggled(state.cameras, key));

  void clear() => state = const Panorama360Filter();

  static Set<T> _toggled<T>(Set<T> values, T value) =>
      Set.unmodifiable(values.contains(value) ? ({...values}..remove(value)) : {...values, value});
}

final panorama360FilterProvider = NotifierProvider<Panorama360FilterNotifier, Panorama360Filter>(
  Panorama360FilterNotifier.new,
);

/// The list of the 360° page, one per page. Its inputs come through listeners: it is never rebuilt, so the
/// TimelineService built on it (and held by an open asset viewer) lives as long as the page.
final panorama360ListProvider = Provider.autoDispose<Panorama360ListService>((ref) {
  final service = Panorama360ListService(
    repository: Panorama360Repository(ref.watch(driftProvider)),
    groupBy: ref.watch(timelineFactoryProvider).groupBy,
  );

  void pushSources() => service.setSources(
    userId: ref.read(hasServerProvider) ? ref.read(currentUserProvider)?.id : null,
    forcedKeys: ref.read(forcedPanoramaAssetsProvider),
    deviceIds: ref.read(foundLocalPanoramaIdsProvider),
  );
  ref.listen(forcedPanoramaAssetsProvider, (_, _) => pushSources());
  ref.listen(foundLocalPanoramaIdsProvider, (_, _) => pushSources());
  ref.listen(currentUserProvider, (_, _) => pushSources());
  ref.listen(hasServerProvider, (_, _) => pushSources());

  void pushView() =>
      service.setView(filter: ref.read(panorama360FilterProvider), traitsOf: panorama360TraitsReader(ref));
  ref.listen(panorama360FilterProvider, (_, _) => pushView());
  ref.listen(sphereCoverageOverridesProvider, (_, _) => pushView());
  ref.listen(localPanoramaAssetsProvider, (_, _) => pushView());

  pushSources();
  pushView();
  ref.onDispose(service.dispose);
  return service;
});

/// What the filter bar shows
final panorama360ViewProvider = StreamProvider.autoDispose<Panorama360View>(
  (ref) => ref.watch(panorama360ListProvider).views,
);

/// Traits of an entry from the stores and the probes in memory, see [panorama360TraitsOf]. Reads them once: a change
/// of a store gives a new reader (see [panorama360ListProvider]).
Panorama360TraitsReader panorama360TraitsReader(Ref ref) {
  final coverages = ref.read(sphereCoverageOverridesProvider);
  final records = ref.read(localPanoramaAssetsProvider);
  final probes = ref.read(sphericalProbeServiceProvider);
  return (entry) {
    final asset = entry.asset;
    final localId = asset.localId;
    final record = localId == null ? null : records[localId];
    return panorama360TraitsOf(
      entry,
      chosenCoverage: coverages[spatialLayoutKey(asset)] ?? (localId == null ? null : coverages[localId]),
      recordHalfSphere: record?.halfSphere,
      recordRaw: record?.raw360 ?? false,
      probe: asset.isVideo ? probes.cached(asset) : null,
    );
  };
}
