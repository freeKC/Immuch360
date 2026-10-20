# mpv of the macOS libmpv of Immuch360 Desktop: the recipe's mk-pkg-mpv/default.nix (media-kit/libmpv-darwin-build at
# the commit .github/workflows/immuch360-libmpv.yml pins) brought to the mpv commit of packages.lock.nix, copied over it
# by apply_overlay.sh. What differs:
#   - libplacebo, required since mpv 0.37, built by mk-pkg-libplacebo (a dependency of its own, as the recipe builds
#     every library), and libass, required in every variant since 0.37 (the recipe removed it from the audio one by a
#     patch of 0.36);
#   - the list of disabled options follows meson.options of that commit (meson refuses an option it does not know),
#     and the build date is left out so that two runs of the same sources give the same library;
#   - one patch, immuch360-mpv-objc-language.patch, in place of the recipe's three: the Objective-C language added
#     where Cocoa is, as the recipe's mpv-fix-missing-objc.patch does for 0.36 (mpv adds it only once xcrun reports
#     an SDK, and the Nix sandbox has no xcrun). The other two are for iOS (AudioUnit) and the audio variant.
{
  pkgs ? import ../../utils/default/pkgs.nix,
  os ? import ../../utils/default/os.nix,
  arch ? pkgs.callPackage ../../utils/default/arch.nix { },
  variant ? import ../../utils/default/variant.nix,
}:

let
  name = "mpv";
  packageLock = (import ../../../packages.lock.nix).${name};
  inherit (packageLock) version;

  variants = import ../../utils/constants/variants.nix;
  oses = import ../../utils/constants/oses.nix;
  callPackage = pkgs.lib.callPackageWith {
    inherit
      pkgs
      os
      arch
      variant
      ;
  };
  nativeFile = callPackage ../../utils/native-file/default.nix { };
  crossFile = callPackage ../../utils/cross-file/default.nix { };
  xctoolchainLipo = callPackage ../../utils/xctoolchain/lipo.nix { };
  ffmpeg = callPackage ../mk-pkg-ffmpeg/default.nix { };
  uchardet = callPackage ../mk-pkg-uchardet/default.nix { };
  libass = callPackage ../mk-pkg-libass/default.nix { };
  libplacebo = callPackage ../mk-pkg-libplacebo/default.nix { };

  nativeBuildInputs = [
    pkgs.meson
    pkgs.ninja
    pkgs.pkg-config
    pkgs.python3
    xctoolchainLipo
  ];

  pname = import ../../utils/name/package.nix name;
  src = callPackage ../../utils/fetch-tarball/default.nix {
    name = "${pname}-source-${version}";
    inherit (packageLock) url sha256;
  };
  patchedSource = pkgs.runCommand "${pname}-patched-source-${variant}-${version}" { } ''
    cp -r ${src} src
    export src=$PWD/src
    chmod -R 777 $src

    cd $src
    patch -p1 <${../../../patches/immuch360-mpv-objc-language.patch}
    cd -

    cp -r $src $out
  '';
  fixedSource = callPackage ../../utils/patch-shebangs/default.nix {
    name = "${pname}-fixed-source-${variant}-${version}";
    src = patchedSource;
    inherit nativeBuildInputs;
  };
in

