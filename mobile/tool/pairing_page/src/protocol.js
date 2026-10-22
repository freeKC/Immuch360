// The pairing protocol, version 1, on the browser page a big screen serves: the same bytes as
// mobile/lib/domain/services/pairing/pairing_protocol.dart, checked against mobile/test/fixtures/pairing/vectors.json
// by test/protocol.test.mjs. An http:// page on a LAN address is not a secure context and has no WebCrypto: the
// audited noble libraries do the work, with crypto.getRandomValues for the randomness.

import { gcm } from '@noble/ciphers/aes.js';
import { p256 } from '@noble/curves/nist.js';
import { hmac } from '@noble/hashes/hmac.js';
import { sha256 } from '@noble/hashes/sha2.js';

export const VERSION = 1;
const LABEL = 'immuch360 pairing 1';
export const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
export const UP = 1;
export const DOWN = 2;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function utf8(text) {
  return encoder.encode(text);
}

export function concat(...parts) {
  const length = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

export function toBase64(bytes) {
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function fromBase64(text) {
  if (typeof text !== 'string' || !/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) {
    return null;
  }
  const padded = text.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((text.length + 3) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/** The fragment of the QR code: {id, secret}, or null */
export function parseFragment(hash) {
  const match = /^#?1\.([A-Za-z0-9_-]{11})\.([A-Za-z0-9_-]{22})$/.exec(hash || '');
  if (!match) {
    return null;
  }
  const secret = fromBase64(match[2]);
  return secret && secret.length === 16 ? { id: match[1], secret } : null;
}

/** The code as typed, in capitals without spaces or dashes, or null */
export function normalizeCode(typed) {
  const code = String(typed || '').replace(/[\s-]/g, '').toUpperCase();
  if (code.length !== 10 || [...code].some((symbol) => !CODE_ALPHABET.includes(symbol))) {
    return null;
  }
  return code;
}

function lengthPrefixed(bytes) {
  return concat(new Uint8Array([bytes.length >> 8, bytes.length & 0xff]), bytes);
}

export function transcript({ id, mode, client, phoneKey, screenKey }) {
  return sha256(
    concat(
      lengthPrefixed(utf8(LABEL)),
      lengthPrefixed(utf8(id)),
      lengthPrefixed(utf8(mode)),
      lengthPrefixed(utf8(client)),
      lengthPrefixed(phoneKey),
      lengthPrefixed(screenKey),
    ),
  );
}

export function deriveKeys({ shared, secret, transcript: salt }) {
  const prk = hmac(sha256, salt, concat(shared, secret));
  const expand = (info) => hmac(sha256, prk, concat(utf8(info), new Uint8Array([1])));
  return { confirm: expand('confirm'), up: expand('up'), down: expand('down') };
}

export function confirmOf({ confirmKey, transcript: th, device }) {
  return hmac(sha256, confirmKey, concat(utf8('screen'), th, device));
}

/** The six digits the screen and the app show once a hello is done (pairingCheckNumber in Dart) */
export function checkNumberOf({ confirmKey, transcript: th }) {
  const mac = hmac(sha256, confirmKey, concat(utf8('check'), th));
  const value = ((mac[0] << 24) >>> 0) + (mac[1] << 16) + (mac[2] << 8) + mac[3];
  return String(value % 1000000).padStart(6, '0');
}

export function sameBytes(a, b) {
  if (a.length !== b.length) {
    return false;
  }
  let difference = 0;
  for (let i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference === 0;
}

export function newKeyPair(secretKey = p256.utils.randomSecretKey()) {
  return { secretKey, publicKey: p256.getPublicKey(secretKey, true) };
}

/** The x coordinate of the ECDH point, 32 bytes; throws on a key that is not a point of the curve */
export function agree(secretKey, peerKey) {
  if (peerKey.length !== 33 || (peerKey[0] !== 2 && peerKey[0] !== 3)) {
    throw new Error('not a compressed point');
  }
  return p256.getSharedSecret(secretKey, peerKey, true).slice(1);
}

export function seal({ keys, transcript: th, direction, nonce, plain }) {
  const key = direction === UP ? keys.up : keys.down;
  return gcm(key, nonce, concat(th, new Uint8Array([direction]))).encrypt(plain);
}

/** The plain bytes, or null when they do not decrypt */
export function open({ keys, transcript: th, direction, nonce, sealed }) {
  const key = direction === UP ? keys.up : keys.down;
  try {
    return gcm(key, nonce, concat(th, new Uint8Array([direction]))).decrypt(sealed);
  } catch {
    return null;
  }
}

export function randomBytes(length) {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return bytes;
}

/**
 * Says hello to the screen as the browser page and checks its proof. [post] sends JSON and gives {status, json}.
 * Gives the channel of the rest of the pairing, or throws an Error whose message is one of: expired, used,
 * throttled, wrongCode, invalid, unreachable.
 */
export async function hello({ id, mode, secret, post, keyPair = newKeyPair() }) {
  let answer;
  try {
    answer = await post(`/p/${id}/hello`, { v: VERSION, mode, client: 'web', pk: toBase64(keyPair.publicKey) });
  } catch {
    throw new Error('unreachable');
  }
  if (answer.status === 410) {
    throw new Error(answer.json && answer.json.error === 'used' ? 'used' : 'expired');
  }
  if (answer.status === 429) {
    throw new Error('throttled');
  }
  if (answer.status !== 200) {
    throw new Error('invalid');
  }
  const screenKey = fromBase64(answer.json.pk);
  const device = fromBase64(answer.json.d);
  const confirm = fromBase64(answer.json.confirm);
  if (!screenKey || !device || !confirm) {
    throw new Error('invalid');
  }
  let shared;
  try {
    shared = agree(keyPair.secretKey, screenKey);
  } catch {
    throw new Error('invalid');
  }
  const th = transcript({ id, mode, client: 'web', phoneKey: keyPair.publicKey, screenKey });
  const keys = deriveKeys({ shared, secret, transcript: th });
  if (!sameBytes(confirmOf({ confirmKey: keys.confirm, transcript: th, device }), confirm)) {
    throw new Error('wrongCode');
  }
  return {
    id,
    device: JSON.parse(decoder.decode(device)),
    handle: toBase64(th.slice(0, 8)),
    sealMessage(message) {
      const nonce = randomBytes(12);
      const plain = utf8(JSON.stringify(message));
      return { v: VERSION, h: toBase64(th.slice(0, 8)), n: toBase64(nonce), c: toBase64(seal({ keys, transcript: th, direction: UP, nonce, plain })) };
    },
    openAnswer(envelope) {
      const nonce = fromBase64(envelope && envelope.n);
      const sealed = fromBase64(envelope && envelope.c);
      if (!nonce || !sealed) {
        return null;
      }
      const plain = open({ keys, transcript: th, direction: DOWN, nonce, sealed });
      if (!plain) {
        return null;
      }
      try {
        return JSON.parse(decoder.decode(plain));
      } catch {
        return null;
      }
    },
  };
}
