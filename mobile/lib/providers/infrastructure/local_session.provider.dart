import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('LocalSession');

/// Whether the app runs without an Immich server (see [StoreKey.localSession]): the photos and videos of this device
/// only, no account, no sync, no backup. The login page offers it, and connecting a server ends it.
///
/// Widgets that need a server consult [hasServerProvider]; the route guard reads the Store directly because it runs
/// synchronously, outside of any provider.
class LocalSessionNotifier extends Notifier<bool> {
  @override
  bool build() {
    try {
      return ref.watch(storeServiceProvider).tryGet(StoreKey.localSession) ?? false;
    } on UnsupportedError catch (error) {
      // The store is not initialised: no session without a server was started
      _log.fine('No store for the session without a server: $error');
      return false;
    }
  }

  /// Starts a session without a server
  Future<void> enter() async {
    state = true;
    await ref.read(storeServiceProvider).put(StoreKey.localSession, true);
  }

  /// Ends it, when a server is connected
  Future<void> leave() async {
    state = false;
    await ref.read(storeServiceProvider).delete(StoreKey.localSession);
  }
}

final localSessionProvider = NotifierProvider<LocalSessionNotifier, bool>(LocalSessionNotifier.new);

/// False in a session without a server. Everything that talks to the server, shows server data or offers server
/// actions should watch this and stay out of the way when it is false.
final hasServerProvider = Provider<bool>((ref) => !ref.watch(localSessionProvider));

/// Looks for the 360° photos and videos among the assets of this device (see [scanLocalPanoramas]). A provider so the
/// pages, which hold a widget ref, can start it, and so tests can replace it.
final localPanoramaScanProvider = Provider<Future<void> Function()>((ref) {
  return () => scanLocalPanoramas(ref);
});

/// Brings a session without a server up to date: indexes the photos and videos of this device (all of them when
/// `full` is true), then looks for the 360° ones among them. Failures are logged and never thrown, so callers can
/// start it without waiting for it.
final localSessionRefreshProvider = Provider<Future<void> Function({bool full})>((ref) {
  return ({bool full = false}) async {
    try {
      await ref.read(backgroundSyncProvider).syncLocal(full: full);
    } catch (error, stackTrace) {
      _log.warning('Could not index the photos and videos of this device', error, stackTrace);
    }

    try {
      await ref.read(localPanoramaScanProvider)();
    } catch (error, stackTrace) {
      _log.warning('Could not look for the 360° photos and videos of this device', error, stackTrace);
    }
  };
});
