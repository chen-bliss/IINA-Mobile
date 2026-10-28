// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

// Unsupported device languages deliberately fall back to English.
enum AppLanguage {
    static let supported = ["en", "zh-Hans", "fr", "es", "ru", "ar"]
    static let preferenceKey = "interfaceLanguage.v1"
    static func resolve(_ preferred: [String]) -> String {
        let first = (preferred.first ?? "en").replacingOccurrences(of: "_", with: "-").lowercased()
        let base = first.split(separator: "-").first.map(String.init) ?? "en"
        return base == "zh" ? "zh-Hans" : supported.contains(base) ? base : "en"
    }
    static func resolveSelection(_ selection: String, preferred: [String]) -> String {
        supported.contains(selection) ? selection : resolve(preferred)
    }
    static var current: String {
        resolveSelection(UserDefaults.standard.string(forKey: preferenceKey) ?? "system", preferred: Locale.preferredLanguages)
    }
    private static let bundles: [String: Bundle] = supported.reduce(into: [:]) { result, code in
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) { result[code] = bundle }
    }
    static var bundle: Bundle { bundles[current] ?? bundles["en"] ?? .main }
}

final class LanguageStore: ObservableObject {
    static let shared = LanguageStore()
    @Published var selection: String {
        didSet { UserDefaults.standard.set(selection, forKey: AppLanguage.preferenceKey) }
    }
    var code: String { AppLanguage.resolveSelection(selection, preferred: Locale.preferredLanguages) }
    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--uitesting") && !arguments.contains("--preserve-language") {
            selection = "system"
            UserDefaults.standard.set(selection, forKey: AppLanguage.preferenceKey)
        } else { selection = UserDefaults.standard.string(forKey: AppLanguage.preferenceKey) ?? "system" }
    }
}

func L(_ key: String) -> String { AppLanguage.bundle.localizedString(forKey: key, value: key, table: nil) }
func LF(_ key: String, _ arguments: Any...) -> String {
    String(format: L(key), locale: Locale(identifier: AppLanguage.current), arguments: arguments.map { String(describing: $0) as NSString })
}
