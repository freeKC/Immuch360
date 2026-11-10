// The invitation to rate the app (lib/domain/services/rate_app.service.dart), wired to the app: the store of the
// build, its review API, the app's store, the clock, the router and the dialog of the Quest store build. Each part is
// a provider the lab tests replace (integration_test/lab_rate_app_test.dart). Started once by the app's engine; a build
// with no store to rate in starts nothing.

import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/rate_app.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/rate_app.service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/platform/store_review_api.g.dart';
import 'package:immich_mobile/presentation/widgets/rate_app/rate_app_dialog.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/store_channel.dart';
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

/// The review API of the store of the build, through pigeon
final rateAppStoreApiProvider = Provider<RateAppStoreApi>((ref) => PigeonRateAppStoreApi(StoreReviewApi()));

/// The screen: the router, the settings and the dialog of the Quest store build
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
  bool get versionWarning => _ref.read(versionWarningPresentProvider(_ref.read(currentUserProvider)));

  @override
  Future<RateAppAnswer?> showInvite() async {
    final context = _ref.read(appRouterProvider).navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      return null;
    }
    return showRateAppDialog(context);
  }
}

/// [RateAppStoreApi] through pigeon; the store page falls back to its address
class PigeonRateAppStoreApi implements RateAppStoreApi {
  PigeonRateAppStoreApi(this._api, {this.storePageUrl = kHorizonStoreLink});

  final StoreReviewApi _api;

  /// The address opened when the store page does not open natively
  final String storePageUrl;

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
    try {
      return await launchUrl(Uri.parse(storePageUrl), mode: LaunchMode.externalApplication);
    } catch (error) {
      _log.warning('The address of the store page did not open: $error');
      return false;
    }
  }
}
