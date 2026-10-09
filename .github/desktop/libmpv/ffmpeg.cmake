# FFmpeg for the libmpv of Immuch360 Desktop on Windows, built by .github/workflows/immuch360-libmpv.yml.
#
# Copied over packages/ffmpeg.cmake of the build recipe before it is configured. The configuration is media_kit's
# video one (media-kit/libmpv-win32-video-cmake, the libmpv that media_kit_libs_windows_video ships), as kept building
# by its fork Predidit/libmpv-win32-video-cmake at fdf75129 (same DEPENDS and options), with these differences:
#   - the FFmpeg commit or tag comes from the workflow (IMMUCH360_FFMPEG_REF), so a security release is a dispatch
#     input away; its default is the commit of master the fork built green on 2026-09-15;
#   - no source patch: the fork's HLS patch serves its own streaming app, not a photo library;
#   - the filters the 360 and raw camera paths ask mpv for through lavfi-complex (hstack, vstack, crop, pad, the null
#     and format filters and the converters libavfilter inserts between them), the ProRes, VC-1 and raw video
#     decoders, the yuv4mpegpipe demuxer for lossless reference clips, and the AV1, VP9 and VC-1 parsers.
# --enable-version3 stays: OpenSSL 3 is Apache-2.0, compatible with version 3 of the LGPL, so FFmpeg as built here is
# LGPL-3.0-or-later (mobile/packages/media_kit_video/windows/NOTICES.md).
if(NOT IMMUCH360_FFMPEG_REF)
    message(FATAL_ERROR "IMMUCH360_FFMPEG_REF is not set: the workflow passes the FFmpeg commit or tag with "
        "-DIMMUCH360_FFMPEG_REF=")
endif()

