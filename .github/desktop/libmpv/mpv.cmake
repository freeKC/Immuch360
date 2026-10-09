# mpv (libmpv-2.dll) for Immuch360 Desktop on Windows, built by .github/workflows/immuch360-libmpv.yml.
#
# Copied over packages/mpv.cmake of the build recipe before it is configured. Same as the one of
# Predidit/libmpv-win32-video-cmake at fdf75129 (media_kit's video configuration, -Dgpl=false so that mpv is
# LGPL-2.1-or-later), with these differences:
#   - the mpv commit or tag comes from the workflow (IMMUCH360_MPV_REF);
#   - none of the fork's mpv patches: one turns TLS certificate verification off by default, one adds a D3D11 render
#     API media_kit_video does not use;
#   - no libarchive: mpv would open videos inside zip, rar and 7z archives, which the app never asks for, and archive
#     parsers are code that reads files the app does not control.
if(NOT IMMUCH360_MPV_REF)
    message(FATAL_ERROR "IMMUCH360_MPV_REF is not set: the workflow passes the mpv commit with -DIMMUCH360_MPV_REF=")
endif()

ExternalProject_Add(mpv
    DEPENDS
        angle-headers
        ffmpeg
        fribidi
        lcms2
        libass
        libjpeg
        libpng
        uchardet
        shaderc
        spirv-cross
        vulkan
        shaderc
        libplacebo
        spirv-cross
    GIT_REPOSITORY https://github.com/mpv-player/mpv.git
    GIT_TAG ${IMMUCH360_MPV_REF}
    SOURCE_DIR ${SOURCE_LOCATION}
    UPDATE_COMMAND ""
    CONFIGURE_COMMAND ${EXEC} CONF=1 meson setup <BINARY_DIR> <SOURCE_DIR>
        --prefix=${MINGW_INSTALL_PREFIX}
        --libdir=${MINGW_INSTALL_PREFIX}/lib
        --cross-file=${MESON_CROSS}
        --default-library=shared
        --prefer-static
        -Dgpl=false
        -Ddebug=false
        -Db_ndebug=false
        -Doptimization=3
        -Db_lto=true
        ${mpv_lto_mode}
        -Dlibmpv=true
        -Dpdf-build=enabled
        -Dlua=disabled
        -Djavascript=disabled
        -Duchardet=enabled
        -Dlcms2=enabled
        -Dopenal=disabled
        -Dspirv-cross=enabled
        -Dvulkan=disabled
        -Dvapoursynth=disabled
        -Dlibarchive=disabled
        ${mpv_gl}
        -Dc_args='-Wno-error=int-conversion'
    BUILD_COMMAND ${EXEC} LTO_JOB=1 PDB=1 ninja -C <BINARY_DIR>
    INSTALL_COMMAND ""
    LOG_DOWNLOAD 1 LOG_UPDATE 1 LOG_CONFIGURE 1 LOG_BUILD 1 LOG_INSTALL 1
)

ExternalProject_Add_Step(mpv strip-binary
    DEPENDEES build
    ${mpv_add_debuglink}
    COMMENT "Stripping mpv binaries"
)

ExternalProject_Add_Step(mpv copy-binary
    DEPENDEES strip-binary
    COMMAND ${CMAKE_COMMAND} -E copy <BINARY_DIR>/mpv.exe                           ${CMAKE_CURRENT_BINARY_DIR}/mpv-package/mpv.exe
    COMMAND ${CMAKE_COMMAND} -E copy <BINARY_DIR>/mpv.com                           ${CMAKE_CURRENT_BINARY_DIR}/mpv-package/mpv.com
    COMMAND ${CMAKE_COMMAND} -E copy <BINARY_DIR>/mpv.pdf                           ${CMAKE_CURRENT_BINARY_DIR}/mpv-package/doc/manual.pdf
    COMMAND ${CMAKE_COMMAND} -E copy ${MINGW_INSTALL_PREFIX}/etc/fonts/fonts.conf   ${CMAKE_CURRENT_BINARY_DIR}/mpv-package/mpv/fonts.conf
    ${mpv_copy_debug}
    COMMAND ${CMAKE_COMMAND} -E copy <BINARY_DIR>/libmpv-2.dll          ${CMAKE_CURRENT_BINARY_DIR}/mpv-dev/libmpv-2.dll
    COMMAND ${CMAKE_COMMAND} -E copy <BINARY_DIR>/libmpv.dll.a          ${CMAKE_CURRENT_BINARY_DIR}/mpv-dev/libmpv.dll.a
    COMMAND ${CMAKE_COMMAND} -E copy <SOURCE_DIR>/include/mpv/client.h       ${CMAKE_CURRENT_BINARY_DIR}/mpv-dev/include/mpv/client.h
    COMMAND ${CMAKE_COMMAND} -E copy <SOURCE_DIR>/include/mpv/stream_cb.h    ${CMAKE_CURRENT_BINARY_DIR}/mpv-dev/include/mpv/stream_cb.h
    COMMAND ${CMAKE_COMMAND} -E copy <SOURCE_DIR>/include/mpv/render.h       ${CMAKE_CURRENT_BINARY_DIR}/mpv-dev/include/mpv/render.h
    COMMAND ${CMAKE_COMMAND} -E copy <SOURCE_DIR>/include/mpv/render_gl.h    ${CMAKE_CURRENT_BINARY_DIR}/mpv-dev/include/mpv/render_gl.h
    COMMENT "Copying mpv binaries and manual"
)

set(RENAME ${CMAKE_CURRENT_BINARY_DIR}/mpv-prefix/src/rename.sh)
file(WRITE ${RENAME}
"#!/bin/bash
cd $1
GIT=$(git rev-parse --short=7 HEAD)
mv $2 $2-git-\${GIT}")

ExternalProject_Add_Step(mpv copy-package-dir
    DEPENDEES copy-binary
    COMMAND chmod 755 ${RENAME}
    COMMAND mv ${CMAKE_CURRENT_BINARY_DIR}/mpv-package ${CMAKE_BINARY_DIR}/mpv-${TARGET_CPU}${x86_64_LEVEL}-${BUILDDATE}
    COMMAND ${RENAME} <SOURCE_DIR> ${CMAKE_BINARY_DIR}/mpv-${TARGET_CPU}${x86_64_LEVEL}-${BUILDDATE}

    COMMAND mv ${CMAKE_CURRENT_BINARY_DIR}/mpv-debug ${CMAKE_BINARY_DIR}/mpv-debug-${TARGET_CPU}${x86_64_LEVEL}-${BUILDDATE}
    COMMAND ${RENAME} <SOURCE_DIR> ${CMAKE_BINARY_DIR}/mpv-debug-${TARGET_CPU}${x86_64_LEVEL}-${BUILDDATE}

    COMMAND mv ${CMAKE_CURRENT_BINARY_DIR}/mpv-dev ${CMAKE_BINARY_DIR}/mpv-dev-${TARGET_CPU}${x86_64_LEVEL}-${BUILDDATE}
    COMMAND ${RENAME} <SOURCE_DIR> ${CMAKE_BINARY_DIR}/mpv-dev-${TARGET_CPU}${x86_64_LEVEL}-${BUILDDATE}
    COMMENT "Moving mpv package folder"
    LOG 1
)

force_rebuild_git(mpv)
force_meson_configure(mpv)
cleanup(mpv copy-package-dir)
