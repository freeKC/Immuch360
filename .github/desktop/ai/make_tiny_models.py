#!/usr/bin/env python3
"""The tiny models of the tests of ONNX Runtime with several inputs and outputs, and of the stop of a run (lot C1).

Four models of a few hundred bytes to a few kilobytes that stand for the real ones of phases 2 and 3 in the tests that
load the real ONNX Runtime (design: store/m2/ai-immersive-2026-10-26/phase23/design-final-2026-10-27.md, section 10.1
point 3). Each has the names, element types, ranks, fixed dimensions, IR version and opset of the model it stands for
(read from the files of the mirror by the measure M2, m2-measures-2026-10-27.md section 2), so that the code reads its
names and shapes from the model as it does with the real one:

  tiny_moge.onnx    MoGe-2 ViT-S as we export it: image float32 [batch, 3, height, width] and num_tokens int64 [] in;
                    points and normal float32 [batch, height, width, 3], mask float32 [batch, height, width] and
                    scale float32 [batch] out (IR 7, opset 14). Inside: points = 2 t - 1 and normal = 1 - t where t is
                    the image turned channels last, mask = the first channel, scale = num_tokens / 1024 for each image.
  tiny_lama.onnx    LaMa (lama_fp32.onnx): image float32 [batch, 3, 512, 512] and mask float32 [batch, 1, 512, 512]
                    in, output float32 [batch, 3, height, width] out, in [0, 255] (IR 8, opset 17). Inside:
                    output = 255 (image (1 - mask) + 0.5 mask): the holes painted mid grey.
  tiny_migan.onnx   MI-GAN (migan_pipeline_v2.onnx): image uint8 [batch, 3, height, width] and mask uint8
                    [batch, 1, height, width] in, 255 where the pixel is known, result uint8 [batch, 3, height, width]
                    out (IR 8, opset 17). Inside: the known pixels kept, the holes painted 128.
  tiny_slow.onnx    A model made slow on purpose, for the stop of a run from another isolate (RunOptionsSetTerminate):
                    state float32 [384, 384] and iterations int64 [] in; a Loop of `iterations` matrix products by a
                    permutation that turns the columns by one; rotated float32 [384, 384] and count int64 [] out
                    (IR 8, opset 17). ONNX Runtime looks at the stop before each node of the loop's body, so a run of a
                    million turns (minutes) ends within milliseconds of the stop. rotated[i][j] = state[i][(j - n) mod
                    384] after n turns, exactly: each product adds one value and zeros.

Every constant is a power of two or an integer, so that with inputs made of multiples of 1/32 float32 computes the
outputs exactly in any order: the tests compare them exactly. tiny_models_expected.json holds the signatures as
ONNX Runtime reports them (-1 for a dimension the model leaves free), the constants, and a sample of tiny_moge with
its outputs.

The protocol buffers are written by a small encoder of the few messages of onnx.proto these models use: pure Python,
so the bytes are the same on every machine and the CI checks them without any package. The models were checked once
by onnx.checker (onnx 1.20.1) and run by ONNX Runtime 1.18.1, 1.23.2 and 1.31.0 in Python (tools only, never in the
repository); the Dart tests run them on 1.31.0 and 1.23.2 in every run of the CI.

  make_tiny_models.py           writes the five files into mobile/test/fixtures/ai_immersive
  make_tiny_models.py --check   exit 1 when one of them differs from what this script writes (a CI step)

Pure Python 3, no package.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import struct
import sys

FIXTURES = pathlib.Path(__file__).resolve().parents[3] / "mobile/test/fixtures/ai_immersive"

PRODUCER = "immuch360 make_tiny_models.py"

# TensorProto.DataType
FLOAT = 1
UINT8 = 2
INT64 = 7
BOOL = 9
TYPE_NAMES = {FLOAT: "float32", UINT8: "uint8", INT64: "int64", BOOL: "bool"}

# AttributeProto.AttributeType
ATTRIBUTE_INT = 2
ATTRIBUTE_GRAPH = 5
ATTRIBUTE_INTS = 7

MOGE_SCALE_DIVISOR = 1024
LAMA_HOLE = 0.5
MIGAN_HOLE = 128
SLOW_SIZE = 384


# --- a protocol buffer encoder for the messages of onnx.proto used here --------------------------------------------


def varint(value: int) -> bytes:
    if value < 0:
        value += 1 << 64
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def field_varint(number: int, value: int) -> bytes:
    return varint(number << 3) + varint(value)


def field_bytes(number: int, data: bytes) -> bytes:
    return varint(number << 3 | 2) + varint(len(data)) + data


def field_string(number: int, text: str) -> bytes:
    return field_bytes(number, text.encode("utf-8"))


def tensor(name: str, data_type: int, dims: list, values: list) -> bytes:
    """TensorProto: dims 1, data_type 2, name 8, raw_data 9 (little endian)"""
    pack = {FLOAT: "<f", INT64: "<q", BOOL: "<?", UINT8: "<B"}[data_type]
    raw = b"".join(struct.pack(pack, value) for value in values)
    count = 1
    for dimension in dims:
        count *= dimension
    assert count == len(values), name
    out = b"".join(field_varint(1, dimension) for dimension in dims)
    return out + field_varint(2, data_type) + field_string(8, name) + field_bytes(9, raw)


def value_info(name: str, elem_type: int, shape: list) -> bytes:
    """ValueInfoProto name 1, type 2; TypeProto.tensor_type 1; Tensor elem_type 1, shape 2; TensorShapeProto dim 1;
    Dimension dim_value 1 or dim_param 2"""
    dims = b""
    for dimension in shape:
        dims += field_bytes(1, field_varint(1, dimension) if isinstance(dimension, int) else field_string(2, dimension))
    tensor_type = field_varint(1, elem_type) + field_bytes(2, dims)
    return field_string(1, name) + field_bytes(2, field_bytes(1, tensor_type))


def attribute_int(name: str, value: int) -> bytes:
    """AttributeProto name 1, i 3, type 20"""
    return field_string(1, name) + field_varint(3, value) + field_varint(20, ATTRIBUTE_INT)


def attribute_ints(name: str, values: list) -> bytes:
    """AttributeProto name 1, ints 8, type 20"""
    return field_string(1, name) + b"".join(field_varint(8, value) for value in values) + field_varint(
        20, ATTRIBUTE_INTS
    )


def attribute_graph(name: str, graph_bytes: bytes) -> bytes:
    """AttributeProto name 1, g 6, type 20"""
    return field_string(1, name) + field_bytes(6, graph_bytes) + field_varint(20, ATTRIBUTE_GRAPH)


def node(op_type: str, inputs: list, outputs: list, name: str, attributes: tuple = ()) -> bytes:
    """NodeProto input 1, output 2, name 3, op_type 4, attribute 5"""
    out = b"".join(field_string(1, item) for item in inputs)
    out += b"".join(field_string(2, item) for item in outputs)
    out += field_string(3, name) + field_string(4, op_type)
    return out + b"".join(field_bytes(5, attribute) for attribute in attributes)


def graph(name: str, nodes: list, inputs: list, outputs: list, initializers: tuple = ()) -> bytes:
    """GraphProto node 1, name 2, initializer 5, input 11, output 12"""
    out = b"".join(field_bytes(1, item) for item in nodes) + field_string(2, name)
    out += b"".join(field_bytes(5, item) for item in initializers)
    out += b"".join(field_bytes(11, item) for item in inputs)
    return out + b"".join(field_bytes(12, item) for item in outputs)


def model(graph_bytes: bytes, ir_version: int, opset: int, doc: str) -> bytes:
    """ModelProto ir_version 1, producer_name 2, producer_version 3, doc_string 6, graph 7, opset_import 8
    (OperatorSetIdProto domain 1, version 2: the default domain, left empty)"""
    out = field_varint(1, ir_version) + field_string(2, PRODUCER) + field_string(3, "1") + field_string(6, doc)
    return out + field_bytes(7, graph_bytes) + field_bytes(8, field_varint(2, opset))


# --- the models -----------------------------------------------------------------------------------------------------


def tiny_moge() -> bytes:
    nodes = [
        node("Transpose", ["image"], ["channels_last"], "turn", [attribute_ints("perm", [0, 2, 3, 1])]),
        node("Mul", ["channels_last", "two"], ["doubled"], "double"),
        node("Sub", ["doubled", "one"], ["points"], "points"),
        node("Sub", ["one", "channels_last"], ["normal"], "normal"),
        node("Slice", ["image", "first", "second", "channel_axis"], ["first_channel"], "first_channel"),
        node("Squeeze", ["first_channel", "channel_axis"], ["mask"], "mask"),
        node("ReduceMax", ["image"], ["largest"], "largest", [attribute_ints("axes", [1, 2, 3]), attribute_int(
            "keepdims", 0)]),
        node("Mul", ["largest", "zero"], ["zeros"], "zeros"),
        node("Cast", ["num_tokens"], ["tokens"], "tokens", [attribute_int("to", FLOAT)]),
        node("Div", ["tokens", "divisor"], ["per_image"], "per_image"),
        node("Add", ["zeros", "per_image"], ["scale"], "scale"),
    ]
    initializers = (
        tensor("two", FLOAT, [], [2.0]),
        tensor("one", FLOAT, [], [1.0]),
        tensor("zero", FLOAT, [], [0.0]),
        tensor("divisor", FLOAT, [], [float(MOGE_SCALE_DIVISOR)]),
        tensor("first", INT64, [1], [0]),
        tensor("second", INT64, [1], [1]),
        tensor("channel_axis", INT64, [1], [1]),
    )
    inputs = [
        value_info("image", FLOAT, ["batch_size", 3, "height", "width"]),
        value_info("num_tokens", INT64, []),
    ]
    outputs = [
        value_info("points", FLOAT, ["batch_size", "height", "width", 3]),
        value_info("normal", FLOAT, ["batch_size", "height", "width", 3]),
        value_info("mask", FLOAT, ["batch_size", "height", "width"]),
        value_info("scale", FLOAT, ["batch_size"]),
    ]
    doc = "A stand in for MoGe-2 ViT-S in the tests of Immuch360: the image turned, its first channel, num_tokens / 1024."
    return model(graph("tiny_moge", nodes, inputs, outputs, initializers), 7, 14, doc)


def tiny_lama() -> bytes:
    nodes = [
        node("Sub", ["one", "mask"], ["known"], "known"),
        node("Mul", ["image", "known"], ["kept"], "kept"),
        node("Mul", ["mask", "hole"], ["grey"], "grey"),
        node("Add", ["kept", "grey"], ["filled"], "filled"),
        node("Mul", ["filled", "full"], ["output"], "output"),
    ]
    initializers = (
        tensor("one", FLOAT, [], [1.0]),
        tensor("hole", FLOAT, [], [LAMA_HOLE]),
        tensor("full", FLOAT, [], [255.0]),
    )
    inputs = [value_info("image", FLOAT, ["batch", 3, 512, 512]), value_info("mask", FLOAT, ["batch", 1, 512, 512])]
    outputs = [value_info("output", FLOAT, ["batch", 3, "height", "width"])]
    doc = "A stand in for LaMa in the tests of Immuch360: the holes painted mid grey, the output in [0, 255]."
    return model(graph("tiny_lama", nodes, inputs, outputs, initializers), 8, 17, doc)


def tiny_migan() -> bytes:
    nodes = [
        node("Cast", ["image"], ["pixels"], "pixels", [attribute_int("to", FLOAT)]),
        node("Cast", ["mask"], ["mask_float"], "mask_float", [attribute_int("to", FLOAT)]),
        node("Div", ["mask_float", "full"], ["known"], "known"),
        node("Sub", ["one", "known"], ["holes"], "holes"),
        node("Mul", ["pixels", "known"], ["kept"], "kept"),
        node("Mul", ["holes", "hole"], ["grey"], "grey"),
        node("Add", ["kept", "grey"], ["filled"], "filled"),
        node("Cast", ["filled"], ["result"], "result", [attribute_int("to", UINT8)]),
    ]
    initializers = (
        tensor("one", FLOAT, [], [1.0]),
        tensor("full", FLOAT, [], [255.0]),
        tensor("hole", FLOAT, [], [float(MIGAN_HOLE)]),
    )
    inputs = [
        value_info("image", UINT8, ["batch_size", 3, "height", "width"]),
        value_info("mask", UINT8, ["batch_size", 1, "height", "width"]),
    ]
    outputs = [value_info("result", UINT8, ["batch_size", 3, "height", "width"])]
    doc = "A stand in for the MI-GAN pipeline in the tests of Immuch360: the known pixels kept, the holes painted 128."
    return model(graph("tiny_migan", nodes, inputs, outputs, initializers), 8, 17, doc)


def tiny_slow() -> bytes:
    body = graph(
        "turn",
        [
            node("Identity", ["going"], ["still_going"], "still_going"),
            node("MatMul", ["state_in", "turn_by_one"], ["state_out"], "product"),
            node("Add", ["count_in", "step"], ["count_out"], "count"),
        ],
        [
            value_info("turn", INT64, []),
            value_info("going", BOOL, []),
            value_info("state_in", FLOAT, [SLOW_SIZE, SLOW_SIZE]),
            value_info("count_in", INT64, []),
        ],
        [
            value_info("still_going", BOOL, []),
            value_info("state_out", FLOAT, [SLOW_SIZE, SLOW_SIZE]),
            value_info("count_out", INT64, []),
        ],
        (tensor("step", INT64, [], [1]),),
    )
    # The permutation: ones where j = k + 1, and at k = size - 1, j = 0; made from the shape of the state, not stored
    nodes = [
        node("EyeLike", ["state"], ["next"], "next", [attribute_int("k", 1)]),
        node("EyeLike", ["state"], ["wrap"], "wrap", [attribute_int("k", 1 - SLOW_SIZE)]),
        node("Add", ["next", "wrap"], ["turn_by_one"], "turn_by_one"),
        node("Loop", ["iterations", "always", "state", "no_turn"], ["rotated", "count"], "loop", [
            attribute_graph("body", body)]),
    ]
    initializers = (
        tensor("always", BOOL, [], [True]),
        tensor("no_turn", INT64, [], [0]),
    )
    inputs = [value_info("state", FLOAT, [SLOW_SIZE, SLOW_SIZE]), value_info("iterations", INT64, [])]
    outputs = [value_info("rotated", FLOAT, [SLOW_SIZE, SLOW_SIZE]), value_info("count", INT64, [])]
    doc = "A slow model for the tests of Immuch360: a loop of matrix products that turn the columns by one."
    return model(graph("tiny_slow", nodes, inputs, outputs, initializers), 8, 17, doc)


# --- what the tests compare with ------------------------------------------------------------------------------------

MOGE_SAMPLE_SHAPE = [1, 3, 2, 3]
MOGE_SAMPLE_TOKENS = 2500


def moge_sample() -> list:
    """image[b][c][y][x] = (20 c + 5 y + x) / 32, a list in the order of the tensor"""
    _, channels, height, width = MOGE_SAMPLE_SHAPE
    return [(20 * c + 5 * y + x) / 32 for c in range(channels) for y in range(height) for x in range(width)]


def moge_outputs(image: list) -> dict:
    _, channels, height, width = MOGE_SAMPLE_SHAPE
    turned = [image[(c * height + y) * width + x] for y in range(height) for x in range(width) for c in range(channels)]
    return {
        "points": [2 * value - 1 for value in turned],
        "normal": [1 - value for value in turned],
        "mask": image[: height * width],
        "scale": [MOGE_SAMPLE_TOKENS / MOGE_SCALE_DIVISOR],
    }


def spec(name: str, elem_type: int, shape: list) -> dict:
    return {"name": name, "type": TYPE_NAMES[elem_type], "shape": [d if isinstance(d, int) else -1 for d in shape]}


def expected_json() -> str:
    image = moge_sample()
    _, channels, height, width = MOGE_SAMPLE_SHAPE
    document = {
        "about": "Made by .github/desktop/ai/make_tiny_models.py with the four tiny models: their inputs and outputs as "
        "ONNX Runtime reports them (-1 for a free dimension), their constants, and a sample of tiny_moge.onnx with its "
        "outputs, exact in float32.",
        "tiny_moge.onnx": {
            "inputs": [spec("image", FLOAT, ["b", 3, "h", "w"]), spec("num_tokens", INT64, [])],
            "outputs": [
                spec("points", FLOAT, ["b", "h", "w", 3]),
                spec("normal", FLOAT, ["b", "h", "w", 3]),
                spec("mask", FLOAT, ["b", "h", "w"]),
                spec("scale", FLOAT, ["b"]),
            ],
            "scaleDivisor": MOGE_SCALE_DIVISOR,
            "sampleShape": MOGE_SAMPLE_SHAPE,
            "sampleTokens": MOGE_SAMPLE_TOKENS,
            "sampleImage": image,
            "expectedShapes": {
                "points": [1, height, width, channels],
                "normal": [1, height, width, channels],
                "mask": [1, height, width],
                "scale": [1],
            },
            "expected": moge_outputs(image),
        },
        "tiny_lama.onnx": {
            "inputs": [spec("image", FLOAT, ["b", 3, 512, 512]), spec("mask", FLOAT, ["b", 1, 512, 512])],
            # ONNX Runtime infers the 512 of the output from the input, as it does for lama_fp32.onnx
            "outputs": [spec("output", FLOAT, ["b", 3, 512, 512])],
            "hole": LAMA_HOLE,
        },
        "tiny_migan.onnx": {
            "inputs": [spec("image", UINT8, ["b", 3, "h", "w"]), spec("mask", UINT8, ["b", 1, "h", "w"])],
            "outputs": [spec("result", UINT8, ["b", 3, "h", "w"])],
            "hole": MIGAN_HOLE,
        },
        "tiny_slow.onnx": {
            "inputs": [spec("state", FLOAT, [SLOW_SIZE, SLOW_SIZE]), spec("iterations", INT64, [])],
            "outputs": [spec("rotated", FLOAT, [SLOW_SIZE, SLOW_SIZE]), spec("count", INT64, [])],
            "size": SLOW_SIZE,
        },
    }
    return json.dumps(document, indent=1) + "\n"


def outputs() -> dict:
    return {
        "tiny_moge.onnx": tiny_moge(),
        "tiny_lama.onnx": tiny_lama(),
        "tiny_migan.onnx": tiny_migan(),
        "tiny_slow.onnx": tiny_slow(),
        "tiny_models_expected.json": expected_json().encode("utf-8"),
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
                print(f"{name} is not what make_tiny_models.py writes: run it and commit the result")
                failed = True
        else:
            path.write_bytes(data)
            print(f"{path}: {len(data)} bytes")
    if args.check and not failed:
        print("the tiny models and tiny_models_expected.json are what the script writes")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
