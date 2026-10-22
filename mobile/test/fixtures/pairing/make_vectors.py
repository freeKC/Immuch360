#!/usr/bin/env python3
"""Known answer vectors of the pairing protocol (sign in with your phone), written to vectors.json.

Computed with the Python cryptography package, apart from the Dart (pointycastle) and browser (noble) code they
check, so that the three agree on the same bytes. Run again only when the protocol changes:

  python3 make_vectors.py > vectors.json
"""
import base64
import hashlib
import hmac
import json

from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives import serialization

LABEL = b'immuch360 pairing 1'


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


def lp(data: bytes) -> bytes:
    return len(data).to_bytes(2, 'big') + data


def key_pair(scalar_hex: str):
    private = ec.derive_private_key(int(scalar_hex, 16), ec.SECP256R1())
    public = private.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.CompressedPoint)
    return private, public


def vector(name, mode, client, secret, phone_hex, screen_hex, pairing_id, device, nonce_up, nonce_down, up, down):
    phone, phone_pk = key_pair(phone_hex)
    screen, screen_pk = key_pair(screen_hex)
    shared = phone.exchange(ec.ECDH(), screen.public_key())
    assert shared == screen.exchange(ec.ECDH(), phone.public_key())
    transcript = hashlib.sha256(
        lp(LABEL) + lp(pairing_id.encode()) + lp(mode.encode()) + lp(client.encode()) + lp(phone_pk) + lp(screen_pk)
    ).digest()
    prk = hmac.new(transcript, shared + secret, hashlib.sha256).digest()
    keys = {info: hmac.new(prk, info.encode() + b'\x01', hashlib.sha256).digest() for info in ('confirm', 'up', 'down')}
    device_bytes = json.dumps(device, separators=(',', ':'), sort_keys=True, ensure_ascii=False).encode()
    confirm = hmac.new(keys['confirm'], b'screen' + transcript + device_bytes, hashlib.sha256).digest()
    up_bytes = json.dumps(up, separators=(',', ':')).encode()
    down_bytes = json.dumps(down, separators=(',', ':')).encode()
    sealed_up = AESGCM(keys['up']).encrypt(nonce_up, up_bytes, transcript + b'\x01')
    sealed_down = AESGCM(keys['down']).encrypt(nonce_down, down_bytes, transcript + b'\x02')
    return {
        'name': name,
        'mode': mode,
        'client': client,
        'id': pairing_id,
        'secret': b64(secret),
        'phonePrivate': phone_hex,
        'screenPrivate': screen_hex,
        'phonePublic': b64(phone_pk),
        'screenPublic': b64(screen_pk),
        'shared': b64(shared),
        'transcript': b64(transcript),
        'prk': b64(prk),
        'kConfirm': b64(keys['confirm']),
        'kUp': b64(keys['up']),
        'kDown': b64(keys['down']),
        'device': b64(device_bytes),
        'confirm': b64(confirm),
        'nonceUp': b64(nonce_up),
        'plainUp': b64(up_bytes),
        'sealedUp': b64(sealed_up),
        'nonceDown': b64(nonce_down),
        'plainDown': b64(down_bytes),
        'sealedDown': b64(sealed_down),
    }


def main():
    device = {'app': '3.3.0', 'kind': 'tv', 'label': 'Living room TV', 'os': 'Android'}
    vectors = [
        vector(
            'qr code, app',
            'qr',
            'app',
            bytes(range(1, 17)),
            '0f1e2d3c4b5a69788796a5b4c3d2e1f00112233445566778899aabbccddeeff0',
            '7a6b5c4d3e2f1011121314151617181920212223242526272829303132333435',
            'AAECAwQFBgc',
            device,
            bytes(range(100, 112)),
            bytes(range(200, 212)),
            {'v': 1, 'server': 'https://photos.example.com', 'token': 'example-token'},
            {'v': 1, 'status': 'signedIn', 'label': 'Living room TV'},
        ),
        vector(
            'short code, browser page',
            'code',
            'web',
            'K7M2Q9XRTH'.encode(),
            '1111111111111111111111111111111111111111111111111111111111111111',
            '2222222222222222222222222222222222222222222222222222222222222222',
            'qrs-_tuvwxY',
            {'app': '3.3.0', 'kind': 'computer', 'label': 'Fred’s PC été', 'os': 'Windows'},
            bytes(12),
            bytes([255] * 12),
            {'v': 1, 'server': 'http://192.168.1.10:2283', 'email': 'fred@example.com', 'password': 'päss word'},
            {'v': 1, 'status': 'badCredentials', 'triesLeft': 2},
        ),
    ]
    print(json.dumps({'version': 1, 'vectors': vectors}, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
