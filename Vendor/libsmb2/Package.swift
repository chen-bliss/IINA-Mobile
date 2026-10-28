// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "IINASMB2", platforms: [.iOS(.v17)],
    products: [.library(name: "IINASMB2", targets: ["IINASMB2"])],
    targets: [.target(name: "IINASMB2", path: ".",
        exclude: ["COPYING", "UPSTREAM_COMMIT", "lib/CMakeLists.txt", "lib/Makefile.am", "lib/Makefile.AMIGA", "lib/Makefile.AMIGA_AROS", "lib/Makefile.AMIGA_OS3", "lib/Makefile.PS3_PPU", "lib/ps2", "lib/dreamcast", "lib/libsmb2.syms"],
        sources: ["lib"], publicHeadersPath: "include",
        cSettings: [.headerSearchPath("include"), .headerSearchPath("include/apple"),
                    .headerSearchPath("include/smb2"), .headerSearchPath("lib"),
                    .define("HAVE_CONFIG_H", to: "1"), .define("_U_", to: "__attribute__((unused))")])])
