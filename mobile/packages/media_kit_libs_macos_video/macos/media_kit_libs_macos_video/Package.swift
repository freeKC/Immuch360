// swift-tools-version: 5.9
// The macOS libraries of media_kit for Immuch360 Desktop: libmpv and the libraries it needs, one xcframework each,
// from a libmpv-macos-* release of freeKC/Immuch360, built from published sources by
// .github/workflows/immuch360-libmpv.yml (see ../../IMMUCH360-NOTE.md and ../../NOTICES.md). Swift Package Manager
// downloads each zip once and checks it by its SHA-256 before the app links it. Same targets and products as
// media-kit's package, so media_kit_video finds Mpv as before; Placebo.framework is new (mpv needs libplacebo since
// 0.37).

import PackageDescription

// The pins: paste the lines the run summary of the release prints ("Lines for the Package.swift of the libs package")
// IMMUCH360_LIBMPV_PINS_BEGIN
let libmpvTag = "libmpv-macos-20261020-9"
let libmpvArtifactBase = "https://github.com/freeKC/Immuch360/releases/download/\(libmpvTag)/libmpv-xcframeworks_libmpv-macos-20261020-9_macos-universal-video-default"
let libmpvChecksums: [String: String] = [
    "Ass": "d306fc98a4d323b5807ab212ef3d9a2b39eefd4ac7b9e3f760abccaf2de41c92",
    "Avcodec": "8685d0084e450fbd9563e92cce90447b46c5742e8e8e6f42f29c4867a92c0945",
    "Avfilter": "3e8210626bf77be9d65a790fdea7c153f999c807dacd0f33c05fc480a4bff2bc",
    "Avformat": "93e5e9dfa90acb42df4cacbfafb589bdbdbde90ec4cc31324a99f933f369f205",
    "Avutil": "4229396457916ff31ab4b4642d91cf5d6c02a868cf40c5aa0698459376403323",
    "Dav1d": "f991d90b3b4576cf890df2ae4e55ff0de908ab4d2572ee045e4cca5a256276a2",
    "Freetype": "98ebe7f029b41d18cd210351e3960747d17133c184f56979ee5caa89acf8323f",
    "Fribidi": "e0e28b97b628b3e63a25d762667942715acce6b20971159a15205e130f3cfa4e",
    "Harfbuzz": "e40ca957447105aa50ff1b2c4d7d5c179bfcaa6d19f5d5ee5bee70dad10e4bd7",
    "Mbedcrypto": "1e00a9127dd1ea22372e6a3cbedafc16e1514f60625552bab0a886df3fb8db07",
    "Mbedtls": "afb920db2f60aaf3c1bd3f99a37e7434ce3beac352a6e0f2d5a6b3581f19d8b6",
    "Mbedx509": "b9f44fb7c0ade3fda1b6aaef1f365ce72fa5835e04452a6a21f92d18b7366f8a",
    "Mpv": "5763c85cfca8bb3ea5c6811373b080d2d75642b92c8089b3e95d3aad3de70cb6",
    "Placebo": "e8b215df07afeca9dcd85bdb64ac650350ee6ae6d3e0bcdc655d7e519f78c839",
    "Png16": "35d62ef8ede2aa00bdf8e131a45e3a8a3b41b90494a0895a5d8014a11b18b6b9",
    "Swresample": "daf058501d55cd3ac19eb39f8c9cc2e912b5afd98da3996464c78f2b6d58b0da",
    "Swscale": "8b9ae94e4358a2ddee16b8a4f64a914db613917043b94160295dde992609c28e",
    "Uchardet": "6e4127deddcddbd7c9880d7e9d12859359661275f88a31dc82ae25d3f37b0d58",
    "Xml2": "8094f0e31dec87f57e9902767faaf8e27eb9269655ecdce58fbd55eaad3850de",
]
// IMMUCH360_LIBMPV_PINS_END

let libmpvTargets = libmpvChecksums.keys.sorted()
let libmpvProductTargets: [String] = ["media_kit_libs_macos_video"] + libmpvTargets

let package = Package(
    name: "media_kit_libs_macos_video",
    platforms: [
        // As media_kit_video, which depends on this package; the frameworks themselves need macOS 12, the oldest
        // system of the app (MACOSX_DEPLOYMENT_TARGET of mobile/macos)
        .macOS("10.9")
    ],
    products: [
        .library(name: "media-kit-libs-macos-video", targets: libmpvProductTargets),
        .library(name: "Mpv", targets: ["Mpv"]),
    ],
    dependencies: [],
    targets: libmpvTargets.map { framework in
        .binaryTarget(
            name: framework,
            url: "\(libmpvArtifactBase)_\(framework).zip",
            checksum: libmpvChecksums[framework]!
        )
    } + [
        .target(
            name: "media_kit_libs_macos_video",
            dependencies: libmpvTargets.map { framework in .target(name: framework) },
            resources: [
                .process("PrivacyInfo.xcprivacy"),
                // The notices and licence texts of the libraries, in the resource bundle of this package inside the
                // app (Contents/Resources/media_kit_libs_macos_video_media_kit_libs_macos_video.bundle)
                .copy("licenses"),
            ]
        )
    ]
)
