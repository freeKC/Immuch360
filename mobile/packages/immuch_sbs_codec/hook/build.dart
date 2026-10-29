// The build hook of immuch_sbs_codec: compiles the crate in rust/ for the computers of Immuch360 Desktop, and builds
// nothing for any other target. Without that early return the crate would be compiled into the phone and Quest APKs
// and the iOS app, which never call it (design-final 2026-10-26, section 2.8). Modelled on upstream's
// native/native_core/hook/build.dart; the toolchain is the one the desktop jobs already install for native_core.

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

/// The systems and processors the desktop builds target, as the targets of rust/rust-toolchain.toml
const _built = {
  (OS.windows, Architecture.x64),
  (OS.linux, Architecture.x64),
  (OS.macOS, Architecture.arm64),
  (OS.macOS, Architecture.x64),
};

// Cargo's dep-info only lists source files, so these have to rerun the hook too.
const _manifests = ['rust/Cargo.toml', 'rust/Cargo.lock', 'rust/rust-toolchain.toml'];

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }
    final code = input.config.code;
    if (!_built.contains((code.targetOS, code.targetArchitecture))) {
      return;
    }
    output.dependencies.addAll(_manifests.map(input.packageRoot.resolve));
    // The crates are pinned to exact versions in Cargo.toml, so the lock cannot move during a build
    await const RustBuilder(assetName: 'src/bindings.dart', cratePath: 'rust').run(input: input, output: output);
  });
}
