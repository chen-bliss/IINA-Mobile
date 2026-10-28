// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine
import CoreGraphics

enum SubtitlePreference: String, Codable, CaseIterable, Identifiable {
    case automatic, simplified, traditional, off
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: return "自动选择"; case .simplified: return "优先简体中文"; case .traditional: return "优先繁体中文"; case .off: return "默认关闭" }
    }
    var languages: String {
        switch self {
        case .traditional: return "zh-Hant,zh-TW,zh-HK,cht,zh,chi,zho,en"
        case .simplified: return "zh-Hans,zh-CN,chs,zh,chi,zho,en"
        default: return "zh-Hans,zh,chi,zho,en"
        }
    }
}

struct AppPreferences: Codable, Equatable {
    var picture = PictureSettings()
    var display = VideoDisplaySettings()
    var rendering: RenderingMode = .smooth
    var subtitles: SubtitlePreference = .automatic
    var subtitleSize: Double = 40
    var saveHistory = true
    var resumePlayback = true
    var autoHideControls = true
    var adaptToHeat = true
    static let storageKey = "defaults.v1"

    static func load(from defaults: UserDefaults = .standard) -> Self {
        if let data = defaults.data(forKey: storageKey), let saved = try? JSONDecoder().decode(Self.self, from: data) { return saved }
        var migrated = Self()
        // Existing users retain their pre-settings-page choices on migration.
        if defaults === UserDefaults.standard {
            migrated.picture = PictureSettings.load()
            migrated.display = VideoDisplaySettings.load()
            if defaults.string(forKey: "rendering.v1") != nil { migrated.rendering = RenderingMode.load() }
        }
        migrated.save(to: defaults)
        return migrated
    }
    func save(to defaults: UserDefaults = .standard) { defaults.set(try? JSONEncoder().encode(self), forKey: Self.storageKey) }
}

final class PreferencesStore: ObservableObject {
    @Published var value: AppPreferences { didSet { value.save() } }
    init() { value = .load() }
}

enum RenderResolution {
    static func scale(size: CGSize, nativeScale: CGFloat, constrained: Bool) -> CGFloat {
        guard constrained, max(size.width, size.height) > 0 else { return nativeScale }
        return min(nativeScale, 1920 / max(size.width, size.height))
    }
}
