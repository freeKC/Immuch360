import 'package:pigeon/pigeon.dart';

// The invitation to rate the app (lib/domain/models/rate_app.dart): the store's own review prompt, and the store page.
// Android phone flavour: the Play In-App Review card (src/phone, com.google.android.play:review). Quest flavour: no
// Play, no review API on Horizon OS; the Meta Horizon Store page through the system deep link (src/quest). iOS: the
// StoreKit prompt. The computers never call it (storeChannelOf answers none there).
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/store_review_api.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/review/StoreReview.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.review'),
    swiftOut: 'ios/Runner/Core/StoreReview.g.swift',
    // PigeonError is already declared by Messages.g.swift in the same Runner target
    swiftOptions: SwiftOptions(includeErrorClass: false),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
@HostApi()
abstract class StoreReviewApi {
  /// Asks the store's review prompt (Play's card, StoreKit's prompt). True once the request went through; the stores
  /// never say whether the prompt showed nor what the user did. False where the build has no such prompt (the Quest),
  /// and on any error.
  @async
  bool requestReview();

  /// Opens the page of the app on the store of the build (the Meta Horizon Store on the Quest). False where the build
  /// has no such page to open natively, or when it did not open: the app then opens the address of the page.
  bool openStorePage();
}
