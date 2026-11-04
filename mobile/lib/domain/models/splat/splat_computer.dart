// The gaussians a computer shows in the splat viewer (lot SVC, 3 November 2026, after FreeKC asked why a computer
// kept only its 1,000,000 strongest): what draws the page, how much a splat takes, and how many a computer shows whole.
//
// Measured on 3 November 2026 (store/m2/splat-viewer-2026-11-02/SVC-report.md; fixture
// test/fixtures/splat_viewer/computer_measures.json): scenes of 1 to 12 million gaussians made of offset copies of the
// Brush room (637,401, SH degree 3) and of the InnerScene cactus (452,451), SPZ version 2, in the app's page in Chrome
// 156 at 2482 x 1170 on a laptop with 16 GB, an RTX 4060 Laptop (8 GB) and an Intel UHD:
//
// * the RTX 4060 draws them whole: 118 fps at 1 million, 114 at 2, 99 to 104 at 4, 94 to 98 at 6, 78 to 87 at 8, and
//   50 to 57 at 12 (4,069 MB, a quarter of the laptop's memory: past this rule's margin, which makes it 10.3 million);
// * the Intel UHD, its quality steps down to a quarter of the drawing: 48 fps at 1 million, 33 at 2, 22 to 27 at 3,
//   12 to 20 at 4;
// * the web view's processes (page, graphics process, browser) took 822 MB at 1 million and 3,065 MB at 8 on the RTX,
//   890 to 2,293 MB from 1 to 4 million on the Intel; the RTX's own memory 241 MB at 1 million, 590 at 4, 1,046 at 6
//   and 1,048 at 8 (Spark makes room by layers of 4,194,304 gaussians);
// * the page decoded 96 million gaussians without dying (Chromium on ai1, [splatEngineMostGaussians]): what limits a
//   computer is its memory and its card's, not the engine.
//
// So a computer is limited by its memory, not by a count: a graphics card with memory of its own shows every
// gaussian up to [splatComputerMostGaussians], and the frames of the first seconds decide whether a reduced copy is
// offered (framewatch.js of the page). A graphics chip that shares the computer's memory keeps the cap of 1,000,000
// (splatComputerGaussians) unless the user asks for every gaussian.

import 'dart:math' as math;

/// What draws the splat viewer's page
enum SplatGpuKind {
  /// A graphics card with memory of its own (NVIDIA, AMD Radeon RX, Intel Arc A and B)
  dedicated,

  /// A chip that shares the computer's memory (Intel UHD, Iris and Arc of the processors, AMD Radeon Graphics of the
  /// processors, Apple, Qualcomm), or a software renderer
  integrated,

  /// Not known: no list of the cards, a renderer string WebKit hides ("Apple GPU")
  unknown,
}

/// The chip that draws the page: its [kind], its [name] when known, and its own [memory] in bytes when known (a
/// dedicated card)
class SplatGpu {
  const SplatGpu(this.kind, {this.name, this.memory});

  static const unknown = SplatGpu(SplatGpuKind.unknown);

  final SplatGpuKind kind;
  final String? name;
  final int? memory;

  @override
  bool operator ==(Object other) =>
      other is SplatGpu && other.kind == kind && other.name == name && other.memory == memory;

  @override
  int get hashCode => Object.hash(kind, name, memory);

  @override
  String toString() => 'SplatGpu(${kind.name}${name == null ? '' : ', $name'}${memory == null ? '' : ', $memory'})';
}

/// What a computer gives the splat viewer: the chip that draws its page ([gpu]), its physical memory in bytes (null
/// when not read), and the setting "Keep every gaussian" ([keepEveryGaussian])
class SplatComputer {
  const SplatComputer({this.gpu = SplatGpu.unknown, this.physicalMemory, this.keepEveryGaussian = false});

  final SplatGpu gpu;
  final int? physicalMemory;
  final bool keepEveryGaussian;

