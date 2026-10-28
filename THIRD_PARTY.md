# Sources and licenses

The application is distributed as GPL-3.0-or-later source. See LICENSE. It is an independent project and does not use IINA's branding assets or claim official affiliation.

## IINA

- Source: https://github.com/iina/iina
- Reference revision: `3c72aa0593d25d67e52e249b99708baf908bca43`
- License: GPL-3.0; included in LICENSE.
- Adapted behavior: `iina/PlayerCore.swift`, `VideoEqualizerType` and `setVideoEqualizer`, which map brightness, contrast, saturation, gamma and hue to mpv properties with range −100...100. The iOS controller is implemented in `App/PlayerEngine.swift`.
- HDR behavior was studied in `iina/VideoView.swift`, especially source PQ/HLG recognition, EDR, target transfer characteristics and tone mapping. The macOS AppKit/CoreDisplay rendering path is not reused on iOS.

## MPVKit

- Source and build scripts: https://github.com/mpvkit/MPVKit/tree/d9194243bdc68b87d8989376ab52aee7da6c8e0b
- Revision: `d9194243bdc68b87d8989376ab52aee7da6c8e0b`
- Binaries: `1.1.0-n9.0.2` GPL variant, with dependency releases and exact SHA-256 hashes recorded in `Vendor/MPVKit-Package.upstream.swift`.
- License: GPLv3 for the selected bundle; wrapper license included in `Vendor/MPVKit-LICENSE` and `Vendor/MPVKit/LICENSE`. Bundled components retain their own licenses.
- Dependencies include mpv, FFmpeg, libass, libplacebo, libdovi, MoltenVK and associated codec, text, TLS and color libraries. Upstream build scripts identify the component versions, source repositories, patches and build settings.
- `Scripts/bootstrap.py` verifies the upstream artifact SHA-256 before extracting only iOS device and simulator slices. It adjusts the XCFramework Info.plist to describe the retained slices; framework binaries are not altered.
- `VideoLayer` and the Metal layer integration in `App/PlayerEngine.swift` follow the upstream iOS demo's `MPVMetalViewController.swift` and `MetalLayer.swift` (including the drawable-size and main-thread EDR workarounds).
- The GPL FFmpeg package links Samba, but application SMB browsing and streaming use the separately supplied libsmb2 code below.

## libsmb2

- Source: https://github.com/sahlberg/libsmb2
- Revision: `727feaaa6d0f4fed1bae57745fbc2c5db9a30e64`
- License: LGPL-2.1-or-later; see `Vendor/libsmb2/COPYING` and the retained source file notices.
- Full library `lib` and `include` source directories are supplied. Examples and standalone command-line tools are not included.
- Local changes: a Swift package manifest, an iOS umbrella header and a module map that expose the core client API without the separately built dcerpc library. Library implementation sources are unchanged.
- Used for authenticated directory listing and read-only, seekable mpv custom streams. The application implements the adapter and its cancellation behavior in `App/SMBBridge.c` and `App/SMBPlaybackStream.swift`.
- Version 0.2 adds an in-memory opaque URL router, explicit error stages, and Windows domain-login normalization. These are application adapter changes; the vendored library sources remain unchanged.

## Noto Sans CJK

- Font: unmodified `NotoSansCJKsc-Regular.otf`, from the Noto CJK project maintained by the Noto Project / Adobe and Google.
- Source: https://github.com/notofonts/noto-cjk/tree/f8d157532fbfaeda587e826d4cd5b21a49186f7c
- Revision: `f8d157532fbfaeda587e826d4cd5b21a49186f7c`; source path `Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf`.
- SHA-256: `2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b`.
- License: SIL Open Font License 1.1, included as `Resources/NotoFonts-OFL.txt`. The font retains its embedded copyright and naming metadata.
- Loaded by libass and registered with CoreText for missing Chinese glyph fallback. No Apple system font is redistributed.

## Original assets and fixtures

The app icon and test media were generated for this project. `Scripts/generate_samples.py` reproduces them with the Python standard library and FFmpeg. The HDR sample uses BT.2020 primaries, SMPTE ST 2084 PQ, 10-bit HEVC, HDR10 mastering metadata and a controlled 0–1000-nit gradient.

No server password is embedded in the source or project. Fixed credentials in the QA scripts are only for a loopback test server serving generated media.

## Release source archives

Pinned source revisions, build scripts and archive SHA-256 values are indexed in `Dependencies/SOURCES.json` and `Dependencies/ADDITIONAL-SOURCES.json`. The matching Release includes a `ThirdPartySources.tar` source archive bundle. Rust dependency sources follow libdovi’s library Cargo.lock.
