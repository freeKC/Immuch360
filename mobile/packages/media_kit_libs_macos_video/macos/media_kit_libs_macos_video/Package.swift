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
let libmpvTag = "libmpv-macos-20261102-12"
let libmpvArtifactBase = "https://github.com/freeKC/Immuch360/releases/download/\(libmpvTag)/libmpv-xcframeworks_libmpv-macos-20261102-12_macos-universal-video-default"
let libmpvChecksums: [String: String] = [
    "Ass": "4a6d013abcc21ee401216a1a1c4536dbb1b966d187976f72b3905c55964c8eb4",
    "Avcodec": "f47b663a9db1d377335f98d3188bfaf0ea6dc045f4346614c00be5701fdab800",
    "Avfilter": "791c40006fff342a8addb3d94e9da87e06122f9f89d1ff97af28ea919ce46c0a",
    "Avformat": "a6075f4e1782fdfdc64da27edacc58d9b1ef64942384c2b70ceb834dc4d153d6",
    "Avutil": "a0e195f4936ae111737d3e015f1e7b96368b1c973879f19d7eea777521ecb928",
    "Dav1d": "a9fd60789aab9994a72fe83a9a4d762c8fbb2eb88c7069b158ec3cde97cec0df",
    "Freetype": "68ea706de116c81db517195bdc948931c9cf0a38e4c63ad4d4743932304a7841",
    "Fribidi": "0f00c60c3ecb2af9ae1051d0aef7486a953b073c9f69f00953992ee724e4bce6",
    "Harfbuzz": "aea80b9defacd1eb535d66f5c9298b529064030853d59bdfe6bf2be8cc2e77a4",
    "Mbedcrypto": "7660205825ea4304a6346793c27fbbba85de5844cc08cbfd478c74fa2567e6eb",
    "Mbedtls": "365092f0004c79f17fe7730dd494d7ce3c5b54f963e22f12784444df896bb7e1",
    "Mbedx509": "ddc4c9876953c079b4925155c9d22371b1593f50bdc200b1696ca632e2eef3f3",
    "Mpv": "a1c0e0bbc62dffbf84f174364047b814bc0cfc4829823e2e7a81fb4ab96d83b8",
    "Placebo": "528238e77774cb78a8512144aacb072a4d10ed1d192f6ba56c2984fa1524fa90",
    "Png16": "9d573ed3c720b93d7ee59302a56d1a69aeab86ed9de1f4f6805180b70a1c9d25",
    "Swresample": "282e0d3fcef8f5ab1d6c5b9846cfc791073f07011e5f588b52187e901d4141d1",
    "Swscale": "2a262c546aa3f516455bdf7e8d2823259a980f279d55936ae0b3d5a288ecb1b9",
    "Uchardet": "e13ac7688fe5565611c1bc2003d2f63e5255dcc237eedbbf33254b45a87ff568",
    "Xml2": "37cafd50d292c8acca3557c2484de29cbee7d6a6aca681fa99ec9fd8a1059fcf",
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
