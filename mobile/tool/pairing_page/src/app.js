// The browser page of "Sign in with your phone": a phone without Immuch360 scans the QR code of a big screen with its
// camera and lands here. The page runs the same hello as the app (protocol.js), checks that it talks to the screen
// that shows this code, and sends the server address, the email and the password sealed with the pairing key. The
// screen signs in itself with them and forgets the password. Served by the screen with a strict
// Content-Security-Policy: no inline script or style, no other origin. Every text goes in with textContent.
//
// The "Open it" link hands the app the screen's address only, never the secret of the code: the app scans the code
// on the screen itself, so that a link from anywhere else cannot make it sign a device in.

import { hello, normalizeCode, parseFragment, utf8, VERSION } from './protocol.js';

// English, replaced by the screen's own language from /p/info
const DEFAULTS = {
  pairing_web_title_tv: 'Sign your TV in',
  pairing_web_title_headset: 'Sign your headset in',
  pairing_web_title_computer: 'Sign your computer in',
  pairing_web_intro:
    'Your password is encrypted on your home network and used once to sign the screen in. The screen does not keep it.',
  pairing_web_code: 'Code shown on the screen',
  pairing_web_connect: 'Sign in',
  pairing_web_connecting: 'Signing in…',
  pairing_web_done: 'Done: look at the screen.',
  pairing_web_open_app: 'Immuch360 on this phone? Open it',
  pairing_web_prefer_app: 'Safer and faster: use Immuch360 on your phone.',
  pairing_web_get_app: 'Get Immuch360',
  pairing_web_oauth: 'Your server signs in with {provider}: install Immuch360 on your phone to sign this screen in.',
  pairing_web_bad_credentials: 'Wrong email or password.',
  pairing_web_lost: 'Lost contact with the screen. Nothing was signed in: try again.',
  pairing_web_expired: 'This code expired. Scan the new code on the screen.',
  pairing_web_wrong_code: "The code doesn't match. Check it on the screen and try again.",
  pairing_web_unreachable: "Can't reach the screen. Your phone must be on the same Wi-Fi.",
  pairing_web_server_unreachable: "The screen can't reach this server. Check the address.",
  pairing_web_paused: 'The screen shows no code now. Choose Show a new code on the screen.',
  server_info_box_server_url: 'Server URL',
  email: 'Email',
  password: 'Password',
};

// The README lists the stores and the downloads
const STORE_LINK = 'https://github.com/freeKC/Immuch360#readme';

let texts = { ...DEFAULTS };
const $ = (id) => document.getElementById(id);

function text(key, values = {}) {
  let value = texts[key] || DEFAULTS[key] || key;
  for (const [name, replacement] of Object.entries(values)) {
    value = value.split(`{${name}}`).join(replacement);
  }
  return value;
}

async function request(method, path, body) {
  const response = await fetch(path, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
    cache: 'no-store',
    credentials: 'omit',
    redirect: 'error',
    referrerPolicy: 'no-referrer',
  });
  let json = {};
  try {
    json = await response.json();
  } catch {
    // An empty body: the status tells enough
  }
  return { status: response.status, json };
}

const post = (path, body) => request('POST', path, body);

function show(element, visible) {
  element.hidden = !visible;
}

function showError(message) {
  $('error').textContent = message;
  show($('error'), Boolean(message));
}

