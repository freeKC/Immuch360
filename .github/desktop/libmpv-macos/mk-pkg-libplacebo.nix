# libplacebo for the macOS libmpv of Immuch360 Desktop, required by mpv since 0.37 (the recipe, made for mpv 0.36, has
# no package for it). Copied by apply_overlay.sh to nix/packages/mk-pkg-libplacebo/default.nix of the recipe, with
# targets.nix so that it can be built on its own (mk-pkg-libplacebo-macos-arm64). A shared library, which the recipe's
# outputs turn into Placebo.framework like every other library (mk-out-libs.nix): a static C++ library inside libmpv
# would need the C++ runtime added to mpv's link by hand.
#
# Only what libmpv's OpenGL render API needs: libmpv draws through mpv's own OpenGL renderer (render_backend_gpu), so
# libplacebo's OpenGL, Vulkan and Direct3D backends, its shader compilers, LCMS, libdovi, xxhash and unwind are off.
# Its sources come without their git submodules: fast_float (header only, for std::from_chars on floats, which the
# libc++ of macOS 12 lacks) and the Vulkan headers (header only: with Vulkan off, libplacebo still compiles the stubs
# of its Vulkan API, vulkan/stubs.c, which include <vulkan/vulkan.h>) are put in 3rdparty/ from packages.lock.nix;
# Jinja2 and MarkupSafe, the Python modules of its shader preprocessor, come from nixpkgs as build tools, on
# PYTHONPATH: Meson runs the preprocessor with its own Python (find_installation()), not with one that has them, and
# adds the empty submodule folders after that path.
{
  pkgs ? import ../../utils/default/pkgs.nix,
  os ? import ../../utils/default/os.nix,
  arch ? pkgs.callPackage ../../utils/default/arch.nix { },
}:

let
  name = "libplacebo";
  packageLock = (import ../../../packages.lock.nix).${name};
  fastFloatLock = (import ../../../packages.lock.nix).fast_float;
  vulkanHeadersLock = (import ../../../packages.lock.nix).vulkan-headers;
  inherit (packageLock) version;

  callPackage = pkgs.lib.callPackageWith { inherit pkgs os arch; };
  nativeFile = callPackage ../../utils/native-file/default.nix { };
  crossFile = callPackage ../../utils/cross-file/default.nix { };

  pname = import ../../utils/name/package.nix name;
  src = callPackage ../../utils/fetch-tarball/default.nix {
    name = "${pname}-source-${version}";
    inherit (packageLock) url sha256;
  };
  fastFloat = callPackage ../../utils/fetch-tarball/default.nix {
    name = "${pname}-fast-float-source-${fastFloatLock.version}";
    inherit (fastFloatLock) url sha256;
  };
  vulkanHeaders = callPackage ../../utils/fetch-tarball/default.nix {
    name = "${pname}-vulkan-headers-source-${vulkanHeadersLock.version}";
    inherit (vulkanHeadersLock) url sha256;
  };
  fullSource = pkgs.runCommand "${pname}-full-source-${version}" { } ''
    cp -r ${src} $out
    chmod -R u+w $out
    mkdir -p $out/3rdparty/fast_float
    cp -r ${fastFloat}/include $out/3rdparty/fast_float/
    mkdir -p $out/3rdparty/Vulkan-Headers
    cp -r ${vulkanHeaders}/include $out/3rdparty/Vulkan-Headers/
  '';
  pythonPath = pkgs.python3Packages.makePythonPath [
    pkgs.python3Packages.jinja2
    pkgs.python3Packages.markupsafe
  ];
in

pkgs.stdenvNoCC.mkDerivation {
  name = "${pname}-${os}-${arch}-${version}";
  pname = pname;
  inherit version;
  src = fullSource;
  dontUnpack = true;
  enableParallelBuilding = true;
  nativeBuildInputs = [
    pkgs.meson
    pkgs.ninja
    pkgs.pkg-config
    pkgs.python3
  ];
  PYTHONPATH = pythonPath;
  configurePhase = ''
    meson setup build $src \
      --native-file ${nativeFile} \
      --cross-file ${crossFile} \
      --prefix=$out \
      --buildtype=release \
      -Dvulkan=disabled \
      -Dvk-proc-addr=disabled \
      -Dopengl=disabled \
      -Dgl-proc-addr=disabled \
      -Dd3d11=disabled \
      -Dglslang=disabled \
      -Dshaderc=disabled \
      -Dlcms=disabled \
      -Ddovi=enabled \
      -Dlibdovi=disabled \
      -Dunwind=disabled \
      -Dxxhash=disabled \
      -Ddemos=false \
      -Dtests=false \
      -Dbench=false \
      -Dfuzz=false
  '';
  buildPhase = ''
    meson compile -vC build
  '';
  installPhase = ''
    meson install -C build
  '';
}
