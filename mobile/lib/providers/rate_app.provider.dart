// The invitation to rate the app (lib/domain/services/rate_app.service.dart), wired to the app: the store of the
// build, its review API and its page, the app's store, the clock, the router and the quiet line of the Quest store
// build. Each part is a provider the lab tests replace (integration_test/lab_rate_app_test.dart). Started once by the
// app's engine; a build with no store to rate in starts nothing.

import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/rate_app.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/rate_app.service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/models/server_info/server_info.model.dart';
import 'package:immich_mobile/platform/store_review_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/store_channel.dart';
import 'package:immich_ui/immich_ui.dart' show scaffoldMessengerKey;
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

final _log = Logger('RateApp');

/// The store of this build (storeChannelOf). None on the computers, before anything is read
final rateAppChannelProvider = FutureProvider<RateAppChannel>((ref) async {
  if (!CurrentPlatform.isAndroid && !CurrentPlatform.isIOS) {
    return RateAppChannel.none;
  }
  final info = await PackageInfo.fromPlatform();
  final isHorizonOs = CurrentPlatform.isAndroid && await ref.read(isHorizonOsProvider.future);
  return storeChannelOf(
    platform: defaultTargetPlatform,
    flavor: appFlavor,
    packageName: info.packageName,
    signature: appFlavor == kQuestFlavor ? info.buildSignature : null,
    installerStore: info.installerStore,
    isHorizonOs: isHorizonOs,
  );
});

/// The build number of the app (PackageInfo.buildNumber), 0 when it does not read
final rateAppBuildProvider = FutureProvider<int>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return int.tryParse(info.buildNumber) ?? 0;
});

/// Whether a crash is told by the marker of the foreground: iOS, and Android before 11, which keeps no exit reasons
final rateAppForegroundMarkerProvider = FutureProvider<bool>((ref) async {
  if (CurrentPlatform.isIOS) {
    return true;
  }
  try {
    return (await DeviceInfoPlugin().androidInfo).version.sdkInt < 30;
  } catch (error) {
    _log.fine('No Android version: $error');
    return false;
  }
});

/// The clock of the rule
final rateAppClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// Where the state is kept: StoreKey.rateAppState in the app's store
final rateAppMemoryProvider = Provider<RateAppMemory>((ref) {
  final store = ref.watch(storeServiceProvider);
  return RateAppMemory(
    read: () => store.tryGet(StoreKey.rateAppState),
    write: (text) => store.put(StoreKey.rateAppState, text),
  );
});

/// The review API of the store of the build, through pigeon, and the addresses of its page
final rateAppStoreApiProvider = Provider<RateAppStoreApi>((ref) {
  final channel = ref.watch(rateAppChannelProvider).valueOrNull ?? RateAppChannel.none;
  return PigeonRateAppStoreApi(StoreReviewApi(), storePages: rateAppStorePages(channel));
});

/// The screen: the router, the settings and the quiet line of the Quest store build
final rateAppScreenProvider = Provider<RateAppScreen>((ref) => RouterRateAppScreen(ref));

/// The service, started once by the app's engine (main.dart); null for a build with no store to rate in, whose
/// signals then go nowhere
final rateAppServiceProvider = FutureProvider<RateAppService?>((ref) async {
  final channel = await ref.read(rateAppChannelProvider.future);
  if (!kRateAppInvite || !channel.canAsk) {
    _log.info('No invitation to rate in this build (${channel.name})');
    return null;
  }
  final service = RateAppService(
    channel: channel,
    build: await ref.read(rateAppBuildProvider.future),
    memory: ref.read(rateAppMemoryProvider),
    store: ref.read(rateAppStoreApiProvider),
    screen: ref.read(rateAppScreenProvider),
    now: ref.read(rateAppClockProvider),
    screenshotMode: kScreenshotMode,
    useForegroundMarker: await ref.read(rateAppForegroundMarkerProvider.future),
  );
  await service.start();
  final lifecycle = AppLifecycleListener(onResume: service.resumed, onPause: service.paused);
  RateAppSignals.register(service);
  ref.onDispose(() {
    lifecycle.dispose();
    if (identical(RateAppSignals.service, service)) {
      RateAppSignals.register(null);
    }
  });
  _log.info('The invitation to rate follows this build (${channel.name})');
  return service;
});

/// Rate Immuch360 in Settings: the store page of the build, kept by the invitation so that it never asks again.
/// True when the page opened
Future<bool> rateAppFromSettings(WidgetRef ref) async {
  try {
    final service = await ref.read(rateAppServiceProvider.future);
    if (service != null) {
      return await service.rateFromSettings();
    }
    await ref.read(rateAppChannelProvider.future);
    return await ref.read(rateAppStoreApiProvider).openStorePage();
  } catch (error, stackTrace) {
    _log.warning('The store page did not open from Settings', error, stackTrace);
    return false;
  }
}

