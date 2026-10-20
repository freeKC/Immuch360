# FFmpeg of the macOS libmpv of Immuch360 Desktop: the recipe's mk-pkg-ffmpeg/default.nix (media-kit/libmpv-darwin-build
# at the commit .github/workflows/immuch360-libmpv.yml pins) without its four patches, copied over it by
# apply_overlay.sh. They were made for FFmpeg 6.0: two (HLS seek, DASH base URL) no longer apply to the FFmpeg commit of
# packages.lock.nix and concern streams the app never gives libmpv (local files and its own loopback bridge), one is for
# iOS only (HDR textures), and the VP9 one adds a separate VideoToolbox VP9 decoder where FFmpeg's vp9_videotoolbox
# hwaccel, enabled by the recipe's meson.build, already decodes VP9 on the GPU. The configure options stay the recipe's
# (its meson.build): the default flavor, LGPL only, no GPL or nonfree part.
{
  pkgs ? import ../../utils/default/pkgs.nix,
  os ? import ../../utils/default/os.nix,
  arch ? pkgs.callPackage ../../utils/default/arch.nix { },
  variant ? import ../../utils/default/variant.nix,
  flavor ? import ../../utils/default/flavor.nix,
}:

let
  name = "ffmpeg";
  packageLock = (import ../../../packages.lock.nix).${name};
  inherit (packageLock) version;

  flavors = import ../../utils/constants/flavors.nix;
  variants = import ../../utils/constants/variants.nix;
  callPackage = pkgs.lib.callPackageWith {
    inherit
      pkgs
      os
      arch
      variant
      flavor
      ;
  };
  nativeFile = callPackage ../../utils/native-file/default.nix { };
  crossFile = callPackage ../../utils/cross-file/default.nix { };
  mbedtls = callPackage ../mk-pkg-mbedtls/default.nix { };
  dav1d = callPackage ../mk-pkg-dav1d/default.nix { };
  libxml2 = callPackage ../mk-pkg-libxml2/default.nix { };
  libvorbis = callPackage ../mk-pkg-libvorbis/default.nix { };
  libvpx = callPackage ../mk-pkg-libvpx/default.nix { };
  libx264 = callPackage ../mk-pkg-libx264/default.nix { };

  pname = import ../../utils/name/package.nix name;
  src = callPackage ../../utils/fetch-tarball/default.nix {
    name = "${pname}-source-${version}";
    inherit (packageLock) url sha256;
  };
  patchedSource = pkgs.runCommand "${pname}-patched-source-${version}" { } ''
    cp -r ${src} src
    export src=$PWD/src
    chmod -R 777 $src


    cp ${./meson.build} $src/meson.build
    cp ${./meson.options} $src/meson.options

    cp -r $src $out
  '';
in

pkgs.stdenvNoCC.mkDerivation {
  name = "${pname}-${os}-${arch}-${variant}-${flavor}-${version}";
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
  buildInputs =
    [ mbedtls ]
    ++ pkgs.lib.optionals (flavor == flavors.encodersgpl) [
      libvorbis
    ]
    ++ pkgs.lib.optionals (variant == variants.video) [
      dav1d
      libxml2
    ]
    ++ pkgs.lib.optionals (variant == variants.video && flavor == flavors.encodersgpl) [
      libvpx
      libx264
    ];
  configurePhase = ''
    meson setup build $src \
      --native-file ${nativeFile} \
      --cross-file ${crossFile} \
      --prefix=$out \
      -Dvariant=${variant} \
      -Dflavor=${flavor} |
      tee configure.log
  '';
  buildPhase = ''
    meson compile -vC build $(basename $src)
  '';
  installPhase = ''
    # manual install to preserve symlinks (meson install -C build)
    cp -r build/dist$out $out

    # copy configure.log
    cp configure.log $out/share/ffmpeg/
  '';
}