pkgs.stdenvNoCC.mkDerivation {
  name = "${pname}-${os}-${arch}-${variant}-${version}";
  pname = pname;
  inherit version;
  src = fixedSource;
  dontUnpack = true;
  enableParallelBuilding = true;
  inherit nativeBuildInputs;
  # libass and libplacebo are required by mpv since 0.37, whatever the variant
  buildInputs =
    [
      ffmpeg
      libass
      libplacebo
    ]
    ++ pkgs.lib.optionals (variant == "video") [
      uchardet
    ];
  configurePhase = ''
    DISABLE_ALL_OPTIONS=(
      `# booleans`
      -Dgpl=false `# GPL (version 2 or later) build: off, the library is LGPL 2.1 or later`
      -Dcplayer=false
      -Dlibmpv=false
      -Dbuild-date=false
      -Dtests=false
      -Dfuzzers=false

      `# every feature of meson.options of the mpv commit, then the ones below turned back on`
      -Dcdda=disabled
      -Dcplugins=disabled
      -Ddvbin=disabled
      -Ddvda=disabled
      -Ddvdnav=disabled
      -Diconv=disabled
      -Djavascript=disabled
      -Dlua=disabled
      -Djpeg=disabled
      -Dlcms2=disabled
      -Dlibarchive=disabled
      -Dlibavdevice=disabled
      -Dlibbluray=disabled
      -Dlibcurl=disabled
      -Dpthread-debug=disabled
      -Drubberband=disabled
      -Dsdl2-gamepad=disabled
      -Dsubrandr=disabled
      -Duchardet=disabled
      -Duwp=disabled
      -Dvapoursynth=disabled
      -Dvector=disabled
      -Dwin32-threads=disabled
      -Dx11-clipboard=disabled
      -Dzimg=disabled
      -Dzlib=disabled
      -Dalsa=disabled
      -Daudiounit=disabled
      -Dcoreaudio=disabled
      -Davfoundation=disabled
      -Djack=disabled
      -Dopenal=disabled
      -Daudiotrack=disabled
      -Daaudio=disabled
      -Dopensles=disabled
      -Doss-audio=disabled
      -Dpipewire=disabled
      -Dpulse=disabled
      -Dsdl2-audio=disabled
      -Dsndio=disabled
      -Dwasapi=disabled
      -Damf=disabled
      -Dcaca=disabled
      -Dcocoa=disabled
      -Dd3d11=disabled
      -Ddirect3d=disabled
      -Ddmabuf-wayland=disabled
      -Ddrm=disabled
      -Degl=disabled
      -Degl-android=disabled
      -Degl-angle=disabled
      -Degl-angle-lib=disabled
      -Degl-angle-win32=disabled
      -Degl-drm=disabled
      -Degl-wayland=disabled
      -Degl-x11=disabled
      -Dgbm=disabled
      -Dgl=disabled
      -Dgl-cocoa=disabled
      -Dgl-dxinterop=disabled
      -Dgl-win32=disabled
      -Dgl-x11=disabled
      -Dsdl2-video=disabled
      -Dshaderc=disabled
      -Dsixel=disabled
      -Dspirv-cross=disabled
      -Dplain-gl=disabled
      -Dvdpau=disabled
      -Dvdpau-gl-x11=disabled
      -Dvaapi=disabled
      -Dvaapi-drm=disabled
      -Dvaapi-wayland=disabled
      -Dvaapi-win32=disabled
      -Dvaapi-x11=disabled
      -Dvulkan=disabled
      -Dwayland=disabled
      -Dx11=disabled
      -Dxv=disabled
      -Dandroid-media-ndk=disabled
      -Dcuda-hwaccel=disabled
      -Dcuda-interop=disabled
      -Dd3d-hwaccel=disabled
      -Dd3d9-hwaccel=disabled
      -Dgl-dxinterop-d3d9=disabled
      -Dios-gl=disabled
      -Dvideotoolbox-gl=disabled
      -Dvideotoolbox-pl=disabled
      -Dmacos-10-15-4-features=disabled
      -Dmacos-11-features=disabled
      -Dmacos-11-3-features=disabled
      -Dmacos-12-features=disabled
      -Dmacos-cocoa-cb=disabled
      -Dmacos-media-player=disabled
      -Dmacos-touchbar=disabled
      -Dswift-build=disabled
      -Dwin32-smtc=disabled
      -Dhtml-build=disabled
      -Dmanpage-build=disabled
      -Dpdf-build=disabled
      -Dswift-flags=
    )

    COMMON_OPTIONS=(
      `# booleans`
      -Dlibmpv=true `# libmpv library`

      `# misc features`
      -Diconv=enabled `# iconv`
    )

    COMMON_VIDEO_OPTIONS=(
      `# misc features`
      -Duchardet=enabled `# uchardet support`
      -Dzlib=enabled `# zlib`

      `# video output features`
      -Dgl=enabled `# OpenGL context support`
      -Dplain-gl=enabled `# OpenGL without platform-specific code (e.g. for libmpv)`
    )

    MACOS_OPTIONS=(
      `# audio output features`
      -Dcoreaudio=enabled `# CoreAudio audio output`

      `# video output features`
      -Dcocoa=enabled `# Cocoa` `# BUG: required in audio mode since v0.36.0`
    )

    MACOS_VIDEO_OPTIONS=(
      `# video output features`
      -Dgl-cocoa=enabled `# gl-cocoa`

      `# hwaccel features`
      -Dvideotoolbox-gl=enabled `# Videotoolbox with OpenGL`
    )

    IOS_OPTIONS=(
      `# audio output features`
      -Daudiounit=enabled `# AudioUnit output for iOS`
    )

    IOS_VIDEO_OPTIONS=(
      `# hwaccel features`
      -Dios-gl=enabled `# iOS OpenGL ES hardware decoding interop support`
    )

    OPTIONS=("''${DISABLE_ALL_OPTIONS[@]}")

    OPTIONS+=("''${COMMON_OPTIONS[@]}")
    if [ "${variant}" == "${variants.video}" ]; then
      OPTIONS+=("''${COMMON_VIDEO_OPTIONS[@]}")
    fi

    if [ "${os}" == "${oses.macos}" ]; then
      OPTIONS+=("''${MACOS_OPTIONS[@]}")
      if [ "${variant}" == "${variants.video}" ]; then
        OPTIONS+=("''${MACOS_VIDEO_OPTIONS[@]}")
      fi
    elif [ "${os}" == "${oses.ios}" ]; then
      OPTIONS+=("''${IOS_OPTIONS[@]}")
      if [ "${variant}" == "${variants.video}" ]; then
        OPTIONS+=("''${IOS_VIDEO_OPTIONS[@]}")
      fi
    fi

    meson setup build $src \
      --native-file ${nativeFile} \
      --cross-file ${crossFile} \
      --prefix=$out \
      "''${OPTIONS[@]}" |
      tee configure.log
  '';
  buildPhase = ''
    meson compile -vC build
  '';
  installPhase = ''
    meson install -C build

    # copy configure.log
    mkdir -p $out/share/mpv
    cp configure.log $out/share/mpv/
  '';
}