/// Starts the invitation, once, from the app's engine; a failure is only logged
Future<void> startRateApp(WidgetRef ref) async {
  try {
    await ref.read(rateAppServiceProvider.future);
  } catch (error, stackTrace) {
    _log.warning('The invitation to rate did not start', error, stackTrace);
  }
}

/// Whether the root router showing the routes named [stack] (bottom first) is on a browse page with nothing above it:
/// the tabs of the app alone, no dialog or sheet over them ([canPop] false), the app in the foreground ([resumed])
bool rateAppBrowsing(List<String> stack, {required bool canPop, required bool resumed}) =>
    resumed && !canPop && stack.length == 1 && stack.single == TabShellRoute.name;

/// Whether the version [status] of the server holds the invitation: only an app too old for the server. The other
/// warnings of the profile menu held it in the builds 45 to 50: a server behind its latest release (shown to the
/// admins, most users of a self hosted server, for as long as they keep an older server) and a server version that did
/// not read (a server out of reach, outside home), so most users never reached an ask
bool rateAppHeldByVersion(VersionStatus status) => status == VersionStatus.clientOutOfDate;

/// See [rateAppScreenProvider]
class RouterRateAppScreen implements RateAppScreen {
  RouterRateAppScreen(this._ref);

  final Ref _ref;

  @override
  bool get browsing {
    final router = _ref.read(appRouterProvider);
    final navigator = router.navigatorKey.currentState;
    if (navigator == null) {
      return false;
    }
    return rateAppBrowsing(
      router.stackData.map((route) => route.name).toList(),
      canPop: navigator.canPop(),
      resumed: WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
  }

  @override
  bool get kioskActive {
    try {
      return SettingsRepository.instance.appConfig.kiosk.isActive;
    } catch (error) {
      _log.fine('No kiosk settings: $error');
      return false;
    }
  }

  @override
  bool get remoteControl {
    try {
      return _ref.read(tvModeProvider);
    } catch (error) {
      _log.fine('No remote control layout: $error');
      return false;
    }
  }

  @override
  bool get appOutOfDate => rateAppHeldByVersion(_ref.read(serverInfoProvider).versionStatus);

  @override
  Future<bool> showLine() async {
    final context = _ref.read(appRouterProvider).navigatorKey.currentContext;
    final messenger = scaffoldMessengerKey.currentState;
    if (context == null || !context.mounted || messenger == null) {
      return false;
    }
    messenger.showSnackBar(
      rateAppSnackBar(
        context.t,
        onRate: () {
          final service = RateAppSignals.service;
          if (service != null) {
            unawaited(service.answer(RateAppAnswer.rate));
          }
        },
      ),
    );
    return true;
  }
}

/// The quiet line of the Quest store build at the end of a viewing: one sentence and Rate, gone by itself after
/// [kRateAppLineShows]; it takes no focus and blocks nothing
SnackBar rateAppSnackBar(Translations t, {required VoidCallback onRate}) => SnackBar(
  key: rateAppSnackBarKey,
  content: Text(t.rate_app_horizon_invite),
  duration: kRateAppLineShows,
  persist: false,
  behavior: SnackBarBehavior.floating,
  action: SnackBarAction(label: t.rate_app_rate, onPressed: onRate),
);

/// The key of [rateAppSnackBar]
const rateAppSnackBarKey = Key('rate_app_snack_bar');

/// [RateAppStoreApi] through pigeon; the store page falls back to its addresses
class PigeonRateAppStoreApi implements RateAppStoreApi {
  PigeonRateAppStoreApi(this._api, {required this.storePages, Future<bool> Function(Uri url)? launch})
    : _launch = launch ?? ((url) => launchUrl(url, mode: LaunchMode.externalApplication));

  final StoreReviewApi _api;

  /// The addresses of the store page, tried in turn when it does not open natively (rateAppStorePages)
  final List<Uri> storePages;

  final Future<bool> Function(Uri url) _launch;

  @override
  Future<bool> requestReview() async {
    try {
      return await _api.requestReview();
    } catch (error) {
      _log.warning('The review prompt of the store was not asked: $error');
      return false;
    }
  }

  @override
  Future<bool> openStorePage() async {
    try {
      if (await _api.openStorePage()) {
        return true;
      }
    } catch (error) {
      _log.warning('The store page did not open natively: $error');
    }
    for (final url in storePages) {
      try {
        if (await _launch(url)) {
          return true;
        }
      } catch (error) {
        _log.warning('The store page did not open at ${url.scheme}: $error');
      }
    }
    return false;
  }
}
