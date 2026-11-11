#!/usr/bin/env python3
"""Known answer vectors of the play link protocol (play on the TV), written to vectors.json.

Computed with the Python cryptography package, apart from the Dart code they check (play_link_protocol.dart), so that
a JavaScript receiver later is checked against the same bytes. Run again only when the protocol changes:

  python3 make_vectors.py > vectors.json
"""
import base64
import hashlib
import hmac
import json

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

LABEL = b'immuch360 player 1'
HANDOVER_LABEL = b'immuch360 player handover 1'


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


def lp(data: bytes) -> bytes:
    return len(data).to_bytes(2, 'big') + data


def mac(key: bytes, message: bytes) -> bytes:
    return hmac.new(key, message, hashlib.sha256).digest()


def key_pair(scalar_hex: str):
    private = ec.derive_private_key(int(scalar_hex, 16), ec.SECP256R1())
    public = private.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.CompressedPoint)
    return private, public


def seal(key: bytes, transcript: bytes, direction: int, counter: int, plain: bytes) -> bytes:
    counter_bytes = counter.to_bytes(8, 'big')
    nonce = bytes([direction, 0, 0, 0]) + counter_bytes
    return AESGCM(key).encrypt(nonce, plain, transcript + bytes([direction]) + counter_bytes)


def vector(name, key, screen_id, phone_id, nonce_s, nonce_p, up, down, phone_hex, screen_hex, token_plain, token_nonce):
    transcript = hashlib.sha256(
        lp(LABEL) + lp(screen_id.encode()) + lp(phone_id.encode()) + lp(nonce_s) + lp(nonce_p)
    ).digest()
    proof_phone = mac(key, b'phone' + transcript)
    proof_screen = mac(key, b'screen' + transcript)
    prk = mac(transcript, key)
    keys = {info: mac(prk, info.encode() + b'\x01') for info in ('up', 'down', 'handover')}
    up_bytes = json.dumps(up, separators=(',', ':')).encode()
    down_bytes = json.dumps(down, separators=(',', ':')).encode()
    sealed_up = seal(keys['up'], transcript, 1, 1, up_bytes)
    sealed_down = seal(keys['down'], transcript, 2, 2, down_bytes)

    # The token handover: a fresh P-256 hello inside the session, the keys of pairing v1 with K_handover as secret
    phone, phone_pk = key_pair(phone_hex)
    screen, screen_pk = key_pair(screen_hex)
    shared = phone.exchange(ec.ECDH(), screen.public_key())
    assert shared == screen.exchange(ec.ECDH(), phone.public_key())
    handover_transcript = hashlib.sha256(lp(HANDOVER_LABEL) + lp(transcript) + lp(phone_pk) + lp(screen_pk)).digest()
    handover_prk = mac(handover_transcript, shared + keys['handover'])
    handover_keys = {info: mac(handover_prk, info.encode() + b'\x01') for info in ('confirm', 'up', 'down')}
    check_mac = mac(handover_keys['confirm'], b'check' + handover_transcript)
    check = '%06d' % (int.from_bytes(check_mac[:4], 'big') % 1000000)
    token_bytes = json.dumps(token_plain, separators=(',', ':')).encode()
    token_sealed = AESGCM(handover_keys['up']).encrypt(token_nonce, token_bytes, handover_transcript + b'\x01')
    return {
        'name': name,
        'key': b64(key),
        'screenId': screen_id,
        'phoneId': phone_id,
        'nonceScreen': b64(nonce_s),
        'noncePhone': b64(nonce_p),
        'transcript': b64(transcript),
        'handle': b64(transcript[:8]),
        'proofPhone': b64(proof_phone),
        'proofScreen': b64(proof_screen),
        'prk': b64(prk),
        'kUp': b64(keys['up']),
        'kDown': b64(keys['down']),
        'kHandover': b64(keys['handover']),
        'plainUp': b64(up_bytes),
        'counterUp': 1,
        'sealedUp': b64(sealed_up),
        'plainDown': b64(down_bytes),
        'counterDown': 2,
        'sealedDown': b64(sealed_down),
        'handover': {
            'phonePrivate': phone_hex,
            'screenPrivate': screen_hex,
            'phonePublic': b64(phone_pk),
            'screenPublic': b64(screen_pk),
            'shared': b64(shared),
            'transcript': b64(handover_transcript),
            'kConfirm': b64(handover_keys['confirm']),
            'kUp': b64(handover_keys['up']),
            'kDown': b64(handover_keys['down']),
            'check': check,
            'tokenNonce': b64(token_nonce),
            'tokenPlain': b64(token_bytes),
            'tokenSealed': b64(token_sealed),
        },
    }


def main():
    vectors = [
        vector(
            'living room TV and a phone',
            bytes(range(32)),
            '0123456789abcdef',
            'fedcba9876543210',
            bytes(range(100, 116)),
            bytes(range(200, 216)),
            {'v': 1, 'type': 'play', 'kind': 'plex', 'server': 'abcdef0123456789', 'item': '4242', 'offsetMs': 61000},
            {'v': 1, 'status': 'ok', 'state': {'seq': 3, 'phase': 'playing', 'positionMs': 61000}},
            '0f1e2d3c4b5a69788796a5b4c3d2e1f00112233445566778899aabbccddeeff0',
            '7a6b5c4d3e2f1011121314151617181920212223242526272829303132333435',
            {'server': {'name': 'Plex at home', 'machineIdentifier': 'abcdef0123456789'}, 'token': 'example-token'},
            bytes(range(1, 13)),
        ),
        vector(
            'headset, other bytes',
            bytes([255] * 32),
            '00000000ffffffff',
            '1111111122222222',
            bytes(16),
            bytes([7] * 16),
            {'v': 1, 'type': 'pause'},
            {'v': 1, 'status': 'ok'},
            '1111111111111111111111111111111111111111111111111111111111111111',
            '2222222222222222222222222222222222222222222222222222222222222222',
            {'token': 'another-token'},
            bytes(12),
        ),
    ]
    print(json.dumps({'version': 1, 'vectors': vectors}, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
