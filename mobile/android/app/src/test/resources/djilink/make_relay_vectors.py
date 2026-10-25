#!/usr/bin/env python3
"""Known answers of the proofs of relay protocol 1 (p2/design-stage2b.md, section 4.5), written apart from the Kotlin
code with the Python standard library only, as the pairing's make_vectors.py is.

  label         = UTF-8 "immuch360 drone relay 1"
  key           = UTF-8 of the normalised code: 10 capitals of the pairing alphabet, no space
  headset proof = HMAC-SHA256(key, label || 0x01 || server nonce || client nonce)
  phone proof   = HMAC-SHA256(key, label || 0x02 || server nonce || client nonce)

The nonces are derived from a fixed text so that the file is the same on every run. No capture byte is in it.

  python3 make_relay_vectors.py > relay-vectors.json
"""
import hashlib
import hmac
import json

LABEL = b'immuch360 drone relay 1'
ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
CODES = ['K7M2Q9XRTH', 'ABCDEFGHJK', '2345678922', 'ZZZZZZZZZZ', 'MNPQRSTUVW']


def nonce(text: str) -> bytes:
    return hashlib.sha256(text.encode('utf-8')).digest()[:16]


def proof(code: str, role: int, server: bytes, client: bytes) -> bytes:
    return hmac.new(code.encode('utf-8'), LABEL + bytes([role]) + server + client, hashlib.sha256).digest()


def main() -> None:
    vectors = []
    for index, code in enumerate(CODES):
        assert len(code) == 10 and all(symbol in ALPHABET for symbol in code)
        server = nonce(f'server nonce {index}')
        client = nonce(f'client nonce {index}')
        vectors.append({
            'code': code,
            'serverNonce': server.hex(),
            'clientNonce': client.hex(),
            'headsetProof': proof(code, 1, server, client).hex(),
            'phoneProof': proof(code, 2, server, client).hex(),
        })
    print(json.dumps({'label': LABEL.decode('utf-8'), 'vectors': vectors}, indent=2))


if __name__ == '__main__':
    main()
