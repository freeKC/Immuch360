import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/server/activity.dart';
import 'package:immich_mobile/data/server/person.dart';
import 'package:immich_mobile/providers/infrastructure/search.provider.dart';
import 'package:immich_mobile/providers/infrastructure/user.provider.dart';
import 'package:immich_mobile/repositories/album_api_repository.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/repositories/partner_api.repository.dart';

void invalidateAllApiRepositoryProviders(WidgetRef ref) => invalidateApiRepositoryProviders(ref.invalidate);

/// The same from a provider (a [Ref]) as from a widget: [invalidate] is the invalidate of either
void invalidateApiRepositoryProviders(void Function(ProviderOrFamily provider) invalidate) {
  invalidate(userApiRepositoryProvider);
  invalidate(activityApiRepositoryProvider);
  invalidate(partnerApiRepositoryProvider);
  invalidate(personApiRepositoryProvider);
  invalidate(assetApiRepositoryProvider);
  invalidate(searchApiRepositoryProvider);

  // Drift
  invalidate(albumApiRepositoryProvider);
}
