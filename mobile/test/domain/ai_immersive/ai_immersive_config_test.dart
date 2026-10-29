import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/config/ai_immersive_config.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';

// The AI features are experimental: on by default like the other experimental switches, and turned off in the
// settings. Quest 2 and Quest Pro stay off until the user turns them on. An AI relief first shows in stereo on the Quest
// until FreeKC's comfort session decides; 2.5D is there, experimental, on the 3D button of the quad.
void main() {
  test('the AI features are on by default', () {
    expect(const AppConfig().aiImmersive.enabled, isTrue);
    expect(defaultConfig.read(SettingsKey.aiImmersiveEnabled), isTrue);
  });

  test('Quest 2 and Quest Pro are off by default', () {
    expect(const AiImmersiveConfig().olderHeadsets, isFalse);
    expect(defaultConfig.read(SettingsKey.aiImmersiveOlderHeadsets), isFalse);
  });

  test('an AI relief first shows in stereo on the Quest by default', () {
    expect(const AiImmersiveConfig().questMode, ReliefViewMode.stereo);
    expect(defaultConfig.read(SettingsKey.aiReliefQuestMode), ReliefViewMode.stereo);
  });

  test('a stored value wins over the default, and each key writes its own field', () {
    final config = AppConfig.fromEntries({
      SettingsKey.aiImmersiveEnabled: false,
      SettingsKey.aiImmersiveOlderHeadsets: true,
      SettingsKey.aiReliefQuestMode: ReliefViewMode.mesh25d,
    });

    expect(
      config.aiImmersive,
      const AiImmersiveConfig(enabled: false, olderHeadsets: true, questMode: ReliefViewMode.mesh25d),
    );
    expect(config.write(SettingsKey.aiImmersiveEnabled, true).aiImmersive.olderHeadsets, isTrue);
    expect(config.write(SettingsKey.aiImmersiveOlderHeadsets, false).aiImmersive.enabled, isFalse);
    expect(config.write(SettingsKey.aiReliefQuestMode, ReliefViewMode.stereo).aiImmersive.olderHeadsets, isTrue);
    expect(config.write(SettingsKey.aiImmersiveEnabled, true).aiImmersive.questMode, ReliefViewMode.mesh25d);
  });

  test('the keys are stored by these names', () {
    expect(SettingsKey.aiImmersiveEnabled.name, 'aiImmersiveEnabled');
    expect(SettingsKey.aiImmersiveOlderHeadsets.name, 'aiImmersiveOlderHeadsets');
    expect(SettingsKey.aiImmersiveEnabled.decode(SettingsKey.aiImmersiveEnabled.encode(false)), isFalse);
    expect(SettingsKey.aiReliefQuestMode.name, 'aiReliefQuestMode');
    expect(SettingsKey.aiReliefQuestMode.encode(ReliefViewMode.mesh25d), 'mesh25d');
    expect(SettingsKey.aiReliefQuestMode.decode('stereo'), ReliefViewMode.stereo);
  });
}
