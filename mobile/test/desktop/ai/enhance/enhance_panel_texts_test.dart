// The words the panel of the conversions says of the enhanced photos.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/desktop_enhance.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_engine.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart' show AiTimings;
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

import '../creator/english_texts.dart';

void main() {
  setUpAll(loadEnglishTexts);

  test('the steps of an enhanced photo are said in its own words', () {
    final t = StaticTranslations.instance;
    final job = ConversionJob(
      id: 'conversion-1',
      source: LocalFileSource('/p/salon.jpg'),
      batchIndex: 1,
      batchSize: 1,
      kind: ConversionKind.enhanceSharpen,
      state: ConversionState.generating,
    );
    expect(conversionStageText(t, job), 'Enhancing, tile by tile');
    expect(conversionStageText(t, job.copyWith(state: ConversionState.pasteBack)), startsWith('Keeping the colours'));
    final panorama = ConversionJob(
      id: 'conversion-2',
      source: LocalFileSource('/p/salon.jpg'),
      batchIndex: 1,
      batchSize: 1,
      kind: ConversionKind.panoramaFromPhoto,
      state: ConversionState.generating,
    );
    expect(conversionStageText(t, panorama), 'Generating the surroundings');
  });

  test('Rebuild details says its loading, the phase of its tiles, and its time without a step count', () {
    final t = StaticTranslations.instance;
    final job = ConversionJob(
      id: 'conversion-1',
      source: LocalFileSource('/p/salon.jpg'),
      batchIndex: 1,
      batchSize: 1,
      kind: ConversionKind.enhanceRebuild,
      state: ConversionState.loadingModels,
    );
    expect(conversionStageText(t, job), 'Loading the engine and its models; the first run can take a few minutes');
    // No time is told while it loads: the job tells the time of the whole run, none there
    expect(ConversionKind.enhanceRebuild.tellsWholeTimeLeft, isTrue);
    expect(
      conversionTimeLeft(
        ConversionKind.enhanceRebuild,
        ImmersiveStage.loadingModels,
        timings: const AiTimings(),
        inStage: const Duration(minutes: 2),
      ),
      isNull,
    );
    expect(conversionProgressText(t, job, null), isNull);
    ConversionJob tiles(ImmersiveTilePhase phase, int step) =>
        job.copyWith(state: ConversionState.generating, step: () => step, steps: () => 77, tilePhase: () => phase);
    expect(conversionStageText(t, tiles(ImmersiveTilePhase.encode, 12)), 'Reading the photo, tile 12 of 77');
    expect(conversionStageText(t, tiles(ImmersiveTilePhase.sample, 40)), 'Rebuilding the details, tile 40 of 77');
    expect(conversionStageText(t, tiles(ImmersiveTilePhase.decode, 77)), 'Writing the result, tile 77 of 77');
    expect(
      conversionProgressText(t, tiles(ImmersiveTilePhase.sample, 40), const Duration(seconds: 50)),
      'About 50 s left',
    );
  });

  test('the failures of an enhanced photo say what to do', () {
    final t = StaticTranslations.instance;
    String said(ImmersiveErrorCode code, String? message, {ConversionKind kind = ConversionKind.enhanceRebuild}) =>
        conversionFailureText(t, code, message, kind: kind);

    expect(
      said(ImmersiveErrorCode.outOfMemory, '$enhanceMemoryMessage (900 MiB free, 3072 MiB needed)'),
      'The engine refused for lack of memory: close other programs and try again.',
    );
    // The figures of release 54: the memory available and the need of the photo, or how short sd-cli was
    expect(
      said(ImmersiveErrorCode.outOfMemory, enhanceMemoryShortMessage(3150 << 20, 3472 << 20)),
      'Not enough memory free for this photo: ${formatBytes(3150 << 20)} free, ${formatBytes(3472 << 20)} needed. '
      'Close other programs, then try again.',
    );
    expect(
      said(ImmersiveErrorCode.outOfMemory, '${enhanceMemoryRanShortMessage(26070320)}: [E] RAM graph capacity'),
      'The engine ran short of memory during the run, by ${formatBytes(26070320)}. Close other programs, then try '
      'again.',
    );
    expect(
      said(ImmersiveErrorCode.gpuUnavailable, '$enhanceNoIntDotMessage: ggml_vulkan: 1 = ...'),
      contains('Natural'),
    );
    expect(said(ImmersiveErrorCode.componentsMissing, enhanceNotInThisVersion), contains('not published'));
    expect(said(ImmersiveErrorCode.tooLarge, '9000 x 6000'), contains('50 megapixels'));
    // The other kinds keep their words
    expect(
      conversionFailureText(t, ImmersiveErrorCode.outOfMemory, null, kind: ConversionKind.sbsFromPhoto),
      isNot(contains('close other programs')),
    );
    expect(conversionKindText(t, ConversionKind.enhanceNatural), 'Enhance (AI): Natural');
    expect(
      gpuShortfallText(
        t,
        const GpuShortfall(need: 9 << 29, free: 1 << 30),
        kind: ConversionKind.enhanceRebuild,
      ),
      startsWith('Enhance (AI) needs 4.5'),
    );
    expect(conversionKindLabel(t, ConversionKind.enhanceSharpen), startsWith('Details are invented by AI'));
  });
}
