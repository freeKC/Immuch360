// The page's hello and sealed sign in against a stub screen, which plays the screen's side with the same functions
// (the Dart listener is checked against the same bytes by the Flutter tests)

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { agree, confirmOf, deriveKeys, fromBase64, hello, newKeyPair, open, randomBytes, seal, toBase64, transcript, utf8, DOWN, UP } from '../src/protocol.js';

/** A screen that shows [secret] for [id] and answers [result] to a login */
function stubScreen({ id, secret, result, device = { app: '3.3.0', kind: 'tv', label: 'Living room TV', os: 'Android' } }) {
  const received = [];
  let pairing = null;
  const deviceBytes = utf8(JSON.stringify(device));
  return {
    received,
    async post(path, body) {
      if (path === `/p/${id}/hello`) {
        const screen = newKeyPair();
        const phoneKey = fromBase64(body.pk);
        const th = transcript({ id, mode: body.mode, client: body.client, phoneKey, screenKey: screen.publicKey });
        const keys = deriveKeys({ shared: agree(screen.secretKey, phoneKey), secret, transcript: th });
        pairing = { th, keys };
        return {
          status: 200,
          json: { v: 1, pk: toBase64(screen.publicKey), d: toBase64(deviceBytes), confirm: toBase64(confirmOf({ confirmKey: keys.confirm, transcript: th, device: deviceBytes })) },
        };
      }
      if (path === `/p/${id}/login` && pairing) {
        const plain = open({ keys: pairing.keys, transcript: pairing.th, direction: UP, nonce: fromBase64(body.n), sealed: fromBase64(body.c) });
        if (!plain) {
          return { status: 400, json: { v: 1, error: 'rejected' } };
        }
        received.push(JSON.parse(new TextDecoder().decode(plain)));
        const nonce = randomBytes(12);
        const answer = seal({ keys: pairing.keys, transcript: pairing.th, direction: DOWN, nonce, plain: utf8(JSON.stringify({ v: 1, ...result })) });
        return { status: 200, json: { v: 1, n: toBase64(nonce), c: toBase64(answer) } };
      }
      return { status: 410, json: { v: 1, error: 'expired' } };
    },
  };
}

test('the page signs a screen in with the QR secret: the password goes sealed', async () => {
  const secret = randomBytes(16);
  const screen = stubScreen({ id: 'AAECAwQFBgc', secret, result: { status: 'signedIn' } });
  const channel = await hello({ id: 'AAECAwQFBgc', mode: 'qr', secret, post: screen.post });
  assert.equal(channel.device.label, 'Living room TV');
  const envelope = channel.sealMessage({ v: 1, server: 'http://192.168.1.10:2283', email: 'fred@example.com', password: 'hunter2' });
  assert.ok(!JSON.stringify(envelope).includes('hunter2'));
  const answer = await screen.post('/p/AAECAwQFBgc/login', envelope);
  assert.deepEqual(channel.openAnswer(answer.json), { v: 1, status: 'signedIn' });
  assert.deepEqual(screen.received, [{ v: 1, server: 'http://192.168.1.10:2283', email: 'fred@example.com', password: 'hunter2' }]);
});

test('with the typed code', async () => {
  const screen = stubScreen({ id: 'qrs-_tuvwxY', secret: utf8('K7M2Q9XRTH'), result: { status: 'badCredentials', triesLeft: 2 } });
  const channel = await hello({ id: 'qrs-_tuvwxY', mode: 'code', secret: utf8('K7M2Q9XRTH'), post: screen.post });
  const answer = await screen.post('/p/qrs-_tuvwxY/login', channel.sealMessage({ v: 1, password: 'x' }));
  assert.equal(channel.openAnswer(answer.json).triesLeft, 2);
});

test('a screen that does not know the secret is caught before anything is sent', async () => {
  const screen = stubScreen({ id: 'AAECAwQFBgc', secret: randomBytes(16), result: { status: 'signedIn' } });
  await assert.rejects(hello({ id: 'AAECAwQFBgc', mode: 'qr', secret: randomBytes(16), post: screen.post }), { message: 'wrongCode' });
  assert.deepEqual(screen.received, []);
});

test('an expired code, an unreachable screen', async () => {
  const screen = stubScreen({ id: 'AAECAwQFBgc', secret: randomBytes(16), result: {} });
  await assert.rejects(hello({ id: 'BBECAwQFBgc', mode: 'qr', secret: randomBytes(16), post: screen.post }), { message: 'expired' });
  await assert.rejects(
    hello({ id: 'AAECAwQFBgc', mode: 'qr', secret: randomBytes(16), post: () => Promise.reject(new Error('offline')) }),
    { message: 'unreachable' },
  );
});
