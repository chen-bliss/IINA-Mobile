// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreText

enum SubtitleFonts {
    static let directory: URL? = {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("NotoSansCJKsc-Regular.otf").path) else { return nil }
        // Make the bundled face available to CoreText's glyph fallback as well
        // as libass's explicit font directory (ASS can request a different face).
        CTFontManagerRegisterFontsForURL(root.appendingPathComponent("NotoSansCJKsc-Regular.otf") as CFURL, .process, nil)
        return root
    }()
}
