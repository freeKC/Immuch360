import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:logging/logging.dart';

final immersiveApiProvider = Provider<ImmersiveApi>((_) => ImmersiveApi());

/// True on a Meta Quest headset (Horizon OS), where 360 media open in the immersive viewer.
/// Asked once to the platform, false on iOS and when the question fails.
final isHorizonOsProvider = FutureProvider<bool>((ref) async {
  if (!CurrentPlatform.isAndroid) {
    return false;
  }
  try {
    return await ref.read(immersiveApiProvider).isHorizonOs();
  } catch (error) {
    Logger('ImmersiveViewer').warning('Could not detect Horizon OS: $error');
    return false;
  }
});
