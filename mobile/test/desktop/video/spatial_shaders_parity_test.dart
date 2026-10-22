// The Spatial passes of renderer C on Windows (packages/media_kit_video/windows/spatial_shaders.h and
// spatial_renderer.cc, IMMUCH360-NOTE.md patch 11) against the phones' renderer they port
// (android/app/src/main/kotlin/app/alextran/immich/spatial/SpatialShaders.kt and SpatialRenderer.kt), read as text
// on any computer:
// - each pass body of the header is the text of its Kotlin constant, but for the sampler of the eye pass (the
//   decoder's samplerExternalOES on the phones, renderer C's intermediate texture, a sampler2D, here); lines are
//   compared trimmed, blank lines left out, so that a fix of the phones fails here until it is copied;
// - every pass of the phones has its place: copied, or replaced for a reason given below;
// - the start of the fragment shaders and the inputs of the eye pass are those of the phones;
// - the constants and the tiers of SpatialRenderer.kt have the same values in the C++.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _kotlinFolder = 'android/app/src/main/kotlin/app/alextran/immich/spatial';
const _windowsFolder = 'packages/media_kit_video/windows';

/// The header's constant for each Kotlin pass
const _ported = {
  'VERTEX': 'kVertex',
  'EYE_FLAT_BODY': 'kEyeFlat',
  'COPY': 'kCopy',
  'GRAY_PACK': 'kGrayPack',
  'DISPARITY': 'kDisparity',
  'BLEND': 'kBlend',
  'BLUR': 'kBlur',
  'SYNTHESIS': 'kSynthesis',
  'SHOW_DISPARITY': 'kShowDisparity',
};

/// The Kotlin passes without a copy in the header, and why
const _replaced = {
  'VERTEX_ESSL1': 'the GLSL ES 1.00 vertex shader of the eye pass fallbacks: renderer C runs in OpenGL ES 3.0 only',
  'EYE_EQUIRECT_BODY': "renderer C's own equirectangular pass draws each eye, with kEyeSphereMain for the alpha",
};

/// SpatialRenderer.kt's constants and their names in spatial_renderer.cc
const _constants = {
  'DISPARITY_RANGE': 'kDisparityRange',
  'SEARCH_FRACTION': 'kSearchFraction',
  'NEW_DISPARITY_WEIGHT': 'kNewDisparityWeight',
  'CONSISTENCY_TOLERANCE': 'kConsistencyTolerance',
  'MAX_EYE_PIXELS': 'kMaxEyePixels',
  'SETTLE_DELAY_NS': 'kSettleDelayNs',
  'SETTLE_RUNS': 'kSettleRuns',
  'SLOW_MS': 'kSlowMs',
  'FAST_MS': 'kFastMs',
  'FAST_SECONDS_TO_STEP_UP': 'kFastSecondsToStepUp',
  'STEP_UP_BLOCK_NS': 'kStepUpBlockNs',
  'MAP_RESET_DEGREES': 'kMapResetDegrees',
  'MAP_RESET_FOV_DEGREES': 'kMapResetFovDegrees',
  'CPU_TIMING_PERIOD': 'kCpuTimingPeriod',
};

String _read(String folder, String name) => File(p.join(folder, name)).readAsStringSync();

/// The raw strings of the Kotlin passes by name ("val NAME = ...\"\"\"...\"\"\"")
Map<String, String> _kotlinPasses(String source) => {
  for (final match in RegExp(
    r'(?:private )?val (\w+)(?:: String)? = (?:fragment\(\s*|VERSION \+ )?"""(.*?)"""',
    dotAll: true,
  ).allMatches(source))
    match.group(1)!: match.group(2)!,
};

/// The plain string constants of the Kotlin file ("const val NAME = \"...\"" possibly over several + lines)
Map<String, String> _kotlinStrings(String source) {
  final strings = <String, String>{};
  for (final match in RegExp(r'const val (\w+) = ((?:"(?:[^"\\]|\\.)*"\s*\+?\s*)+)').allMatches(source)) {
    final parts = RegExp(r'"((?:[^"\\]|\\.)*)"').allMatches(match.group(2)!).map((part) => part.group(1)!);
    strings[match.group(1)!] = parts.join().replaceAll(r'\n', '\n');
  }
  return strings;
}

/// The raw string constants of a C++ header by name
Map<String, String> _headerStrings(String source) => {
  for (final match in RegExp(r'constexpr const char\* (k\w+) = R"glsl\((.*?)\)glsl";', dotAll: true).allMatches(source))
    match.group(1)!: match.group(2)!,
};

