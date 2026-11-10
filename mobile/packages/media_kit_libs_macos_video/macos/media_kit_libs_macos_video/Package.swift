// swift-tools-version: 5.9
// The macOS libraries of media_kit for Immuch360 Desktop: libmpv and the libraries it needs, one xcframework each,
// from a libmpv-macos-* release of github.com/immuch360/libmpv-builds (those of freeKC/Immuch360 up to desktop build
// 24), built from published sources (see ../../IMMUCH360-NOTE.md and ../../NOTICES.md). Swift Package Manager
// downloads each zip once and checks it by its SHA-256 before the app links it. Same targets and products as
// media-kit's package, so media_kit_video finds Mpv as before; Placebo.framework is new (mpv needs libplacebo since
// 0.37).

import PackageDescription

// The pins: paste the lines the run summary of the release prints ("Lines for the Package.swift of the libs package")
// IMMUCH360_LIBMPV_PINS_BEGIN
let libmpvTag = "libmpv-macos-20261110-1"
let libmpvArtifactBase = "https://github.com/immuch360/libmpv-builds/releases/download/\(libmpvTag)/libmpv-xcframeworks_libmpv-macos-20261110-1_macos-universal-video-default"
let libmpvChecksums: [String: String] = [
    "Ass": "2de30b60fdcce3f85d3370b9bf7805fb9d71e1f96b046d5ed324695e5483aa8b",
    "Avcodec": "01849c94db5cecffeec4681c7a62d3c5942738ea3dd8a81d9a08f5d19125682e",
    "Avfilter": "b925c64aca8f106330885add2a088296bf742f66aaee94db3b4aa8be62e053ce",
    "Avformat": "300fd6dbd93296de000f4ca4a1f2f6250284128c76075d6d1673a652db29e113",
    "Avutil": "9d3262c4bd84cbfb886bf280c63ad85dac288e34683cb2ddb074d9b0bd125359",
    "Dav1d": "90fcc693db4ed885db0bdd5c810124f014656d300769c421c584eed0e5725e7c",
    "Freetype": "6ef37991b69fd18c1abf2d6eb6e6e013cbf7a4b7ec142b9612e9e1fe63964ee7",
    "Fribidi": "8d4f2399029dcaeb08e3c0c2986c018fa4d60b6801e5dbfc19e1f5bf5f5303f8",
    "Harfbuzz": "c8d56f7a74c18fd61ac67d86f30ff323eb66757590961d01c74ac92eee2ab305",
    "Mbedcrypto": "eb728befa9bad2cfc8bb0eee873f9efd88663346a6cb519af10dc6f957e93e7d",
    "Mbedtls": "ed2dce2ff47b778d5fd46d21f2806cc7b7e1f681980ab24ff0d2c0bac217eed5",
    "Mbedx509": "e07fb7c5add93744db057c67b10762d1b41d97f8b6160db45a3f2f4688604d7c",
    "Mpv": "27819f9b3f4b26f524484b409b5d99123de0f6d5a7d32eb18ac9a9c2ec70ca1e",
    "Placebo": "d1fe457f99fa0437224e6c68f9252d6dec7df53c709dcb03a4bd6d0b929a115a",
    "Png16": "0925e53ffa55f63abbe96bbff160a225cd39698d695d5ce11c6e8a239b0b5b0e",
    "Swresample": "4197263e41cd35f8ac60e70ef2343f1e030302eda112aae2d0eb71a8b660d703",
    "Swscale": "4e6d9e1b94e6e2e5ecfc2a5d4c0175428dc8b12227078c34a5e9ad1d9dd372e9",
    "Uchardet": "7813a5a655c6011718b51becef18142883b3faf3d04ed28a4c59b76343909b7f",
    "Xml2": "ee43f72e135fb7f106d5099fe3b805fcf9522685387d5da252bca7acc625781e",
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
