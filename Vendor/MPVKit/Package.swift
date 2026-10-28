// swift-tools-version:5.9
// MPVKit GPL dependencies pinned at d9194243bdc68b87d8989376ab52aee7da6c8e0b.
// Only Apple iOS slices retained; all binaries verified against upstream SHA-256.
import PackageDescription
let package = Package(name: "MPVKit", platforms: [.iOS(.v17)],
    products: [.library(name: "MPVKit-GPL", targets: ["_MPVKit-GPL"])],
    targets: [
        .target(
            name: "_MPVKit-GPL",
            dependencies: [
                "Libmpv-GPL", "_FFmpeg-GPL", "Libuchardet", "Libbluray",
                
            ],
            path: "Sources/_MPVKit-GPL",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .target(
            name: "_FFmpeg-GPL",
            dependencies: [
                "Libavcodec-GPL", "Libavdevice-GPL", "Libavfilter-GPL", "Libavformat-GPL", "Libavutil-GPL", "Libswresample-GPL", "Libswscale-GPL",
                "Libssl", "Libcrypto", "Libass", "Libfreetype", "Libfribidi", "Libharfbuzz",
                "MoltenVK", "Libshaderc_combined", "lcms2", "Libplacebo", "Libdovi", "Libunibreak",
                "Libsmbclient", "gmp", "nettle", "hogweed", "gnutls", "Libdav1d", "Libuavs3d"
            ],
            path: "Sources/_FFmpeg-GPL",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Metal"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("expat"),
                .linkedLibrary("resolv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),

        .binaryTarget(name: "Libmpv-GPL", path: "Artifacts/Libmpv-GPL/Libmpv.xcframework"),
        .binaryTarget(name: "Libavcodec-GPL", path: "Artifacts/Libavcodec-GPL/Libavcodec.xcframework"),
        .binaryTarget(name: "Libavdevice-GPL", path: "Artifacts/Libavdevice-GPL/Libavdevice.xcframework"),
        .binaryTarget(name: "Libavformat-GPL", path: "Artifacts/Libavformat-GPL/Libavformat.xcframework"),
        .binaryTarget(name: "Libavfilter-GPL", path: "Artifacts/Libavfilter-GPL/Libavfilter.xcframework"),
        .binaryTarget(name: "Libavutil-GPL", path: "Artifacts/Libavutil-GPL/Libavutil.xcframework"),
        .binaryTarget(name: "Libswresample-GPL", path: "Artifacts/Libswresample-GPL/Libswresample.xcframework"),
        .binaryTarget(name: "Libswscale-GPL", path: "Artifacts/Libswscale-GPL/Libswscale.xcframework"),
        .binaryTarget(name: "Libcrypto", path: "Artifacts/Libcrypto/Libcrypto.xcframework"),
        .binaryTarget(name: "Libssl", path: "Artifacts/Libssl/Libssl.xcframework"),
        .binaryTarget(name: "gmp", path: "Artifacts/gmp/gmp.xcframework"),
        .binaryTarget(name: "nettle", path: "Artifacts/nettle/nettle.xcframework"),
        .binaryTarget(name: "hogweed", path: "Artifacts/hogweed/hogweed.xcframework"),
        .binaryTarget(name: "gnutls", path: "Artifacts/gnutls/gnutls.xcframework"),
        .binaryTarget(name: "Libunibreak", path: "Artifacts/Libunibreak/Libunibreak.xcframework"),
        .binaryTarget(name: "Libfreetype", path: "Artifacts/Libfreetype/Libfreetype.xcframework"),
        .binaryTarget(name: "Libfribidi", path: "Artifacts/Libfribidi/Libfribidi.xcframework"),
        .binaryTarget(name: "Libharfbuzz", path: "Artifacts/Libharfbuzz/Libharfbuzz.xcframework"),
        .binaryTarget(name: "Libass", path: "Artifacts/Libass/Libass.xcframework"),
        .binaryTarget(name: "Libsmbclient", path: "Artifacts/Libsmbclient/Libsmbclient.xcframework"),
        .binaryTarget(name: "Libbluray", path: "Artifacts/Libbluray/Libbluray.xcframework"),
        .binaryTarget(name: "Libuavs3d", path: "Artifacts/Libuavs3d/Libuavs3d.xcframework"),
        .binaryTarget(name: "Libdovi", path: "Artifacts/Libdovi/Libdovi.xcframework"),
        .binaryTarget(name: "MoltenVK", path: "Artifacts/MoltenVK/MoltenVK.xcframework"),
        .binaryTarget(name: "Libshaderc_combined", path: "Artifacts/Libshaderc_combined/Libshaderc_combined.xcframework"),
        .binaryTarget(name: "lcms2", path: "Artifacts/lcms2/lcms2.xcframework"),
        .binaryTarget(name: "Libplacebo", path: "Artifacts/Libplacebo/Libplacebo.xcframework"),
        .binaryTarget(name: "Libdav1d", path: "Artifacts/Libdav1d/Libdav1d.xcframework"),
        .binaryTarget(name: "Libuchardet", path: "Artifacts/Libuchardet/Libuchardet.xcframework")
    ])
