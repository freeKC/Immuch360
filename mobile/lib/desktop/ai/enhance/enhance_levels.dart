// "Enhance (AI)" on the computers, lots E1 to E3 of release 51 (store/m2/ai-enhance-2026-11-22/study.md and
// probe-e0.md): one action, three levels, each a model and an engine measured by the probe of 23 November 2026 on the
// RTX 4060 Laptop of the owner.
//
//  - Sharpen: Real-ESRGAN x4plus (BSD-3-Clause, already in the components of the 360° panoramas) through the sd-cli the
//    app ships, on a picture of half the size, the x4 result brought back to the size of the photo; blended with the
//    photo at 60 percent by default (at 100 percent faces turn plastic and letters change shape).
//  - Rebuild details: SeedVR2 3B (Apache-2.0) through stable-diffusion.cpp's script mode (DGL) at 0d71f963, in app
//    tiles of 512 px in three phases, on the graphics card only; it invents the most, so its dialog always says that
//    details are invented; 70 percent by default, with the colour fix.
//  - Natural: VOSR 2.0 1.4B int8 (Apache-2.0) through the ONNX Runtime of the app, on the processor: the most
//    faithful of the three in the probe, and the level a Mac or a computer without a suitable card gets.

/// The three levels of "Enhance (AI)", in the order of the dialog
enum EnhanceLevel {
  sharpen('Sharpen', 60),
  rebuild('RebuildDetails', 70),
  natural('Natural', 100);

  const EnhanceLevel(this.xmp, this.defaultStrength);

  /// The value of Immuch360:EnhanceLevel
  final String xmp;

  /// The strength the dialog starts with, in percent: how much of the result replaces the photo
  final int defaultStrength;

  /// Whether it runs on the graphics card (Sharpen and Rebuild details) rather than on the processor
  bool get onGraphicsCard => this != natural;

  static EnhanceLevel? fromXmp(String? value) {
    for (final level in values) {
      if (level.xmp == value) {
        return level;
      }
    }
    return null;
  }
}

/// What the dialog chose for a batch: the level and the strength, 0 to 100 percent
class EnhanceSettings {
  const EnhanceSettings({required this.level, required this.strength, this.pixels})
    : assert(strength >= 0 && strength <= 100, 'A strength is a percentage');

  /// The level at its default strength
  EnhanceSettings.of(this.level, {this.pixels}) : strength = level.defaultStrength;

  final EnhanceLevel level;
  final int strength;

  /// The pixels of the photo as the library knows them, for the memory the queue holds for its job
  /// (enhanceJobMemoryOf); null when not known
  final int? pixels;

  /// The share of the result in the file written, 0 to 1
  double get blend => strength / 100;

  /// The same settings for a photo of [pixels]
  EnhanceSettings forPixels(int? pixels) => EnhanceSettings(level: level, strength: strength, pixels: pixels);

  @override
  bool operator ==(Object other) =>
      other is EnhanceSettings && other.level == level && other.strength == strength && other.pixels == pixels;

  @override
  int get hashCode => Object.hash(level, strength, pixels);

  @override
  String toString() => 'EnhanceSettings(${level.name}, $strength %${pixels == null ? '' : ', $pixels px'})';
}
