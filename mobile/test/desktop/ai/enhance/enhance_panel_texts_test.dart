// The words the panel of the conversions says of the enhanced photos.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/desktop_enhance.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_engine.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/generated/translations.g.dart';

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

  test('the failures of an enhanced photo say what to do', () {
    final t = StaticTranslations.instance;
    String said(ImmersiveErrorCode code, String? message, {ConversionKind kind = ConversionKind.enhanceRebuild}) =>
        conversionFailureText(t, code, message, kind: kind);

    expect(
      said(ImmersiveErrorCode.outOfMemory, '$enhanceMemoryMessage (900 MiB free, 3072 MiB needed)'),
      'The engine refused for lack of memory: close other programs and try again.',
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
