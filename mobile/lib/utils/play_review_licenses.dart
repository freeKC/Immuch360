import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The flavour of the phones, tablets and Google TV (android/app/build.gradle), the only one that links Play Review
const _phoneFlavor = 'phone';

/// What the licence page says of Google Play In-App Review, the library behind Google Play's own card to rate the app
/// (android/app/build.gradle, phoneImplementation libs.play.review). It is Google's code under Google's terms, with no
/// licence text to ship: the entry names it, what it does in the app, and the terms it is used under
const playReviewLicenseText =
    'Google Play In-App Review 2.0.2 (com.google.android.play:review) and the Google libraries it depends on, '
    'Copyright Google LLC: Google Play\'s own card to rate the app, on the phones, tablets and Google TV that '
    'installed it from Google Play.\n'
    '\n'
    'Used under the Play Core Software Development Kit Terms of Service '
    '(https://developer.android.com/guide/playcore) and the Google APIs Terms of Service '
    '(https://developers.google.com/terms).';

/// The entry of the licence page for Play In-App Review, under its name. Only the APK of the phone flavour ships it,
/// so the quest flavour, iOS and the computers list nothing
Stream<LicenseEntry> playReviewLicenses({String? flavor = appFlavor}) async* {
  if (flavor != _phoneFlavor) {
    return;
  }
  yield const LicenseEntryWithLineBreaks(['Google Play In-App Review'], playReviewLicenseText);
}
