// Builds the browser page of "Sign in with your phone" into mobile/assets/pairing, where the big screens serve it
// from (pairing_server.dart): the page and its style as they are, the script bundled with the noble libraries (MIT)
// into one file, and their licence. The output is committed; test/build.test.mjs checks it is up to date.
//
//   npm ci && npm run build      (from mobile/tool/pairing_page)

import { build } from 'esbuild';
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

export async function buildPage(outDir = join(here, '..', '..', 'assets', 'pairing')) {
  mkdirSync(outDir, { recursive: true });
  await build({
    entryPoints: [join(here, 'src', 'app.js')],
    outfile: join(outDir, 'app.js'),
    bundle: true,
    minify: true,
    format: 'iife',
    // Every phone browser of the last years; BigInt (the curve) needs 2020
    target: ['es2020'],
    legalComments: 'none',
    charset: 'utf8',
    logLevel: 'warning',
  });
  copyFileSync(join(here, 'src', 'index.html'), join(outDir, 'index.html'));
  copyFileSync(join(here, 'src', 'app.css'), join(outDir, 'app.css'));
  const licences = ['curves', 'ciphers', 'hashes'].map((name) => {
    const version = JSON.parse(readFileSync(join(here, 'node_modules', '@noble', name, 'package.json'), 'utf8')).version;
    const text = readFileSync(join(here, 'node_modules', '@noble', name, 'LICENSE'), 'utf8').trim();
    return `@noble/${name} ${version}, bundled in app.js\n\n${text}\n`;
  });
  writeFileSync(join(outDir, 'LICENSE-noble.txt'), licences.join('\n---\n\n'));
  return outDir;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const out = await buildPage();
  console.log(`built ${out}`);
}
