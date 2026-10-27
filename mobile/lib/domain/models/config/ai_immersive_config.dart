import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';

part 'ai_immersive_config.freezed.dart';

/// The shared settings of the AI features (design-final 2026-10-26, section 4.4). The computers keep the rest of
/// theirs in desktop_ai.json (DesktopAiSettings).
@freezed
abstract class AiImmersiveConfig with _$AiImmersiveConfig {
  const factory AiImmersiveConfig({
    /// The AI features, experimental and on by default like the other experimental switches: off, no AI button
    /// anywhere and nothing downloaded. On, nothing is downloaded either until the user asks for it.
    @Default(true) bool enabled,

    /// "AI relief on Quest 2 and Quest Pro (untested)", off by default: those headsets show the button greyed with
    /// its reason until it is turned on
    @Default(false) bool olderHeadsets,

    /// How the immersive viewer of the Meta Quest first shows an AI relief: on the stereo quad by default, until
    /// FreeKC's comfort session decides; 2.5D (experimental) when "Open AI reliefs in 2.5D" is on. The 3D button of
    /// the quad switches between 3D, 2.5D and 2D whatever this says.
    @Default(ReliefViewMode.stereo) ReliefViewMode questMode,
  }) = _AiImmersiveConfig;
}
