// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum ColorControl: String, CaseIterable, Codable, Identifiable {
    case brightness, contrast, saturation, gamma, hue
    var id: String { rawValue }
    var title: String {
        switch self {
        case .brightness: return L("亮度")
        case .contrast: return L("对比度")
        case .saturation: return L("饱和度")
        case .gamma: return L("伽马")
        case .hue: return L("色相")
        }
    }
}

struct PictureSettings: Codable, Equatable {
    var values: [String: Double] = [:]
    var hdrMode: HDRMode = .automatic
    var toneMapping = "auto"
    subscript(_ control: ColorControl) -> Double {
        get { min(100, max(-100, values[control.rawValue] ?? 0)) }
        set { values[control.rawValue] = newValue.isFinite ? min(100, max(-100, newValue)) : 0 }
    }
    mutating func resetColors() { values = [:] }
    static let storageKey = "picture.v1"
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return decoded
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.storageKey) }
}

enum HDRMode: String, Codable, CaseIterable, Identifiable {
    case automatic, sdr
    var id: String { rawValue }
    var title: String { self == .automatic ? L("自动 HDR") : L("映射到 SDR") }
}

enum RenderingMode: String, Codable, CaseIterable, Identifiable {
    case quality, smooth, energy
    var id: String { rawValue }
    var title: String {
        switch self { case .quality: return L("画质优先"); case .smooth: return L("流畅优先"); case .energy: return L("省电优先") }
    }
    static func load() -> Self { Self(rawValue: UserDefaults.standard.string(forKey: "rendering.v1") ?? "") ?? .quality }
    func save() { UserDefaults.standard.set(rawValue, forKey: "rendering.v1") }
}

enum VideoFitMode: String, Codable, CaseIterable, Identifiable {
    case fit, fill, stretch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fit: return L("适应屏幕")
        case .fill: return L("填满屏幕（裁切）")
        case .stretch: return L("拉伸铺满")
        }
    }
}

enum VideoAspect: String, Codable, CaseIterable, Identifiable {
    case original, wide, classic, cinema
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return L("原始比例")
        case .wide: return "16:9"
        case .classic: return "4:3"
        case .cinema: return "2.35:1"
        }
    }
    var mpvValue: String {
        switch self {
        case .original: return "-1"
        case .wide: return "16:9"
        case .classic: return "4:3"
        case .cinema: return "2.35:1"
        }
    }
}

struct VideoDisplaySettings: Codable, Equatable {
    var fit: VideoFitMode = .fit
    var aspect: VideoAspect = .original
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "display.v1"),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return saved
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "display.v1") }
}

struct SMBLogin: Equatable {
    let domain: String
    let username: String
    init(username: String, domain: String) {
        if domain.isEmpty, let separator = username.firstIndex(of: "\\") {
            self.domain = String(username[..<separator])
            self.username = String(username[username.index(after: separator)...])
        } else { self.domain = domain; self.username = username }
    }
}

struct MediaTrack: Identifiable, Equatable {
    let id: Int
    let type: String
    let title: String
    let language: String
    let codec: String
    var external: Bool = false
    var label: String {
        let parts = [title, language, codec].filter { !$0.isEmpty }
        return parts.isEmpty ? LF("轨道 %@", id) : parts.joined(separator: " · ")
    }
    static func decode(_ json: String) -> [Self] {
        guard let data = json.data(using: .utf8),
              let objects = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return objects.compactMap {
            guard let id = $0["id"] as? Int, let type = $0["type"] as? String else { return nil }
            return Self(id: id, type: type, title: $0["title"] as? String ?? "",
                        language: $0["lang"] as? String ?? "", codec: $0["codec"] as? String ?? "", external: $0["external"] as? Bool ?? false)
        }
    }
}

struct SMBServer: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var share: String
    var username: String
    var domain: String = ""
    var port: Int? = nil
    var rootURL: URL? {
        var c = URLComponents()
        c.scheme = "smb"
        c.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        c.port = port
        c.path = "/" + share.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return c.url
    }
    func playbackURL(path: String, password: String) -> URL? {
        guard let root = rootURL, var c = URLComponents(url: root, resolvingAgainstBaseURL: false) else { return nil }
        if !username.isEmpty {
            c.user = domain.isEmpty ? username : "\(domain);\(username)"
            c.password = password
        }
        c.path = path
        return c.url
    }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !host.isEmpty &&
        !host.contains("/") && !host.contains("@") && !host.contains(":") &&
        (port == nil || (1...65535).contains(port!)) && rootURL?.host != nil
    }
}

struct SMBEntry: Identifiable {
    let name: String
    let path: String
    let isDirectory: Bool
    var id: String { path }
    var isSubtitle: Bool { ["srt", "ass", "ssa", "vtt", "sub", "sup"].contains((name as NSString).pathExtension.lowercased()) }
    var isVideo: Bool { ["mkv", "mp4", "mov", "m4v", "avi", "webm", "ts", "m2ts", "wmv", "flv", "mpg", "mpeg", "rmvb", "ogv"].contains((name as NSString).pathExtension.lowercased()) }
}

enum MediaPrivacy {
    static func safeTitle(_ url: URL) -> String {
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return last.isEmpty ? L("网络视频") : last
    }
}
