#!/usr/bin/env python3
"""The tiny depth model of the tests of ONNX Runtime by FFI (lot A4a), and the output it must give.

A few hundred bytes that stand for Depth Anything V2 Small in the tests that load the real ONNX Runtime: the same input
and output names and ranks as the export of onnx-community (pixel_values [batch, 3, height, width] in, predicted_depth
[batch, height, width] out, float32, opset 14, IR 9), so that the code reads the names and shapes from the model as it
does with the real one. Inside, one 3 x 3 convolution of the three channels to one, padded by one, with fixed weights,
then the channel axis squeezed. Every weight and every input value of the sample is a multiple of a power of two
small enough that float32 computes the output exactly in any order of summation: the test compares it exactly.

Writes mobile/test/fixtures/ai_immersive/tiny_depth.onnx and tiny_depth_expected.json (the weights, the bias, a
sample input of 1 x 3 x 4 x 5 and its output). Needs the onnx package (Apache 2.0, https://github.com/onnx/onnx),
a tool only: nothing of it is shipped.

  make_tiny_depth_model.py           writes both files
  make_tiny_depth_model.py --check   exit 1 when they differ from what this script writes
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

import onnx
from onnx import TensorProto, helper

FIXTURES = pathlib.Path(__file__).resolve().parents[3] / "mobile/test/fixtures/ai_immersive"
MODEL = FIXTURES / "tiny_depth.onnx"
EXPECTED = FIXTURES / "tiny_depth_expected.json"

INPUT_NAME = "pixel_values"
OUTPUT_NAME = "predicted_depth"
OPSET = 14
IR_VERSION = 9

# weight[channel][row][column], multiples of 1/64; the asymmetry tells rows from columns and channels apart
WEIGHTS = [
    [[(c + 1) * (3 * ky + kx + 1) * (1 if (c + ky + kx) % 2 == 0 else -1) / 64 for kx in range(3)] for ky in range(3)]
    for c in range(3)
]
BIAS = 0.5

SAMPLE_SHAPE = [1, 3, 4, 5]


def sample_input() -> list[list[list[float]]]:
    """x[channel][row][column] = (20 c + 5 y + x) / 32"""
    _, channels, height, width = SAMPLE_SHAPE
    return [[[(20 * c + 5 * y + x) / 32 for x in range(width)] for y in range(height)] for c in range(channels)]


def expected_output(pixels: list[list[list[float]]]) -> list[list[float]]:
    channels = len(pixels)
    height = len(pixels[0])
    width = len(pixels[0][0])
    out = []
    for y in range(height):
        row = []
        for x in range(width):
            total = BIAS
            for c in range(channels):
                for ky in range(3):
                    for kx in range(3):
                        yy = y + ky - 1
                        xx = x + kx - 1
                        if 0 <= yy < height and 0 <= xx < width:
                            total += WEIGHTS[c][ky][kx] * pixels[c][yy][xx]
            row.append(total)
        out.append(row)
    return out


def build_model() -> onnx.ModelProto:
    pixel_values = helper.make_tensor_value_info(INPUT_NAME, TensorProto.FLOAT, ["batch_size", 3, "height", "width"])
    predicted = helper.make_tensor_value_info(OUTPUT_NAME, TensorProto.FLOAT, ["batch_size", "height", "width"])
    weight = helper.make_tensor(
        "weight", TensorProto.FLOAT, [1, 3, 3, 3], [w for channel in WEIGHTS for row in channel for w in row]
    )
    bias = helper.make_tensor("bias", TensorProto.FLOAT, [1], [BIAS])
    axes = helper.make_tensor("axes", TensorProto.INT64, [1], [1])
    conv = helper.make_node(
        "Conv", [INPUT_NAME, "weight", "bias"], ["depth"], kernel_shape=[3, 3], pads=[1, 1, 1, 1], strides=[1, 1]
    )
    squeeze = helper.make_node("Squeeze", ["depth", "axes"], [OUTPUT_NAME])
    graph = helper.make_graph([conv, squeeze], "tiny_depth", [pixel_values], [predicted], [weight, bias, axes])
    model = helper.make_model(
        graph,
        opset_imports=[helper.make_opsetid("", OPSET)],
        producer_name="immuch360 make_tiny_depth_model.py",
        producer_version="1",
        doc_string="A stand in for Depth Anything V2 Small in the tests of Immuch360: one 3 x 3 convolution.",
    )
    model.ir_version = IR_VERSION
    onnx.checker.check_model(model)
    return model


def expected_json() -> str:
    pixels = sample_input()
    document = {
        "about": "Made by .github/desktop/ai/make_tiny_depth_model.py with tiny_depth.onnx: the output the model gives "
        "for the sample input, exact in float32.",
        "input": INPUT_NAME,
        "output": OUTPUT_NAME,
        "weights": WEIGHTS,
        "bias": BIAS,
        "sampleShape": SAMPLE_SHAPE,
        "sampleInput": pixels,
        "expectedShape": [1, SAMPLE_SHAPE[2], SAMPLE_SHAPE[3]],
        "expectedOutput": expected_output(pixels),
    }
    return json.dumps(document, indent=1) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="compare with the fixtures instead of writing them")
    args = parser.parse_args()
    model_bytes = build_model().SerializeToString()
    expected = expected_json()
    if args.check:
        same = MODEL.exists() and MODEL.read_bytes() == model_bytes
        same = same and EXPECTED.exists() and EXPECTED.read_text(encoding="utf-8") == expected
        if not same:
            print("tiny_depth.onnx or tiny_depth_expected.json differs from what the script writes", file=sys.stderr)
            return 1
        print("tiny_depth.onnx and tiny_depth_expected.json are what the script writes")
        return 0
    FIXTURES.mkdir(parents=True, exist_ok=True)
    MODEL.write_bytes(model_bytes)
    EXPECTED.write_text(expected, encoding="utf-8")
    print(f"wrote {MODEL} ({len(model_bytes)} bytes) and {EXPECTED}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
