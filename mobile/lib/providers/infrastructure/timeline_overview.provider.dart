import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline_overview.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';

/// Immuch360: the one-pass reads of the months and the years of the main timeline
final timelineOverviewRepositoryProvider = Provider<TimelineOverviewRepository>(
  (ref) => TimelineOverviewRepository(ref.watch(driftProvider)),
);