  /// Whether a splat shows whole up to the memory: a dedicated card, or the setting, on a computer whose memory is
  /// known (review of 4 November 2026)
  bool get showsWhole => (gpu.kind == SplatGpuKind.dedicated || keepEveryGaussian) && physicalMemory != null;

  SplatComputer copyWith({SplatGpu? gpu, int? physicalMemory, bool? keepEveryGaussian}) => SplatComputer(
    gpu: gpu ?? this.gpu,
    physicalMemory: physicalMemory ?? this.physicalMemory,
    keepEveryGaussian: keepEveryGaussian ?? this.keepEveryGaussian,
  );

  @override
  bool operator ==(Object other) =>
      other is SplatComputer &&
      other.gpu == gpu &&
      other.physicalMemory == physicalMemory &&
      other.keepEveryGaussian == keepEveryGaussian;

  @override
  int get hashCode => Object.hash(gpu, physicalMemory, keepEveryGaussian);

  @override
  String toString() => 'SplatComputer($gpu, memory $physicalMemory, keep every gaussian $keepEveryGaussian)';
}

/// Computers whose graphics chip shares their memory show this many whole, Large splats or not; a dedicated graphics
/// card, or the setting "Keep every gaussian", shows every gaussian up to splatComputerMostGaussians (lot SVC); a
/// computer whose memory is not known, this many too
const splatComputerGaussians = 1000000;

/// The memory of the web view's processes for a splat, twice the file's bytes on top (the page reads the whole file,
/// and Spark's decoder takes a copy): at most 500 MB and 450 bytes a gaussian in every measure (822 MB measured at 1
/// million against 969 MB counted here, 3,065 MB at 8 million against 4,246, 992 MB for the Brush room's PLY of 143 MB
/// against 1,060; MB of 1,048,576 bytes)
const splatPageBaseBytes = 500 * 1024 * 1024;
const splatPageBytesPerGaussian = 450;

/// The share of the computer's physical memory a splat may take: a third (5,338 MB of 16,013, which the 8 million
/// gaussians of the measures fit, 10.3 million by this count, with room for the app and the system)
const splatPageMemoryShare = 1 / 3;

/// The memory of the graphics card itself for a splat: at most 150 MB and 180 bytes a gaussian in every measure, the
/// gaussians counted by the layers Spark makes room in past the first ([splatCardLayerGaussians]): 590 MB measured at
/// 4 million against 837 MB counted here, 1,046 MB at 6 million and 1,048 at 8 against 1,590 (two layers), 1,497 at 12
/// against 2,310 (three)
const splatCardBaseBytes = 150 * 1024 * 1024;
const splatCardBytesPerGaussian = 180;

/// Spark makes room on the card by layers of this many gaussians (2048 x 2048): up to one layer the room grows with
/// the count (241 MB at 1 million, 590 at 4), past it a whole layer at a time (6 and 8 million take the same 1,046 MB;
/// review of 4 November 2026)
const splatCardLayerGaussians = 4194304;

/// The share of a dedicated card's memory a splat may take: half, the rest for the system and the other programs
const splatCardMemoryShare = 0.5;

/// The most gaussians the page is given whatever the memory: it decoded 96 million (a file of 1.96 GB, 5.6 GB in the
/// page, 68 s) in Chromium 153 on ai1 without dying (3 November 2026); two thirds of it
const splatEngineMostGaussians = 64000000;

/// The largest file the page loaded, that of the 96 million gaussians: a file shown whole is at most this long until a
/// larger one is measured (a PLY of degree 3 that the memory of a computer of 64 GB allows is 5.5 GB; review of 4
/// November 2026)
const splatComputerMostFileBytes = 1960197759;

/// The memory the page takes for [gaussians] gaussians of a file of [fileBytes] (see [splatPageBaseBytes])
int splatPageBytes(int gaussians, {int fileBytes = 0}) =>
    splatPageBaseBytes + splatPageBytesPerGaussian * gaussians + 2 * fileBytes;

