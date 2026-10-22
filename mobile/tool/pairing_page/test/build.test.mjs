// The page in mobile/assets/pairing is the build of these sources: a change of a source without npm run build fails

import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { buildPage } from '../build.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const committed = join(here, '..', '..', '..', 'assets', 'pairing');

test('the committed page is up to date', async () => {
  const out = mkdtempSync(join(tmpdir(), 'pairing-page-'));
  try {
    await buildPage(out);
    for (const name of ['index.html', 'app.js', 'app.css', 'LICENSE-noble.txt']) {
      assert.equal(readFileSync(join(out, name), 'utf8'), readFileSync(join(committed, name), 'utf8'), `${name}: run npm run build`);
    }
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});

test('no inline script or style, which the policy of the screen would block', () => {
  const html = readFileSync(join(committed, 'index.html'), 'utf8');
  assert.ok(!/<script>/.test(html));
  assert.ok(!/<script(?![^>]*\bsrc=)[^>]*>/.test(html));
  assert.ok(!/style=/.test(html));
  assert.ok(!/<style/.test(html));
});

test('every text goes in as text, and the Open it link carries no secret', () => {
  const source = readFileSync(join(here, '..', 'src', 'app.js'), 'utf8');
  for (const sink of ['innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(', 'new Function']) {
    assert.ok(!source.includes(sink), `app.js uses ${sink}`);
  }
  // The link names the page (origin and path), never the fragment with the secret of the code
  assert.ok(/immuch360:\/\/pair\?u=\$\{encodeURIComponent\(window\.location\.origin \+ window\.location\.pathname\)\}/.test(source));
  assert.ok(!/encodeURIComponent\(window\.location\.href\)/.test(source));
  const html = readFileSync(join(committed, 'index.html'), 'utf8');
  assert.ok(!/autocomplete="current-password"/.test(html), 'the browser would offer to save the password');
});
