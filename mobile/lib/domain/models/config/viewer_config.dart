import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:immich_mobile/constants/enums.dart';

part 'viewer_config.freezed.dart';

@freezed
abstract class ViewerConfig with _$ViewerConfig {
  const factory ViewerConfig({
    @Default(true) bool loopVideo,
    @Default(false) bool loadOriginalVideo,
    @Default(true) bool autoPlayVideo,
    @Default(false) bool tapToNavigate,

    /// Experimental Spatial 2.5D player for stereoscopic videos on phones, off by default
    @Default(true) bool spatial25d,

    /// Which file of a server video the players load, null until the user picks one in the settings: the source then
    /// follows [loadOriginalVideo], which the choice replaces (see videoSourcePolicy)
    VideoSourcePolicy? videoSource,
  }) = _ViewerConfig;
}