ExternalProject_Add(ffmpeg
        DEPENDS
        amf-headers
        avisynth-headers
        ${nvcodec_headers}
        bzip2
        lcms2
        openssl
        libssh
        libsrt
        libass
        libmodplug
        libpng
        libsoxr
        libbs2b
        libwebp
        libzimg
        libmysofa
        fontconfig
        harfbuzz
        opus
        speex
        vorbis
        libvpl
        libjxl
        libxml2
        libplacebo
        dav1d
        openal-soft
    GIT_REPOSITORY https://github.com/FFmpeg/FFmpeg.git
    SOURCE_DIR ${SOURCE_LOCATION}
    GIT_CLONE_FLAGS "--sparse --filter=tree:0"
    GIT_TAG ${IMMUCH360_FFMPEG_REF}
    GIT_CLONE_POST_COMMAND "sparse-checkout set --no-cone /* !tests/ref/fate"
    UPDATE_COMMAND ""
    CONFIGURE_COMMAND ${EXEC} CONF=1 <SOURCE_DIR>/configure
        --cross-prefix=${TARGET_ARCH}-
        --prefix=${MINGW_INSTALL_PREFIX}
        --arch=${TARGET_CPU}
        --target-os=mingw32
        --pkg-config-flags=--static
        --enable-cross-compile

        --disable-gpl
        --disable-nonfree
        --enable-version3
        --enable-static
        --disable-shared
        --disable-vulkan
        --disable-iconv
        --enable-stripping

        --disable-muxers
        --disable-decoders
        --disable-encoders
        --disable-demuxers
        --disable-parsers
        --disable-protocols
        --disable-filters
        --disable-doc
        --disable-programs
        --disable-gray
        --disable-swscale-alpha

        --enable-bsfs

        --enable-amf
        --enable-dxva2
        --enable-d3d11va

        --disable-vaapi
        --disable-vdpau
        --disable-bzlib
        --disable-libmfx
        --disable-libuavs3d
        --disable-linux-perf
        --disable-videotoolbox
        --disable-audiotoolbox

        --disable-bsf=mjpeg2jpeg
        --disable-bsf=mjpega_dump_header
        --disable-bsf=mov2textsub
        --disable-bsf=text2movsub
        --disable-bsf=eac3_core

        --enable-small
        --enable-hwaccels
        --enable-optimizations
        --enable-runtime-cpudetect

        --enable-openssl
        --enable-libssh

        --enable-libdav1d

        --enable-libjxl

        --enable-libvpl
        --enable-libbs2b
        --enable-libwebp
        --enable-libzimg
        --enable-libxml2
        --enable-libsoxr
        --enable-libspeex
        --enable-libmysofa
        --enable-libfribidi
        --enable-libfreetype

        --enable-avutil
        --enable-avcodec
        --enable-avfilter
        --enable-avformat
        --enable-avdevice
        --enable-swscale
        --enable-swresample

        --enable-decoder=flv
        --enable-decoder=h263
        --enable-decoder=h263i
        --enable-decoder=h263p
        --enable-decoder=h264*
        --enable-decoder=mpeg1video
        --enable-decoder=mpeg2*
        --enable-decoder=mpeg4*
        --enable-decoder=vp6
        --enable-decoder=vp6a
        --enable-decoder=vp6f
        --enable-decoder=vp8*
        --enable-decoder=vp9*
        --enable-decoder=hevc*
        --enable-decoder=av1*
        --enable-decoder=libdav1d
        --enable-decoder=theora
        --enable-decoder=msmpeg*
        --enable-decoder=mjpeg*
        --enable-decoder=wmv*
        --enable-decoder=prores
        --enable-decoder=vc1
        --enable-decoder=rawvideo

        --enable-decoder=aac*
        --enable-decoder=ac3
        --enable-decoder=alac
        --enable-decoder=als
        --enable-decoder=ape
        --enable-decoder=atrac*
        --enable-decoder=eac3
        --enable-decoder=flac
        --enable-decoder=gsm*
        --enable-decoder=mp1*
        --enable-decoder=mp2*
        --enable-decoder=mp3*
        --enable-decoder=mpc*
        --enable-decoder=opus
        --enable-decoder=ra*
        --enable-decoder=ralf
        --enable-decoder=shorten
        --enable-decoder=tak
        --enable-decoder=tta
        --enable-decoder=vorbis
        --enable-decoder=wavpack
        --enable-decoder=wma*
        --enable-decoder=pcm*
        --enable-decoder=dsd*
        --enable-decoder=dca

        --enable-decoder=ssa
        --enable-decoder=ass
        --enable-decoder=dvbsub
        --enable-decoder=dvdsub
        --enable-decoder=srt
        --enable-decoder=stl
        --enable-decoder=subrip
        --enable-decoder=subviewer
        --enable-decoder=subviewer1
        --enable-decoder=text
        --enable-decoder=vplayer
        --enable-decoder=webvtt
        --enable-decoder=movtext

        --enable-decoder=mjpeg
        --enable-decoder=ljpeg
        --enable-decoder=jpegls
        --enable-decoder=jpeg2000
        --enable-decoder=png
        --enable-decoder=gif
        --enable-decoder=bmp
        --enable-decoder=tiff
        --enable-decoder=webp
        --enable-decoder=jpegls

        --enable-demuxer=concat
        --enable-demuxer=data
        --enable-demuxer=flv
        --enable-demuxer=hls
        --enable-demuxer=latm
        --enable-demuxer=live_flv
        --enable-demuxer=loas
        --enable-demuxer=m4v
        --enable-demuxer=mov
        --enable-demuxer=mpegps
        --enable-demuxer=mpegts
        --enable-demuxer=mpegvideo
        --enable-demuxer=hevc
        --enable-demuxer=rtsp
        --enable-demuxer=mpeg4
        --enable-demuxer=mjpeg*
        --enable-demuxer=avi
        --enable-demuxer=av1
        --enable-demuxer=matroska
        --enable-demuxer=dash
        --enable-demuxer=webm_dash_manifest
        --enable-demuxer=yuv4mpegpipe

        --enable-demuxer=aac
        --enable-demuxer=ac3
        --enable-demuxer=aiff
        --enable-demuxer=ape
        --enable-demuxer=asf
        --enable-demuxer=au
        --enable-demuxer=avi
        --enable-demuxer=flac
        --enable-demuxer=flv
        --enable-demuxer=matroska
        --enable-demuxer=mov
        --enable-demuxer=m4v
        --enable-demuxer=mp3
        --enable-demuxer=mpc*
        --enable-demuxer=ogg
        --enable-demuxer=pcm*
        --enable-demuxer=rm
        --enable-demuxer=shorten
        --enable-demuxer=tak
        --enable-demuxer=tta
        --enable-demuxer=wav
        --enable-demuxer=wv
        --enable-demuxer=xwma
        --enable-demuxer=dsf
        --enable-demuxer=truehd
        --enable-demuxer=dts
        --enable-demuxer=dtshd

        --enable-demuxer=ass
        --enable-demuxer=srt
        --enable-demuxer=stl
        --enable-demuxer=webvtt
        --enable-demuxer=subviewer
        --enable-demuxer=subviewer1
        --enable-demuxer=vplayer

        --enable-parser=h263
        --enable-parser=h264
        --enable-parser=hevc
        --enable-parser=mpeg4
        --enable-parser=mpeg4video
        --enable-parser=mpegvideo
        --enable-parser=av1
        --enable-parser=vp9
        --enable-parser=vc1

        --enable-parser=aac*
        --enable-parser=ac3
        --enable-parser=cook
        --enable-parser=flac
        --enable-parser=gsm
        --enable-parser=mpegaudio
        --enable-parser=tak
        --enable-parser=vorbis
        --enable-parser=dca

        --enable-filter=overlay
        --enable-filter=equalizer
        --enable-filter=hstack
        --enable-filter=vstack
        --enable-filter=crop
        --enable-filter=pad
        --enable-filter=null
        --enable-filter=anull
        --enable-filter=format
        --enable-filter=aformat
        --enable-filter=scale
        --enable-filter=aresample
        --enable-filter=hwdownload

        --enable-protocol=async
        --enable-protocol=cache
        --enable-protocol=crypto
        --enable-protocol=data
        --enable-protocol=ffrtmphttp
        --enable-protocol=file
        --enable-protocol=ftp
        --enable-protocol=hls
        --enable-protocol=http
        --enable-protocol=httpproxy
        --enable-protocol=https
        --enable-protocol=pipe
        --enable-protocol=rtmp
        --enable-protocol=rtmps
        --enable-protocol=rtmpt
        --enable-protocol=rtmpts
        --enable-protocol=rtp
        --enable-protocol=subfile
        --enable-protocol=tcp
        --enable-protocol=tls
        --enable-protocol=srt
        --enable-protocol=udp

        --enable-encoder=mjpeg
        --enable-encoder=ljpeg
        --enable-encoder=jpegls
        --enable-encoder=jpeg2000
        --enable-encoder=png
        --enable-encoder=jpegls

        --enable-network

        ${ffmpeg_cuda}
        ${ffmpeg_lto}
        --extra-cflags='-Wno-error=int-conversion'
        "--extra-libs='${ffmpeg_extra_libs}'" # -lstdc++ / -lc++ needs by libjxl and shaderc
        BUILD_COMMAND ${MAKE}
        INSTALL_COMMAND ${MAKE} install
        LOG_DOWNLOAD 1 LOG_UPDATE 1 LOG_CONFIGURE 1 LOG_BUILD 1 LOG_INSTALL 1
)

force_rebuild_git(ffmpeg)
cleanup(ffmpeg install)
