// The glTF-Validator of Khronos on the 3D scenes of Immuch360 (lot S1; design-final 2026-10-27, section 8.2, point 3).
// Each file named after the package is a photo that carries a scene, <name>_scene3D.jpg: its last SceneLength bytes, as
// its XMP says, are a glb of the format glb-layers-v1, validated here, which must give no error and no warning. The
// infos are printed (KHR_xmp_json_ld, an extension the validator does not know; textures whose sides are not powers of
// two). The validator is the npm package gltf-validator (Apache-2.0, https://github.com/KhronosGroup/glTF-Validator),
// a tool of the CI only, unpacked from its archive once checked by its SHA-256 in
// .github/workflows/immuch360-desktop.yml.
//
//   node validate_scenes.mjs <folder of the package> <scene>...   exit 1 on any error or warning, or a file without
//                                                                 its scene
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [packageFolder, ...files] = process.argv.slice(2);
if (!packageFolder || files.length === 0) {
  console.error('usage: node validate_scenes.mjs <folder of gltf-validator> <scene>...');
  process.exit(2);
}
const validator = (await import(pathToFileURL(resolve(join(packageFolder, 'index.js'))).href)).default;

let failed = false;
for (const file of files) {
  const bytes = readFileSync(file);
  const head = bytes.subarray(0, 131072).toString('latin1');
  const length = /Immuch360:SceneLength="(\d+)"/.exec(head);
  if (!length || Number(length[1]) > bytes.length) {
    console.error(`${file}: no scene named by its XMP`);
    failed = true;
    continue;
  }
  const glb = new Uint8Array(bytes.subarray(bytes.length - Number(length[1])));
  const report = await validator.validateBytes(glb, { maxIssues: 100, uri: file });
  const issues = report.issues;
  for (const message of issues.messages) {
    const level = ['error', 'warning', 'info', 'hint'][message.severity];
    console.log(`${file}: ${level} ${message.code} at ${message.pointer ?? '/'}: ${message.message}`);
  }
  const info = report.info ?? {};
  console.log(
    `${file}: ${issues.numErrors} errors, ${issues.numWarnings} warnings, ${issues.numInfos} infos; ` +
      `${info.drawCallCount ?? '?'} meshes, ${info.totalVertexCount ?? '?'} vertices, ` +
      `${info.totalTriangleCount ?? '?'} triangles, validator ${report.validatorVersion}`,
  );
  if (issues.numErrors > 0 || issues.numWarnings > 0) {
    failed = true;
  }
}
process.exit(failed ? 1 : 0);
