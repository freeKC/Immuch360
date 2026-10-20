# libpng of the macOS libmpv of Immuch360 Desktop: the recipe's mk-pkg-libpng/default.nix (media-kit/libmpv-darwin-build
# at the commit .github/workflows/immuch360-libmpv.yml pins), copied over it by apply_overlay.sh, with one line of
# pngpriv.h changed. libpng 1.6.40 includes the <fp.h> of the classic Mac OS when TARGET_OS_MAC is defined and <math.h>
# was not included yet; the SDK of Xcode 16 defines TARGET_OS_MAC there, has no <fp.h> and guards its <math.h> under
# another name, so every file that includes pngpriv.h stops ("'fp.h' file not found"). Without TARGET_OS_MAC in that
# test libpng includes <math.h>, as libpng 1.6.44 and later do on every Apple system.
{
  pkgs ? import ../../utils/default/pkgs.nix,
  os ? import ../../utils/default/os.nix,
  arch ? pkgs.callPackage ../../utils/default/arch.nix { },
}:

let
  name = "libpng";
  packageLock = (import ../../../packages.lock.nix).${name};
  packagePatchLock = (import ../../../packages.lock.nix).libpngPatch;
  inherit (packageLock) version;

  callPackage = pkgs.lib.callPackageWith { inherit pkgs os arch; };
  nativeFile = callPackage ../../utils/native-file/default.nix { };
  crossFile = callPackage ../../utils/cross-file/default.nix { };

  pname = import ../../utils/name/package.nix name;
  src = callPackage ../../utils/fetch-tarball/default.nix {
    name = "${pname}-source-${version}";
    inherit (packageLock) url sha256;
  };
  libpngPatch = builtins.fetchurl {
    inherit (packagePatchLock) url sha256;
  };
  patchedSource =
    pkgs.runCommand "${pname}-patched-source-${version}"
      {
        nativeBuildInputs = [
          pkgs.unzip
          pkgs.rsync
        ];
      }
      ''
        cp -r ${src} src
        export src=$PWD/src
        chmod -R 777 $src

        # extract and patch libpng dependency
        unzip ${libpngPatch} -d libpng-patch
        rsync -a libpng-patch/libpng-*/ $src/

        # <math.h>, not the <fp.h> of the classic Mac OS, on macOS (see the header of this file)
        if ! grep -q 'defined(__SC__) || defined(TARGET_OS_MAC)' $src/pngpriv.h; then
          echo "pngpriv.h: no TARGET_OS_MAC test to change"
          exit 1
        fi
        sed -i 's/defined(__SC__) || defined(TARGET_OS_MAC)/defined(__SC__)/' $src/pngpriv.h
        if grep -q 'TARGET_OS_MAC' $src/pngpriv.h; then
          echo "pngpriv.h: TARGET_OS_MAC is still tested"
          exit 1
        fi

        cp -r $src $out
      '';
in

pkgs.stdenvNoCC.mkDerivation {
  name = "${pname}-${os}-${arch}-${version}";
  pname = pname;
  inherit version;
  src = patchedSource;
  dontUnpack = true;
  enableParallelBuilding = true;
  nativeBuildInputs = [
    pkgs.meson
    pkgs.ninja
    pkgs.pkg-config
  ];
  configurePhase = ''
    meson setup build $src \
      --native-file ${nativeFile} \
      --cross-file ${crossFile} \
      --prefix=$out
  '';
  buildPhase = ''
    meson compile -vC build
  '';
  installPhase = ''
    meson install -C build
  '';
}
