// The page's crypto against the known answers the Dart side is checked against (make_vectors.py)

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  agree,
  checkNumberOf,
  confirmOf,
  deriveKeys,
  fromBase64,
  newKeyPair,
  normalizeCode,
  open,
  parseFragment,
  seal,
  toBase64,
  transcript,
  DOWN,
  UP,
} from '../src/protocol.js';

const here = dirname(fileURLToPath(import.meta.url));
const { vectors } = JSON.parse(readFileSync(join(here, '..', '..', '..', 'test', 'fixtures', 'pairing', 'vectors.json'), 'utf8'));

const hexToBytes = (hex) => Uint8Array.from(hex.match(/../g).map((byte) => parseInt(byte, 16)));

for (const vector of vectors) {
  test(`known answers: ${vector.name}`, () => {
    const phone = newKeyPair(hexToBytes(vector.phonePrivate));
    const screen = newKeyPair(hexToBytes(vector.screenPrivate));
    assert.equal(toBase64(phone.publicKey), vector.phonePublic);
    assert.equal(toBase64(screen.publicKey), vector.screenPublic);
    const shared = agree(phone.secretKey, screen.publicKey);
    assert.equal(toBase64(shared), vector.shared);
    assert.deepEqual(agree(screen.secretKey, phone.publicKey), shared);

    const th = transcript({ id: vector.id, mode: vector.mode, client: vector.client, phoneKey: phone.publicKey, screenKey: screen.publicKey });
    assert.equal(toBase64(th), vector.transcript);
    const keys = deriveKeys({ shared, secret: fromBase64(vector.secret), transcript: th });
    assert.equal(toBase64(keys.confirm), vector.kConfirm);
    assert.equal(toBase64(keys.up), vector.kUp);
    assert.equal(toBase64(keys.down), vector.kDown);
    assert.equal(toBase64(confirmOf({ confirmKey: keys.confirm, transcript: th, device: fromBase64(vector.device) })), vector.confirm);
    assert.equal(checkNumberOf({ confirmKey: keys.confirm, transcript: th }), vector.check);

    const sealedUp = seal({ keys, transcript: th, direction: UP, nonce: fromBase64(vector.nonceUp), plain: fromBase64(vector.plainUp) });
    assert.equal(toBase64(sealedUp), vector.sealedUp);
    const sealedDown = seal({ keys, transcript: th, direction: DOWN, nonce: fromBase64(vector.nonceDown), plain: fromBase64(vector.plainDown) });
    assert.equal(toBase64(sealedDown), vector.sealedDown);
    assert.deepEqual(open({ keys, transcript: th, direction: DOWN, nonce: fromBase64(vector.nonceDown), sealed: sealedDown }), fromBase64(vector.plainDown));
    assert.equal(open({ keys, transcript: th, direction: UP, nonce: fromBase64(vector.nonceDown), sealed: sealedDown }), null);
  });
}

test('the fragment of the QR code', () => {
  const fragment = parseFragment('#1.AAECAwQFBgc.AQIDBAUGBwgJCgsMDQ4PEA');
  assert.equal(fragment.id, 'AAECAwQFBgc');
  assert.deepEqual([...fragment.secret], Array.from({ length: 16 }, (_, i) => i + 1));
  assert.equal(parseFragment('#2.AAECAwQFBgc.AQIDBAUGBwgJCgsMDQ4PEA'), null);
  assert.equal(parseFragment('#1.AAECAwQFBg.AQIDBAUGBwgJCgsMDQ4PEA'), null);
  assert.equal(parseFragment(''), null);
});

test('the typed code', () => {
  assert.equal(normalizeCode('k7m2q 9xrth'), 'K7M2Q9XRTH');
  assert.equal(normalizeCode('K7M2Q-9XRT0'), null);
  assert.equal(normalizeCode('short'), null);
});

test('a key that is not a compressed point is refused', () => {
  const phone = newKeyPair();
  assert.throws(() => agree(phone.secretKey, new Uint8Array(33)));
  assert.throws(() => agree(phone.secretKey, new Uint8Array(65)));
});
