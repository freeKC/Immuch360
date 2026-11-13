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
let libmpvTag = "libmpv-macos-20261113-2"
let libmpvArtifactBase = "https://github.com/immuch360/libmpv-builds/releases/download/\(libmpvTag)/libmpv-xcframeworks_libmpv-macos-20261113-2_macos-universal-video-default"
let libmpvChecksums: [String: String] = [
    "Ass": "4bf6090f76ed9d53d0f5238b2af400fb96d555a4f807d6464bbfdf29cbe5ece5",
    "Avcodec": "4e09acc3e7c46e3e84e1e015a3555b9ee31f6545efbce6a74ccf16caf33d8864",
    "Avfilter": "4e9737b4cafc1ab040905277d088e4aa29a061d66321abfc3f04e28384606199",
    "Avformat": "54631dca38edea0cc960b6959b808387ee6e9696ed7b8d5f8a45fb7e7bc2c857",
    "Avutil": "92af6b0464fa2b3f445fd29be58eef49cf87eccfb89a0260fad8587a2cac0c03",
    "Dav1d": "91c1d808d336d8869ee0ea1174b4c26c220c9f36afd837cb701cbf6607e961fd",
    "Freetype": "e985c9616666ea6e1150efeb53d5595728daa92a55b6ba7d7c23ffae26de5638",
    "Fribidi": "6608eaefb6cd1667b3ecd808a19e864553758900f972e393410df825c2b7f331",
    "Harfbuzz": "f390cda6c2c571badc62f5921445b7064f2e9c85dc35a12dc9cb02605995ddf4",
    "Mbedcrypto": "4585193ebc47451fad88d12bb171d63636a4b188157dfee4f8253f803ef15507",
    "Mbedtls": "c909aae2a28b1e8e8014c89e524e36c9ac54a99dbb72105e83988dfcf15a2a6c",
    "Mbedx509": "e173cad2752d1eabef823698bddd136e90d8a93ffb3d60b559bd89777864d2ce",
    "Mpv": "43c539914ebe451b6cd5b4eeee5096a4ac62581338f84d9802f77bbe016b6e80",
    "Placebo": "55844d8ac09d2023fb859a4c54417d973a3a7958452e8cf9aa531e85af87308e",
    "Png16": "a491d7bb123390971d5c4fd073474aa166dcdc166b50ccd0977e65626f5d2fd1",
    "Swresample": "ecf70ff3d67bfb6db66c1d8ee66bae93111fae0cea02eecdf475b6358f124811",
    "Swscale": "95d209930e7e938cf69dff3c7c4d3226edf0d33f19da34a4e605f57646a7efd1",
    "Uchardet": "ace833f36772dc4968f67200971d46e0ca9d62a85391f61dc9e06ea08e719e71",
    "Xml2": "e414fbd83feb833d0f67ff27d773d8f5b5786fe770f3144e6dbc4ee171355e1d",
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
