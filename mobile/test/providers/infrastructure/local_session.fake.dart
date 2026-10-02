import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';

/// A session without a server kept in memory, off at first: override [localSessionProvider] with it where there is no
/// store, then call [enter] and [leave] as the app would
class FakeLocalSessionNotifier extends LocalSessionNotifier {
  @override
  bool build() => false;

  @override
  Future<void> enter() async => state = true;

  @override
  Future<void> leave() async => state = false;
}
