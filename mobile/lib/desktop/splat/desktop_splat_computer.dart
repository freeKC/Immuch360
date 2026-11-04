// What a computer gives the splat viewer (lot SVC, 3 November 2026): which graphics chip draws its page and how much
// memory the computer has, for the gate (splat_computer.dart). Read when a splat opens, the cards listed once per run.
//
// Which chip draws:
// 1. the renderer the page last said it drew with, under the same web view arguments (SplatAnswerStore): WebView2 on
//    Windows names it ("ANGLE (NVIDIA, NVIDIA GeForce RTX 4060 Laptop GPU ...)"); WebKitGTK and WKWebView say "Apple
//    GPU" whatever draws, which tells nothing. A renderer read as a dedicated card is looked up in the list of the
//    cards (by its device id or its name), which says its kind and its memory; when it names no card of the list,
//    the list decides as in 2;
// 2. else the list of the cards of the app's GPU probe (gpu_probe.dart: the app started again with
//    --immuch360-gpu-probe, Vulkan and DXGI): on Windows, with "Splats on the more powerful graphics card" (decision D2,
//    --force_high_performance_gpu) the dedicated card when there is one; without it, the integrated chip when there is
//    one (Windows gives WebView2 the power saving chip of a laptop). On Linux WebKitGTK draws on the chip of the
//    display: the integrated one of a laptop that has one, the dedicated card of a computer that has only that;
// 3. a Mac: its chip shares the memory (Apple silicon), no probe runs there;
// 4. nothing known: unknown, which keeps the cap of the chips that share the memory.
// The memory of the computer: MemoryProbe (GlobalMemoryStatusEx, /proc/meminfo, sysctl hw.memsize).

import 'dart:async';
import 'dart:io';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/domain/models/splat/splat_computer.dart';
import 'package:immich_mobile/domain/services/splat_viewer_files.dart';
import 'package:logging/logging.dart';

final _log = Logger('SplatComputer');

/// The systems the choice of the chip knows
enum SplatDesktopSystem { windows, linux, macos }

/// The chip that draws the page (see the top of this file): from [renderer], the one the page last named under the
/// same arguments, then from the [cards] of the GPU probe, on [system], with the dedicated card asked ([highPerformance],
/// Windows only)
SplatGpu splatGpuOf({
  required SplatDesktopSystem system,
  String? renderer,
  GpuReport? cards,
  bool highPerformance = false,
}) {
  final listed = [
    for (final card in cards?.adapters ?? const <GpuAdapter>[])
      if (card.kind == GpuKind.discrete || card.kind == GpuKind.integrated) card,
  ];
  final dedicated = [
    for (final card in listed)
      if (card.kind == GpuKind.discrete) card,
  ]..sort((a, b) => b.localMemory.compareTo(a.localMemory));
  final integrated = [
    for (final card in listed)
      if (card.kind == GpuKind.integrated) card,
  ];
  SplatGpu dedicatedGpu(GpuAdapter card) => SplatGpu(SplatGpuKind.dedicated, name: card.name, memory: card.localMemory);

  final named = splatGpuKindOfRenderer(renderer);
  if (named == SplatGpuKind.dedicated) {
    // The card the renderer names says its kind and its memory: by its device id, which ANGLE writes ("(0x000028A0)"),
    // or its name ("NVIDIA GeForce RTX 4060 Laptop GPU")
    final card = _cardNamedBy(renderer!, listed);
    if (card != null) {
      return card.kind == GpuKind.discrete ? dedicatedGpu(card) : SplatGpu(SplatGpuKind.integrated, name: card.name);
    }
    // No list: the renderer alone. A list that names no such card is trusted, never the memory of another card
    // (review of 4 November 2026): the choice below, as without a renderer
    if (listed.isEmpty) {
      return SplatGpu(SplatGpuKind.dedicated, name: renderer);
    }
  } else if (named == SplatGpuKind.integrated) {
    return SplatGpu(SplatGpuKind.integrated, name: renderer);
  }
  switch (system) {
    case SplatDesktopSystem.macos:
      return const SplatGpu(SplatGpuKind.integrated, name: 'Mac');
    case SplatDesktopSystem.windows:
      if (highPerformance && dedicated.isNotEmpty) {
        return dedicatedGpu(dedicated.first);
      }
      if (integrated.isNotEmpty) {
        return SplatGpu(SplatGpuKind.integrated, name: integrated.first.name);
      }
      return dedicated.isEmpty ? SplatGpu.unknown : dedicatedGpu(dedicated.first);
    case SplatDesktopSystem.linux:
      if (integrated.isNotEmpty) {
        return SplatGpu(SplatGpuKind.integrated, name: integrated.first.name);
      }
      return dedicated.isEmpty ? SplatGpu.unknown : dedicatedGpu(dedicated.first);
  }
}

