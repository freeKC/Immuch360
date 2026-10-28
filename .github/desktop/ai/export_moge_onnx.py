#!/usr/bin/env python3
"""Export MoGe-2 ViT-S (normal) to ONNX from its MIT weights, for the 3D scenes of Immuch360.

Why this exists: the ONNX file published next to the weights (Ruicheng/moge-2-vits-normal-onnx) has neither a card nor
a licence, while the weights (Ruicheng/moge-2-vits-normal, MIT) and the code (microsoft/MoGe, MIT, DINOv2 parts under
Apache 2.0) do. So the app ships our own export, made here by the method of MoGe's docs/onnx.md ("Dynamic Shape &
Variable Number of Tokens"), from pinned inputs, so that anyone who runs it again gets the same bytes or sees the gap.

Tool only, never shipped: run it in a throwaway environment with PyTorch for the CPU (no CUDA wheel), for example
  uv venv --python 3.13 venv && VIRTUAL_ENV=venv uv pip install --index-url https://download.pytorch.org/whl/cpu \
    --extra-index-url https://pypi.org/simple --index-strategy unsafe-best-match "torch==2.7.0+cpu" numpy scipy \
    opencv-python-headless huggingface-hub onnx "onnxruntime==1.23.2" \
    "utils3d_moge @ git+https://github.com/EasternJournalist/utils3d-moge.git@62f09d58509485564e24d5d9f6aac9ee9ebc0c37"
  git clone https://github.com/microsoft/MoGe moge-src && git -C moge-src checkout <MOGE_COMMIT>
  venv/bin/python export_moge_onnx.py --moge-src moge-src --weights model.pt --out moge.onnx

Signature of the file: inputs image (float32, [batch, 3, height, width], RGB in [0, 1]) and num_tokens (int64 scalar);
outputs points (float32, [batch, height, width, 3], affine point map), normal (float32, [batch, height, width, 3]),
mask (float32, [batch, height, width], sigmoid) and scale (float32, [batch], the metric scale). recover_focal_shift and
the metric scaling are not in the graph (docs/onnx.md); the app does them.

Opset 14 and the output names of the published file are kept on purpose (lot M2, 27/10/2026): with the pinned inputs
the export is byte for byte the file published at Ruicheng/moge-2-vits-normal-onnx@e50ffda4 (EXPECTED_SHA256), so its
provenance from the MIT weights can be checked by anyone; opsets 17 and 18 are no faster on ORT 1.23.2 and 1.31.0, and
opset 20 fails at run time on ORT 1.23.2 (bicubic Resize of the position embeddings when a side shrinks).
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

# Pinned inputs. A change here is a new component version.
MOGE_COMMIT = '74fbce054ebed49800de42d0ad0e83495065719a'  # microsoft/MoGe, 2026-08-19
WEIGHTS_REPO = 'Ruicheng/moge-2-vits-normal'
WEIGHTS_REVISION = '26b477f41595707c5db6770294c0d1721e8ed4ed'  # model.pt uploaded 2025-06-10, unchanged since
WEIGHTS_SHA256 = '79a16621928c2bf0ed04659218c55c01075e950507f40bb3332fb4c873d3e1dc'
WEIGHTS_SIZE = 140550416
TORCH_VERSION = '2.7.0+cpu'  # the producer of the published ONNX was PyTorch 2.7.0
DEFAULT_OPSET = 14
OUTPUT_NAMES = ['points', 'normal', 'mask', 'scale']
EXPECTED_SIZE = 140852051
EXPECTED_SHA256 = '24eacb5dc7a2c54c7bc98f7de085ffbed79ad006ea5b664c2c2cdc02ff3a52f0'


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--moge-src', required=True, type=Path, help='clone of microsoft/MoGe at MOGE_COMMIT')
    parser.add_argument('--weights', required=True, type=Path, help=f'model.pt of {WEIGHTS_REPO}@{WEIGHTS_REVISION}')
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--opset', type=int, default=DEFAULT_OPSET)
    parser.add_argument('--allow-other-versions', action='store_true',
                        help='export even if PyTorch or the MoGe commit differ from the pinned ones (bytes will differ)')
    args = parser.parse_args()

    os.environ['XFORMERS_DISABLED'] = '1'
    import torch

    problems = []
    if torch.__version__ != TORCH_VERSION:
        problems.append(f'PyTorch {torch.__version__}, pinned {TORCH_VERSION}')
    commit = subprocess.run(['git', '-C', str(args.moge_src), 'rev-parse', 'HEAD'], capture_output=True, text=True,
                            check=True).stdout.strip()
    if commit != MOGE_COMMIT:
        problems.append(f'MoGe at {commit}, pinned {MOGE_COMMIT}')
    if problems and not args.allow_other_versions:
        sys.exit('Not the pinned inputs: ' + '; '.join(problems))
    size = args.weights.stat().st_size
    weights_sha = sha256_of(args.weights)
    if size != WEIGHTS_SIZE or weights_sha != WEIGHTS_SHA256:
        sys.exit(f'Weights are not {WEIGHTS_REPO}@{WEIGHTS_REVISION}: {size} bytes, sha256 {weights_sha}')

    sys.path.insert(0, str(args.moge_src.resolve()))
    from moge.model.v2 import MoGeModel

    torch.manual_seed(0)
    torch.set_num_threads(max(1, (os.cpu_count() or 2) - 2))
    model = MoGeModel.from_pretrained(str(args.weights)).eval()
    model.onnx_compatible_mode = True
    example = (torch.rand(1, 3, 518, 518), torch.tensor(1800))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with torch.no_grad():
        torch.onnx.export(
            model,
            example,
            str(args.out),
            input_names=['image', 'num_tokens'],
            output_names=OUTPUT_NAMES,
            dynamic_axes={'image': {0: 'batch_size', 2: 'height', 3: 'width'}},
            opset_version=args.opset,
            dynamo=False,
        )

    # Check once against PyTorch on a fixed image of another aspect ratio, so that a wrong dynamic shape shows
    import numpy as np
    import onnxruntime as ort
    generator = torch.Generator().manual_seed(1)
    image = torch.rand(1, 3, 480, 640, generator=generator)
    tokens = 1800
    with torch.no_grad():
        reference = model(image, tokens)
    session = ort.InferenceSession(str(args.out), providers=['CPUExecutionProvider'])
    outputs = session.run(None, {'image': image.numpy(), 'num_tokens': np.array(tokens, dtype=np.int64)})
    gaps = {}
    for name, key, value in zip(OUTPUT_NAMES, ['points', 'normal', 'mask', 'metric_scale'], outputs):
        gaps[name] = float(np.max(np.abs(value - reference[key].numpy())))

    result = {
        'file': args.out.name,
        'size': args.out.stat().st_size,
        'sha256': sha256_of(args.out),
        'opset': args.opset,
        'torch': torch.__version__,
        'onnxruntime_check': ort.__version__,
        'moge_commit': commit,
        'weights': f'{WEIGHTS_REPO}@{WEIGHTS_REVISION}/model.pt',
        'weights_sha256': weights_sha,
        'inputs': [(i.name, i.type, i.shape) for i in session.get_inputs()],
        'outputs': [(o.name, o.type, o.shape) for o in session.get_outputs()],
        'max_abs_gap_to_pytorch_640x480_1800_tokens': gaps,
    }
    result['same_bytes_as_published'] = result['sha256'] == EXPECTED_SHA256 and result['size'] == EXPECTED_SIZE
    print(json.dumps(result, indent=1))
    if max(gaps.values()) > 1e-3:
        sys.exit('ONNX output differs from PyTorch by more than 1e-3')
    if args.opset == DEFAULT_OPSET and not problems and not result['same_bytes_as_published']:
        sys.exit(f'Pinned inputs but not the expected bytes: {result["sha256"]}, expected {EXPECTED_SHA256}')


if __name__ == '__main__':
    main()
