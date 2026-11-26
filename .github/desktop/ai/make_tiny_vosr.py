#!/usr/bin/env python3
"""The tiny graphs that stand for the four of VOSR 2.0 in the tests of Natural of Enhance (AI) (release 53).

Natural runs VOSR 2.0 1.4B int8 (the ONNX export of moonbox-dev, Apache-2.0) through the ONNX Runtime of the app, on
the processor on Windows and Linux and through Core ML on Apple silicon (mobile/lib/desktop/ai/enhance/natural_backend.dart).
The real graphs weigh 1.96 GB: these four, of a few hundred bytes, have the inputs and outputs the backend reads (the
first input of the encoders and of the decoder by its name, the three named inputs of the transformer) and the tile of
512 pixels, so that the whole backend (its worker isolate, its sessions, the tiles, the blend and the colour fix) runs
on the real ONNX Runtime and, on the macOS runner, through Core ML:

  tiny_vosr_image_encoder.onnx  lq float32 [1, 3, 512, 512] in, tokens float32 [1, 3, 16, 16] out: AveragePool 32
  tiny_vosr_vae_encoder.onnx    lq float32 [1, 3, 512, 512] in, lq_latent float32 [1, 3, 64, 64] out: AveragePool 8
  tiny_vosr_transformer.onnx    lq_latent, noise float32 [1, 3, 64, 64] and tokens float32 [1, 3, 16, 16] in,
                                sampled float32 [1, 3, 64, 64] out: lq_latent + 0 noise + 0 GlobalAveragePool(tokens)
  tiny_vosr_vae_decoder.onnx    latent float32 [1, 3, 64, 64] in, image float32 [1, 3, 512, 512] out: Resize nearest
                                by 8, asymmetric and floor (the form the Core ML provider takes)

So a tile comes back as the average of each block of 8 x 8 pixels of the tile, and a photo made of such blocks comes
back as it was. IR 8, opset 17, every dimension fixed (Core ML takes fixed shapes).

  make_tiny_vosr.py           writes the four files into mobile/test/fixtures/ai_immersive
  make_tiny_vosr.py --check   exit 1 when one of them differs from what this script writes (a CI step)

Pure Python 3, no package: the encoder of make_tiny_models.py.
"""
from __future__ import annotations

import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from make_tiny_models import (  # noqa: E402
    FIXTURES,
    FLOAT,
    INT64,
    attribute_ints,
    field_bytes,
    field_string,
    field_varint,
    graph,
    model,
    node,
    tensor,
    value_info,
)

TILE = 512
LATENT = TILE // 8
TOKENS = TILE // 32

# AttributeProto.AttributeType
ATTRIBUTE_STRING = 3


def attribute_string(name: str, value: str) -> bytes:
    """AttributeProto name 1, s 4, type 20"""
    return field_string(1, name) + field_bytes(4, value.encode("utf-8")) + field_varint(20, ATTRIBUTE_STRING)


def pool(name: str, output: str, side: int, size: int, doc: str) -> bytes:
    nodes = [
        # The pads written out: without them the Core ML provider of ONNX Runtime 1.31.0 refuses the pool ("Required
        # param 'pad' is missing", the macOS runner, run 45664805010), and the backend opens the graph on the processor
        node("AveragePool", ["lq"], [output], "pool", [attribute_ints("kernel_shape", [side, side]),
                                                       attribute_ints("strides", [side, side]),
                                                       attribute_ints("pads", [0, 0, 0, 0])]),
    ]
    inputs = [value_info("lq", FLOAT, [1, 3, TILE, TILE])]
    outputs = [value_info(output, FLOAT, [1, 3, size, size])]
    return model(graph(name, nodes, inputs, outputs), 8, 17, doc)


def image_encoder() -> bytes:
    return pool("tiny_vosr_image_encoder", "tokens", 32, TOKENS,
                "A stand in for the image encoder of VOSR 2.0 in the tests of Immuch360: the average of 32 x 32 blocks.")


def vae_encoder() -> bytes:
    return pool("tiny_vosr_vae_encoder", "lq_latent", 8, LATENT,
                "A stand in for the VAE encoder of VOSR 2.0 in the tests of Immuch360: the average of 8 x 8 blocks.")


def transformer() -> bytes:
    nodes = [
        node("GlobalAveragePool", ["tokens"], ["token_mean"], "token_mean"),
        node("Mul", ["token_mean", "zero"], ["token_zero"], "token_zero"),
        node("Mul", ["noise", "zero"], ["noise_zero"], "noise_zero"),
        node("Add", ["lq_latent", "noise_zero"], ["with_noise"], "with_noise"),
        node("Add", ["with_noise", "token_zero"], ["sampled"], "sampled"),
    ]
    initializers = (tensor("zero", FLOAT, [], [0.0]),)
    inputs = [
        value_info("lq_latent", FLOAT, [1, 3, LATENT, LATENT]),
        value_info("noise", FLOAT, [1, 3, LATENT, LATENT]),
        value_info("tokens", FLOAT, [1, 3, TOKENS, TOKENS]),
    ]
    outputs = [value_info("sampled", FLOAT, [1, 3, LATENT, LATENT])]
    doc = "A stand in for the transformer of VOSR 2.0 in the tests of Immuch360: the latent of the photo given back."
    return model(graph("tiny_vosr_transformer", nodes, inputs, outputs, initializers), 8, 17, doc)


def vae_decoder() -> bytes:
    nodes = [
        node("Resize", ["latent", "", "scales"], ["image"], "grow", [
            attribute_string("mode", "nearest"),
            attribute_string("coordinate_transformation_mode", "asymmetric"),
            attribute_string("nearest_mode", "floor"),
        ]),
    ]
    initializers = (tensor("scales", FLOAT, [4], [1.0, 1.0, 8.0, 8.0]),)
    inputs = [value_info("latent", FLOAT, [1, 3, LATENT, LATENT])]
    outputs = [value_info("image", FLOAT, [1, 3, TILE, TILE])]
    doc = "A stand in for the VAE decoder of VOSR 2.0 in the tests of Immuch360: each latent pixel made 8 x 8 pixels."
    return model(graph("tiny_vosr_vae_decoder", nodes, inputs, outputs, initializers), 8, 17, doc)


def outputs() -> dict:
    assert INT64  # the encoder's types, imported for the record
    return {
        "tiny_vosr_image_encoder.onnx": image_encoder(),
        "tiny_vosr_vae_encoder.onnx": vae_encoder(),
        "tiny_vosr_transformer.onnx": transformer(),
        "tiny_vosr_vae_decoder.onnx": vae_decoder(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="compare with the fixtures instead of writing them")
    args = parser.parse_args()
    failed = False
    for name, data in outputs().items():
        path = FIXTURES / name
        if args.check:
            if not path.exists() or path.read_bytes() != data:
                print(f"{name} is not what make_tiny_vosr.py writes: run it and commit the result")
                failed = True
        else:
            path.write_bytes(data)
            print(f"{path}: {len(data)} bytes")
    if args.check and not failed:
        print("the tiny graphs of VOSR are what the script writes")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