/// The lines of a shader, trimmed, without the blank ones nor a version line
List<String> _lines(String source) => [
  for (final line in source.split('\n'))
    if (line.trim().isNotEmpty && !line.trim().startsWith('#version')) line.trim(),
];

/// A numeric literal of Kotlin or C++ ("100_000_000L", "0.5f", "1920 * 1080", "1920.0 * 1080.0", "60000000000LL")
double _number(String literal) => literal
    .split('*')
    .map((factor) => double.parse(factor.trim().replaceAll('_', '').replaceAll(RegExp(r'(?:[fF]|[lL]{1,2})$'), '')))
    .reduce((a, b) => a * b);

void main() {
  final kotlin = _read(_kotlinFolder, 'SpatialShaders.kt');
  final header = _read(_windowsFolder, 'spatial_shaders.h');
  final passes = _kotlinPasses(kotlin);
  final strings = _headerStrings(header);

  test('every pass of the phones is copied into spatial_shaders.h or replaced for a reason', () {
    expect(passes.keys, isNotEmpty, reason: 'the Kotlin passes were not found');
    final unknown = passes.keys.where((name) => !_ported.containsKey(name) && !_replaced.containsKey(name));
    expect(unknown, isEmpty, reason: 'a pass of SpatialShaders.kt without its place in renderer C');
    for (final name in _ported.keys) {
      expect(passes, contains(name), reason: '$name is gone from SpatialShaders.kt');
      expect(strings, contains(_ported[name]), reason: '${_ported[name]} is missing from spatial_shaders.h');
    }
  });

  for (final MapEntry(key: name, value: constant) in _ported.entries) {
    test('$constant is the text of SpatialShaders.$name', () {
      final phone = _lines(passes[name]!.replaceAll('samplerExternalOES', 'sampler2D'));
      final windows = _lines(strings[constant]!);
      expect(windows, phone);
    });
  }

  test('the fragment shaders start as the phones\' and the eye pass has their inputs', () {
    final kotlinStrings = _kotlinStrings(kotlin);
    expect(_lines(strings['kFragmentPrefix']!), [
      ..._lines(kotlinStrings['VERSION']!),
      ..._lines(kotlinStrings['PRECISION']!),
    ], reason: 'kFragmentPrefix is VERSION + PRECISION, the version line left out of both');
    expect(strings['kFragmentPrefix']!.trimLeft(), startsWith('#version 300 es'));
    expect(_lines(strings['kEyeIo']!), _lines(kotlinStrings['EYE_IO_ESSL3']!));
    expect(strings['kVertex']!.trimLeft(), startsWith('#version 300 es'));
  });

  test('the constants and the tiers of SpatialRenderer.kt have the same values in spatial_renderer.cc', () {
    final renderer = _read(_kotlinFolder, 'SpatialRenderer.kt');
    final cpp = _read(_windowsFolder, 'spatial_renderer.cc');
    for (final MapEntry(key: name, value: cppName) in _constants.entries) {
      final phone = RegExp('const val $name = ([^\\n]+)').firstMatch(renderer);
      final windows = RegExp('constexpr \\w+ $cppName = ([^;]+);').firstMatch(cpp);
      expect(phone, isNotNull, reason: '$name is gone from SpatialRenderer.kt');
      expect(windows, isNotNull, reason: '$cppName is missing from spatial_renderer.cc');
      expect(_number(windows!.group(1)!), _number(phone!.group(1)!), reason: '$cppName against $name');
    }
    // Quality.LOW -> Tier(320, 180, 4, false), and the same in TierOf
    final phoneTiers = {
      for (final match in RegExp(r'Quality\.(\w+) -> Tier\(([^)]*)\)').allMatches(renderer))
        match.group(1)!: match.group(2)!.replaceAll(' ', ''),
    };
    final cppTiers = {
      for (final match in RegExp(
        r'case k(\w+):\s*return Tier\{([^}]*)\};|default:\s*return Tier\{([^}]*)\};',
      ).allMatches(cpp))
        (match.group(1) ?? 'Medium').toUpperCase(): (match.group(2) ?? match.group(3))!.replaceAll(' ', ''),
    };
    expect(phoneTiers.keys, containsAll(['LOW', 'MEDIUM', 'HIGH']));
    expect(cppTiers, phoneTiers);
  });
}
