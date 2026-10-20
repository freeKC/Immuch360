# The sources of the macOS libmpv of Immuch360 Desktop, copied over packages.lock.nix of the build recipe
# (media-kit/libmpv-darwin-build) by apply_overlay.sh. Each sha256 is the SHA-256 of the archive as downloaded (the
# recipe's fetch-tarball), except fftools-ffi's, a Nix hash; .github/workflows/immuch360-libmpv.yml checks every
# archive again and publishes them with the release. FFmpeg, mpv, libplacebo and fast_float are the commits the Windows
# build uses (inputs of the workflow and .github/desktop/libmpv/sources.lock); the other libraries keep the recipe's
# versions.
{
  dav1d = {
    version = "1.2.1";
    url = "https://code.videolan.org/videolan/dav1d/-/archive/1.2.1/dav1d-1.2.1.tar.bz2";
    sha256 = "a4003623cdc0109dec3aac8435520aa3fb12c4d69454fa227f2658cdb6dab5fa";
  };
  fast_float = {
    version = "54571f86";
    url = "https://github.com/fastfloat/fast_float/archive/54571f86e3a8124c39bc4765ff64d766b4e25efc.tar.gz";
    sha256 = "ed041b6cc07d0af897a7cdf4c8640008d02b8528fb247416288c595375051298";
  };
  ffmpeg = {
    version = "5b9a3ad7";
    url = "https://github.com/FFmpeg/FFmpeg/archive/5b9a3ad71a4b54979e7afc3a1a4269763c4f41fc.tar.gz";
    sha256 = "eb8987d34d1735749af5f6e858b21b92deaf0d4d9261d4ba1da3c509d82a4f88";
  };
  fftools-ffi = {
    version = "9b0d4da0";
    url = "https://github.com/moffatman/fftools-ffi/archive/9b0d4da026d9c830702ec043c1f1f98d407025af.tar.gz";
    sha256 = "mgf3ddt3yjmYBd2D0WeEnhgxKNjrEbjYnDx2t4YCfU8=";
  };
  freetype = {
    version = "2.13.2";
    url = "https://downloads.sourceforge.net/project/freetype/freetype2/2.13.2/freetype-2.13.2.tar.xz";
    sha256 = "12991c4e55c506dd7f9b765933e62fd2be2e06d421505d7950a132e4f1bb484d";
  };
  fribidi = {
    version = "1.0.13";
    url = "https://github.com/fribidi/fribidi/releases/download/v1.0.13/fribidi-1.0.13.tar.xz";
    sha256 = "7fa16c80c81bd622f7b198d31356da139cc318a63fc7761217af4130903f54a2";
  };
  harfbuzz = {
    version = "8.1.1";
    url = "https://github.com/harfbuzz/harfbuzz/archive/8.1.1.tar.gz";
    sha256 = "b16e6bc0fc7e6a218583f40c7d201771f2e3072f85ef6e9217b36c1dc6b2aa25";
  };
  libass = {
    version = "0.17.1";
    url = "https://github.com/libass/libass/releases/download/0.17.1/libass-0.17.1.tar.xz";
    sha256 = "f0da0bbfba476c16ae3e1cfd862256d30915911f7abaa1b16ce62ee653192784";
  };
  libogg = {
    version = "1.3.5";
    url = "https://github.com/xiph/ogg/releases/download/v1.3.5/libogg-1.3.5.tar.gz";
    sha256 = "0eb4b4b9420a0f51db142ba3f9c64b333f826532dc0f48c6410ae51f4799b664";
  };
  libplacebo = {
    version = "3330a515";
    url = "https://github.com/haasn/libplacebo/archive/3330a515d62139259c26239014f286e233bd3a5c.tar.gz";
    sha256 = "57b8b2beaba218523cef9839af12c9d44785b6cf8e5f79ca3aa55367d7420c80";
  };
  libpng = {
    version = "1.6.40";
    url = "https://github.com/pnggroup/libpng/archive/v1.6.40.tar.gz";
    sha256 = "62d25af25e636454b005c93cae51ddcd5383c40fa14aa3dae8f6576feb5692c2";
  };
  libpngPatch = {
    version = "1.6.40-1";
    url = "https://wrapdb.mesonbuild.com/v2/libpng_1.6.40-1/get_patch";
    sha256 = "bad558070e0a82faa5c0ae553bcd12d49021fc4b628f232a8e58c3fbd281aae1";
  };
  libvorbis = {
    version = "1.3.7";
    url = "https://github.com/xiph/vorbis/releases/download/v1.3.7/libvorbis-1.3.7.tar.gz";
    sha256 = "0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab";
  };
  libvpx = {
    version = "1.13.0+1";
    url = "https://gitlab.freedesktop.org/gstreamer/meson-ports/libvpx/-/archive/90d26fac0d895969a82cd873ad36e39737104c44/libvpx-v1.13.0.tar.gz";
    sha256 = "4f872ad2709d17b848b3588231495e432c42b9263731b9121fa210a3c5a893ff";
  };
  libx264 = {
    version = "a8b68ebf";
    url = "https://code.videolan.org/videolan/x264/-/archive/a8b68ebfaa68621b5ac8907610d3335971839d52/libx264-a8b68ebfaa68621b5ac8907610d3335971839d52.tar.gz";
    sha256 = "164688b63f11a6e4f6d945057fc5c57d5eefb97973d0029fb0303744e10839ff";
  };
  libxml2 = {
    version = "2.11.5";
    url = "https://download.gnome.org/sources/libxml2/2.11/libxml2-2.11.5.tar.xz";
    sha256 = "3727b078c360ec69fa869de14bd6f75d7ee8d36987b071e6928d4720a28df3a6";
  };
  mbedtls = {
    version = "3.4.1";
    url = "https://github.com/Mbed-TLS/mbedtls/archive/refs/tags/v3.4.1.tar.gz";
    sha256 = "a420fcf7103e54e775c383e3751729b8fb2dcd087f6165befd13f28315f754f5";
  };
  mpv = {
    version = "0b7ed670";
    url = "https://github.com/mpv-player/mpv/archive/0b7ed670f7c353dd3dd4f8ae0fc788a181a15aa6.tar.gz";
    sha256 = "d84b3c706592558bfba8e6305d00f86406c647c3b8b317236433e25caf4d9d91";
  };
  uchardet = {
    version = "0.0.8";
    url = "https://www.freedesktop.org/software/uchardet/releases/uchardet-0.0.8.tar.xz";
    sha256 = "e97a60cfc00a1c147a674b097bb1422abd9fa78a2d9ce3f3fdcc2e78a34ac5f0";
  };
}