/// The memory of the graphics card for [gaussians] gaussians (see [splatCardBaseBytes]): past the first layer, whole
/// layers
int splatCardBytes(int gaussians) => splatCardBaseBytes + splatCardBytesPerGaussian * _layered(gaussians);

int _layered(int gaussians) => gaussians <= splatCardLayerGaussians
    ? gaussians
    : (gaussians + splatCardLayerGaussians - 1) ~/ splatCardLayerGaussians * splatCardLayerGaussians;

/// The most gaussians [computer] shows whole for a file of [fileBytesPerGaussian] bytes a gaussian (21 for the SPZ of
/// the measures, about 248 for a PLY of degree 3): what a third of its physical memory holds, what half the memory of
/// its dedicated card holds, and [splatEngineMostGaussians]. A computer whose memory is not known shows the cap of the
/// chips that share it, [splatComputerGaussians] (review of 4 November 2026).
int splatComputerMostGaussians(SplatComputer computer, {double fileBytesPerGaussian = 0}) {
  final physical = computer.physicalMemory;
  if (physical == null) {
    return splatComputerGaussians;
  }
  final room = physical * splatPageMemoryShare - splatPageBaseBytes;
  var most = math.min(
    splatEngineMostGaussians,
    (room / (splatPageBytesPerGaussian + 2 * fileBytesPerGaussian)).floor(),
  );
  final card = computer.gpu.memory;
  if (computer.gpu.kind == SplatGpuKind.dedicated && card != null) {
    final room = card * splatCardMemoryShare - splatCardBaseBytes;
    final fits = (room / splatCardBytesPerGaussian).floor();
    // Past the first layer, only whole layers fit
    most = math.min(
      most,
      fits <= splatCardLayerGaussians ? fits : fits ~/ splatCardLayerGaussians * splatCardLayerGaussians,
    );
  }
  return math.max(0, most);
}

/// How a whole splat stopped the viewer on a computer: its web view's process died for want of memory, or its graphics
/// stopped (the page stalled, or lost its WebGL context)
enum SplatDeath { memory, graphics }

/// [most], the most gaussians a computer holds, as the refusal says it after "about": rounded down to three figures
/// (10,336,420 is said 10,300,000; review of 4 November 2026)
int splatAboutCount(int most) {
  var step = 1;
  while (most ~/ step >= 1000) {
    step *= 10;
  }
  return most ~/ step * step;
}

/// What the user answered for a file whose frames were slow (the page's offer): keep [keep] of its gaussians, or keep
/// them all ([keep] null). Or what the app keeps for a whole splat that stopped the viewer ([died]): the reduced copy
/// of [keep] gaussians is offered before it opens again (review of 4 November 2026)
class SplatFrameAnswer {
  const SplatFrameAnswer.reduce(int this.keep) : died = null;

  const SplatFrameAnswer.whole() : keep = null, died = null;

  const SplatFrameAnswer.died(int this.keep, SplatDeath this.died);

  final int? keep;
  final SplatDeath? died;

  /// The user took the reduced copy of [keep]
  bool get reduces => keep != null && died == null;

  /// The user chose to keep every gaussian
  bool get keepsWhole => keep == null && died == null;

  /// The answer as it is kept: {"keep": 1200000}, {"whole": true}, or {"died": "memory", "keep": 1000000}
  Map<String, Object?> toJson() => switch (died) {
    final SplatDeath died => {'died': died.name, 'keep': keep},
    null => reduces ? {'keep': keep} : {'whole': true},
  };

