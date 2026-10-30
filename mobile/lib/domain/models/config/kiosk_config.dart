import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:immich_mobile/domain/models/kiosk_media.dart';

part 'kiosk_config.freezed.dart';

/// The kiosk mode of the Meta Quest (Settings, Advanced, "Kiosk mode (experimental)", see KioskMedia): on by default
/// like the other experimental switches, and harmless so: nothing happens until a media is chosen.
@freezed
abstract class KioskConfig with _$KioskConfig {
  const KioskConfig._();

  const factory KioskConfig({
    /// The switch: off, the app starts as usual whatever was chosen
    @Default(true) bool enabled,

    /// The media the app opens at its start, as KioskMedia.encode wrote it; null when none is chosen
    String? media,

    /// The text of the end card as the user typed it; null (or blank) for the translated "Thank you for the journey"
    String? endText,
  }) = _KioskConfig;

  /// The media chosen, null when none is or the stored value no longer reads
  KioskMedia? get chosenMedia => KioskMedia.decode(media);

  /// Whether the next start of the app opens the kiosk: the switch on and a media chosen
  bool get isActive => enabled && chosenMedia != null;

  /// The text of the end card: the one typed, else [fallback] (the translated default)
  String endTextOr(String fallback) {
    final typed = endText?.trim();
    return typed == null || typed.isEmpty ? fallback : typed;
  }
}
