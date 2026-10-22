#!/usr/bin/env python3
"""Matrices of QR codes made by python-qrcode (BSD), an encoder apart from lib/domain/services/pairing/qr_matrix.dart,
written to qr_matrices.json for its tests: byte mode, level M, each mask forced, versions 1 to 10. (segno 1.6.6 adds
a zero codeword after a terminator that ends on a byte boundary, which the standard does not ask for: valid, but not
the same modules.)

  python3 -m venv /tmp/qr-venv && /tmp/qr-venv/bin/pip install qrcode
  /tmp/qr-venv/bin/python make_qr_matrices.py > qr_matrices.json
"""
import json

import qrcode
from qrcode.util import MODE_8BIT_BYTE, QRData

TEXTS = [
    'HELLO',
    'http://192.168.1.23:8361/p#1.AAECAwQFBgc.AQIDBAUGBwgJCgsMDQ4PEA',
    'http://10.0.2.2:18361/p#1.qrs-_tuvwxY.ZGVmZ2hpamtsbW5vcHFycw',
    'immuch360 ' * 12,
    'x' * 150,
    'é' * 100,
]


def matrix(data: bytes, mask):
    code = qrcode.QRCode(version=None, error_correction=qrcode.constants.ERROR_CORRECT_M, mask_pattern=mask, border=0)
    code.add_data(QRData(data, mode=MODE_8BIT_BYTE))
    code.make(fit=True)
    return code.version, [''.join('1' if module else '0' for module in row) for row in code.modules]


def main():
    cases = []
    for text in TEXTS:
        data = text.encode('utf-8')
        for mask in range(8):
            version, rows = matrix(data, mask)
            cases.append({'text': text, 'version': version, 'mask': mask, 'rows': rows})
    print(json.dumps({'cases': cases}, indent=1, ensure_ascii=False))


if __name__ == '__main__':
    main()
