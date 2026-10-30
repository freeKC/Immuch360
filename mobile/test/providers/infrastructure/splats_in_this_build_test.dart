import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';

/// Answers splatsInThisBuild as the native side would for one build, or fails
class _ImmersiveApi extends ImmersiveApi {
  _ImmersiveApi(this.answer);

  final bool? answer;
  int asked = 0;

  @override
  Future<bool> splatsInThisBuild() async {
    asked++;
    final answer = this.answer;
    if (answer == null) {
      throw PlatformException(code: 'channel-error');
    }
    return answer;
  }
}

/// Whether this build offers the Gaussian splats (FreeKC's decision of 30 October 2026): the GitHub builds do, the
/// build of the Meta Horizon Store does not, as the native side tells from the certificate of the APK (SplatBuild.kt)
void main() {
  test('a GitHub build offers the splats, the store build hides them', () async {
    expect(await askSplatsInThisBuild(_ImmersiveApi(true), android: true), isTrue);
    expect(await askSplatsInThisBuild(_ImmersiveApi(false), android: true), isFalse);
  });

  test('an answer that fails hides them, so that no failure shows them in the store build', () async {
    expect(await askSplatsInThisBuild(_ImmersiveApi(null), android: true), isFalse);
  });

  test('off Android nothing is asked, and nothing is offered', () async {
    final api = _ImmersiveApi(true);
    expect(await askSplatsInThisBuild(api, android: false), isFalse);
    expect(api.asked, 0);
  });
}