/// The card of [cards] that [renderer] names: by the device id ANGLE writes in it, else by its name
GpuAdapter? _cardNamedBy(String renderer, List<GpuAdapter> cards) {
  final ids = {
    for (final match in RegExp(r'\(0x([0-9a-fA-F]{4,8})\)').allMatches(renderer)) int.parse(match.group(1)!, radix: 16),
  };
  final text = renderer.toLowerCase();
  return cards.where((card) => card.deviceId != null && ids.contains(card.deviceId)).firstOrNull ??
      cards.where((card) => text.contains(card.name.toLowerCase())).firstOrNull;
}

/// The reader of the computers (desktopOverrides): the cards listed once per run, the renderer and the memory read at
/// each opening
class DesktopSplatComputer {
  DesktopSplatComputer({
    required this._probe,
    required this._answers,
    required this._highPerformance,
    this._memory = const SystemMemoryProbe(),
    SplatDesktopSystem? system,
  }) : _system =
           system ??
           (Platform.isWindows
               ? SplatDesktopSystem.windows
               : (Platform.isMacOS ? SplatDesktopSystem.macos : SplatDesktopSystem.linux));

  final GpuProbe _probe;
  final SplatAnswerStore _answers;
  final bool Function() _highPerformance;
  final MemoryProbe _memory;
  final SplatDesktopSystem _system;
  Future<GpuReport?>? _cards;
  String? _told;

  // Whether a failed list of the cards was asked again: once per run
  bool _retried = false;

  Future<GpuReport?> _listCards() async {
    try {
      final report = await _probe.probe();
      if (report.problem != null) {
        _log.info('The graphics cards could not be listed for the splats: ${report.problem!.name}');
        _retryOnce();
      }
      return report;
    } catch (error) {
      _log.info('The graphics cards could not be listed for the splats: $error');
      _retryOnce();
      return null;
    }
  }

  // The first start of a new build may outlast the probe's 10 s while the antivirus scans it (seen on 3 November
  // 2026: 50 s): the next splat asks again, once
  void _retryOnce() {
    if (!_retried) {
      _retried = true;
      _cards = null;
    }
  }

  Future<SplatComputer> read() async {
    final highPerformance = _system == SplatDesktopSystem.windows && _highPerformance();
    String? renderer;
    try {
      renderer = await _answers.renderer(highPerformance: highPerformance);
    } catch (error) {
      _log.fine('No renderer kept: $error');
    }
    // A card the list found for this renderer in an earlier run is kept with it: no list needed (review of 4 November
    // 2026). A chip the page named as one that shares the memory needs none either: only a dedicated card's memory is
    // read there
    SplatGpu? kept;
    if (renderer != null && splatGpuKindOfRenderer(renderer) == SplatGpuKind.dedicated) {
      try {
        kept = await _answers.cardOf(renderer);
      } catch (error) {
        _log.fine('No card kept: $error');
      }
    }
    final needsCards =
        kept == null &&
        _system != SplatDesktopSystem.macos &&
        splatGpuKindOfRenderer(renderer) != SplatGpuKind.integrated;
    final cards = needsCards ? await (_cards ??= _listCards()) : null;
    final gpu = kept ?? splatGpuOf(system: _system, renderer: renderer, cards: cards, highPerformance: highPerformance);
    // The card the renderer itself names, kept for the next run
    if (kept == null && renderer != null && gpu.kind == SplatGpuKind.dedicated && gpu.memory != null) {
      final named = _cardNamedBy(renderer, [...?cards?.adapters]);
      if (named != null && named.name == gpu.name) {
        try {
          await _answers.writeCard(renderer, gpu);
        } catch (error) {
          _log.fine('Card not kept: $error');
        }
      }
    }
    final computer = SplatComputer(gpu: gpu, physicalMemory: _memory.read().physical);
    final told = '$computer';
    if (told != _told) {
      _told = told;
      _log.info(
        'Splats on this computer: $gpu, memory ${computer.physicalMemory}, '
        'at most ${splatComputerMostGaussians(computer)} gaussians whole',
      );
    }
    return computer;
  }
}