async function main() {
  // The secret of the QR code, then out of the address bar and the history
  const fragment = parseFragment(window.location.hash);
  const openLink = `immuch360://pair?u=${encodeURIComponent(window.location.origin + window.location.pathname)}`;
  if (window.location.hash) {
    window.history.replaceState(null, '', window.location.pathname);
  }

  let info = { device: {}, id: null };
  try {
    const answer = await request('GET', '/p/info');
    if (answer.status === 200) {
      info = answer.json;
      texts = { ...DEFAULTS, ...(info.texts || {}) };
    }
  } catch {
    showError(text('pairing_web_unreachable'));
  }
  const kind = info.device && info.device.kind;
  const title = text(kind === 'computer' ? 'pairing_web_title_computer' : kind === 'headset' ? 'pairing_web_title_headset' : 'pairing_web_title_tv');
  document.title = title;
  $('title').textContent = title;
  $('device').textContent = (info.device && info.device.label) || '';
  $('intro').textContent = text('pairing_web_intro');
  $('server-label').textContent = text('server_info_box_server_url');
  $('email-label').textContent = text('email');
  $('password-label').textContent = text('password');
  $('code-label').textContent = text('pairing_web_code');
  $('submit').textContent = text('pairing_web_connect');
  $('prefer').textContent = text('pairing_web_prefer_app');
  $('done').textContent = text('pairing_web_done');
  $('get-app').textContent = text('pairing_web_get_app');
  $('get-app').href = STORE_LINK;
  show($('code-field'), !fragment);
  $('open-app').textContent = text('pairing_web_open_app');
  $('open-app').href = openLink;
  show($('open-app'), true);

  let channel = null;
  const form = $('form');
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    showError('');
    const button = $('submit');
    button.disabled = true;
    button.textContent = text('pairing_web_connecting');
    try {
      await signIn();
    } finally {
      button.disabled = false;
      button.textContent = text('pairing_web_connect');
    }
  });

  async function signIn() {
    let id = fragment ? fragment.id : info.id;
    let secret;
    let mode;
    if (fragment) {
      mode = 'qr';
      secret = fragment.secret;
    } else {
      const code = normalizeCode($('code').value);
      if (!code) {
        showError(text('pairing_web_wrong_code'));
        return;
      }
      mode = 'code';
      secret = utf8(code);
      // The code may have rotated since the page opened
      const fresh = await request('GET', '/p/info').catch(() => null);
      id = fresh && fresh.status === 200 ? fresh.json.id : id;
    }
    if (!id) {
      showError(text('pairing_web_paused'));
      return;
    }
    try {
      if (!channel || channel.id !== id) {
        channel = await hello({ id, mode, secret, post });
      }
    } catch (error) {
      channel = null;
      const reason = error && error.message;
      showError(
        text(
          reason === 'wrongCode'
            ? 'pairing_web_wrong_code'
            : reason === 'unreachable'
              ? 'pairing_web_unreachable'
              : reason === 'expired' || reason === 'used' || reason === 'throttled'
                ? 'pairing_web_expired'
                : 'pairing_web_lost',
        ),
      );
      return;
    }
    let answer;
    try {
      answer = await post(
        `/p/${id}/login`,
        channel.sealMessage({ v: VERSION, server: $('server').value.trim(), email: $('email').value.trim(), password: $('password').value }),
      );
    } catch {
      showError(text('pairing_web_lost'));
      return;
    }
    if (answer.status !== 200) {
      channel = null;
      // 400 rejected: the code is used up, a new one shows on the screen; anything else: no trusted answer
      const used = answer.status === 410 || (answer.status === 400 && answer.json && answer.json.error === 'rejected');
      showError(text(used ? 'pairing_web_expired' : 'pairing_web_lost'));
      return;
    }
    const result = channel.openAnswer(answer.json);
    if (!result) {
      channel = null;
      showError(text('pairing_web_lost'));
      return;
    }
    $('password').value = '';
    // A wrong password or server address keeps the code for another try, up to three
    if (result.triesLeft === 0) {
      channel = null;
    }
    switch (result.status) {
      case 'signedIn':
        show(form, false);
        show($('success'), true);
        return;
      case 'badCredentials':
        showError(text(result.triesLeft ? 'pairing_web_bad_credentials' : 'pairing_web_expired'));
        return;
      case 'oauthOnly':
        showError(text('pairing_web_oauth', { provider: result.provider || 'OAuth' }));
        return;
      case 'serverUnreachable':
        showError(text('pairing_web_server_unreachable'));
        return;
      default:
        channel = null;
        showError(text('pairing_web_lost'));
    }
  }
}

main();
