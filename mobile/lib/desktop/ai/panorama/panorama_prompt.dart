// The prompt of a generated 360° panorama, pano-v1 (design-final 2026-10-27, section 4.3, point 4; lot P3): the fixed
// prompt of the card of the "360 ERP Outpaint" LoRA of nomadoor for FLUX.2 klein 4B, as its graph and measure M3 ran
// it, never changed by the user. The runner of sd-cli adds the LoRA to it (<lora:NAME:0.9>), and the negative prompt
// of the author's graph (PanoV1.negativePrompt). A new wording is a new version here, which a new pipeline would carry.

/// The version of [panoramaPrompt]
const panoramaPromptVersion = 1;

/// The prompt every panorama is generated with
const panoramaPrompt =
    'Fill the green spaces according to the image. Outpaint as a seamless 360 equirectangular panorama (2:1). Keep '
    'the horizon level. Match left and right edges.';