  static SplatFrameAnswer? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final keep = json['keep'];
    final died = SplatDeath.values.where((death) => death.name == json['died']).firstOrNull;
    if (json['died'] != null) {
      return died != null && keep is int && keep > 0 ? SplatFrameAnswer.died(keep, died) : null;
    }
    if (keep is int && keep > 0) {
      return SplatFrameAnswer.reduce(keep);
    }
    return json['whole'] == true ? const SplatFrameAnswer.whole() : null;
  }

  @override
  bool operator ==(Object other) => other is SplatFrameAnswer && other.keep == keep && other.died == died;

  @override
  int get hashCode => Object.hash(keep, died);

  @override
  String toString() => switch (died) {
    final SplatDeath died => 'SplatFrameAnswer.died($keep, ${died.name})',
    null => reduces ? 'SplatFrameAnswer.reduce($keep)' : 'SplatFrameAnswer.whole()',
  };
}

/// The reduced copy offered for a whole splat of [gaussians] that stopped the viewer: the cap of the chips that share
/// the memory, or half the splat under it, rounded down to 10,000 and at least [splatFrameWatchFloor]; null when the
/// splat is no larger than that
int? splatDiedKeep(int gaussians) {
  final keep = math.max(splatFrameWatchFloor, math.min(splatComputerGaussians, gaussians ~/ 2) ~/ 10000 * 10000);
  return keep < gaussians ? keep : null;
}

/// A splat of this many gaussians or fewer is never offered smaller: the phones' cap
const splatFrameWatchFloor = 150000;

/// The kind of chip a WebGL renderer string names: Chromium's on Windows unmasks it ("ANGLE (NVIDIA, NVIDIA GeForce RTX
/// 4060 Laptop GPU (0x000028A0) Direct3D11 vs_5_0 ps_5_0, D3D11)"); WebKitGTK and WKWebView say "Apple GPU" whatever
/// draws (measured under WebKitGTK 2.48 to 2.54 in the five package containers): unknown there
SplatGpuKind splatGpuKindOfRenderer(String? renderer) {
  final text = (renderer ?? '').toLowerCase();
  if (text.isEmpty || text == 'apple gpu' || text == 'webkit webgl') {
    return SplatGpuKind.unknown;
  }
  // Software renderers draw with the processor
  if (RegExp(r'swiftshader|llvmpipe|softpipe|lavapipe|basic render|software').hasMatch(text)) {
    return SplatGpuKind.integrated;
  }
  if (text.contains('nvidia') || text.contains('geforce') || text.contains('quadro')) {
    return text.contains('tegra') ? SplatGpuKind.integrated : SplatGpuKind.dedicated;
  }
  if (text.contains('radeon') || text.contains('amd')) {
    // Radeon RX, Radeon Pro and FirePro have their own memory; "AMD Radeon(TM) Graphics", "Radeon 780M Graphics",
    // "Vega 8 Graphics", "RX Vega 10 Graphics" and "RX Vega 11 Graphics" (Ryzen 2000 to 5000) and the Radeon HD of the
    // A-series ("HD 8610G", "HD 7660D") are the chips of the processors (review of 4 November 2026)
    if (RegExp(r'rx vega \d+ graphics|radeon hd \d{4}[dg]\b').hasMatch(text)) {
      return SplatGpuKind.integrated;
    }
    return RegExp(r'radeon\s*(\(tm\)\s*)?(rx|pro)\b|firepro|radeon r9|radeon hd').hasMatch(text)
        ? SplatGpuKind.dedicated
        : SplatGpuKind.integrated;
  }
  if (text.contains('intel')) {
    // The Arc cards have a model number (A380, A370M, A770, B580, Pro B50); "Intel(R) Arc(TM) Graphics", "Arc 140V"
    // and the Arc B370 and B390 of Panther Lake are the chips of the processors
    return RegExp(r'arc\S*\s*(\(tm\)\s*)?(pro\s*)?(a\d{2,3}m?|b(?!3\d\d)\d{2,3})\b').hasMatch(text)
        ? SplatGpuKind.dedicated
        : SplatGpuKind.integrated;
  }
  if (RegExp(r'apple m\d|adreno|mali|powervr|qualcomm|immortalis|xclipse').hasMatch(text)) {
    return SplatGpuKind.integrated;
  }
  return SplatGpuKind.unknown;
}
