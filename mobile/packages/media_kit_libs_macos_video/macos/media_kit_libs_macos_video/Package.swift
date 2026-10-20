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
let libmpvTag = "libmpv-macos-20261020-8"
let libmpvArtifactBase = "https://github.com/freeKC/Immuch360/releases/download/\(libmpvTag)/libmpv-xcframeworks_libmpv-macos-20261020-8_macos-universal-video-default"
let libmpvChecksums: [String: String] = [
    "Ass": "dae6b97b137aca4c6564ed75998f67aad4a704ecf1252faa684509f1a2e7a75d",
    "Avcodec": "ef3d62996519becc9e2ac885a62f9e102232d16561a91f936ea346993cbd4c93",
    "Avfilter": "665c21566007abc6a86aba64df28397e8165c39ea93a77ded2a654c8b0026561",
    "Avformat": "ae10cf0f68fc017705b31b8fbeaea5096a314b0f8a49a9761bce328f6a20f45e",
    "Avutil": "5a0eb4f34985c859962e5ab24e253b0a0f8b136de6b39201367c9142056a137f",
    "Dav1d": "2b237aa6fe0e81beae9e4cdf1c636904281cfb5b06be33f9d4bd6a499e2850c5",
    "Freetype": "ebb122f12cb19dd0f8130b78a3510844cc966530ed4f2d5be5e21452dadd4873",
    "Fribidi": "65561f2f1bc1ec9d64c1ec502f20603e8af1c5f86e62d8c29bd16f66b1030702",
    "Harfbuzz": "e88836932827f8b3623702b53c286fb1c152ecd83eaca04b958535a15063feb5",
    "Mbedcrypto": "caf89e47c025a2ec798e61d2f979b4291ac2bc51ac37406bc9eac1642743436f",
    "Mbedtls": "2d9cedf21aee4448f0f75ef245846559bf86a53557a35e46a1ddf7c2f9b58501",
    "Mbedx509": "c1a02569064d5556c722989896064c1e86110625c3c9ed4f53a00aa22526f9c6",
    "Mpv": "647b9ba367450be11ae95dee6f2d116f3eb763bfca9f77c6780172d4bf4ebcb2",
    "Placebo": "c622cfa1f4d8ce11083002594f35093f3a2bdefeb19b9e1830edad3f517e0b3f",
    "Png16": "c12b1c1fb0a1887f033225389cfe75363c7ee9d5685e958e2d118dc341c61310",
    "Swresample": "7b90faad63ac1dad21654664f650465847c310a0f04739880d88f74477849a97",
    "Swscale": "184e0084ab8f81b5f049417d558b2c163cc325704f8a3d3625f0b8e8f0d79271",
    "Uchardet": "ab1b3fdebfb12f229e5fde394e1a76c0b10e7e30678d05c4a6b754db343144da",
    "Xml2": "ded4275e1fb79bb17815bd42fe270577f9d6fb8ed11da5d1c395a68189b4c282",
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
