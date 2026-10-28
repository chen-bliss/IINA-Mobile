// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine
import CryptoKit

struct HistoryResource: Codable, Equatable {
    enum Kind: String, Codable { case server, file, network, sample }
    var kind: Kind
    var location: String
    var serverID: UUID?
    var bookmark: Data?
    var credentialID: UUID?
    var resourceKey: String?
    var identity: String { "\(kind.rawValue)|\(serverID?.uuidString ?? "")|\(resourceKey ?? location)" }

    static func capture(_ url: URL, servers: [SMBServer]) throws -> Self {
        if url.isFileURL {
            if let root = Bundle.main.resourceURL, url.path.hasPrefix(root.path + "/") {
                return Self(kind: .sample, location: url.lastPathComponent)
            }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            return Self(kind: .file, location: url.path, bookmark: bookmark)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        if url.scheme?.lowercased() == "smb" {
            let candidates = servers.filter {
                $0.host.lowercased() == components.host?.lowercased() && ($0.port ?? 445) == (components.port ?? 445) &&
                $0.playbackURL(path: components.path, password: "")?.user == url.user
            }
            if let server = candidates.first(where: { KeychainStore.password(for: $0.id) == components.password }) ?? candidates.first {
                return Self(kind: .server, location: components.path, serverID: server.id)
            }
        }
        // Network URLs can also carry access tokens in their query string.
        // Keep the complete resumable URL in Keychain, not in history JSON.
        components.password = nil
        let key = SHA256.hash(data: Data((components.url?.absoluteString ?? url.absoluteString).utf8)).map { String(format: "%02x", $0) }.joined()
        components.user = nil; components.query = nil; components.fragment = nil
        guard let safeURL = components.url else { throw URLError(.badURL) }
        var resource = Self(kind: .network, location: safeURL.absoluteString)
        let id = UUID()
        try KeychainStore.set(url.absoluteString, for: id)
        resource.credentialID = id; resource.resourceKey = key
        return resource
    }
    func resolve(servers: [SMBServer]) throws -> URL {
        switch kind {
        case .sample:
            guard let url = Bundle.main.resourceURL?.appendingPathComponent(location), FileManager.default.fileExists(atPath: url.path) else { throw unavailable }
            return url
        case .file:
            guard let bookmark else { throw unavailable }
            var stale = false
            return try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        case .server:
            guard let server = servers.first(where: { $0.id == serverID }),
                  let url = server.playbackURL(path: location, password: KeychainStore.password(for: server.id)) else { throw unavailable }
            return url
        case .network:
            let text = credentialID.map { KeychainStore.password(for: $0) } ?? location
            guard let url = URL(string: text), url.scheme != nil else { throw unavailable }
            return url
        }
    }
    private var unavailable: NSError { NSError(domain: "History", code: 1, userInfo: [NSLocalizedDescriptionKey: "这个播放来源已不可用，请重新选择文件或添加服务器。"] ) }
    func forgetCredential() { if let credentialID { KeychainStore.remove(credentialID) } }
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var source: HistoryResource
    var subtitles: [HistoryResource] = []
    var position: Double = 0
    var duration: Double = 0
    var lastPlayed = Date()
    var resumePosition: Double {
        guard position.isFinite, position > 0, duration <= 0 || (position < duration - 10 && position / duration < 0.98) else { return 0 }
        return position
    }
}

final class PlaybackHistory: ObservableObject {
    @Published private(set) var entries: [HistoryEntry]
    private let defaults: UserDefaults
    private var lastWrites: [UUID: Date] = [:]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: "history.v1").flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
    }
    func opened(_ item: PlaybackItem, servers: [SMBServer]) -> UUID? {
        guard AppPreferences.load().saveHistory,
              let source = try? HistoryResource.capture(item.url, servers: servers) else { return nil }
        let subtitles = item.subtitles.compactMap { try? HistoryResource.capture($0, servers: servers) }
        var entry: HistoryEntry
        if let index = entries.firstIndex(where: { $0.source.identity == source.identity }) {
            entry = entries.remove(at: index)
            entry.source.forgetCredential(); entry.subtitles.forEach { $0.forgetCredential() }
            entry.source = source; entry.subtitles = subtitles
        } else { entry = HistoryEntry(title: MediaPrivacy.safeTitle(item.url), source: source, subtitles: subtitles) }
        entry.position = max(0, item.startPosition); entry.lastPlayed = Date()
        entries.insert(entry, at: 0)
        while entries.count > 100 {
            let removed = entries.removeLast(); forget(removed)
        }
        persist()
        return entry.id
    }
    func update(_ id: UUID?, position: Double, duration: Double, force: Bool = false) {
        guard let id, position.isFinite, duration.isFinite, duration > 0,
              force || Date().timeIntervalSince(lastWrites[id] ?? .distantPast) >= 5,
              let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].position = min(max(position, 0), duration)
        entries[index].duration = duration
        lastWrites[id] = Date()
        persist()
    }
    func playback(for entry: HistoryEntry, servers: [SMBServer]) throws -> PlaybackItem {
        let url = try entry.source.resolve(servers: servers)
        let subtitles = entry.subtitles.compactMap { try? $0.resolve(servers: servers) }
        return PlaybackItem(url: url, subtitles: subtitles, startPosition: AppPreferences.load().resumePlayback ? entry.resumePosition : 0)
    }
    func remove(_ id: UUID) {
        if let entry = entries.first(where: { $0.id == id }) { forget(entry) }
        entries.removeAll { $0.id == id }; lastWrites[id] = nil; persist()
    }
    func clear() { entries.forEach(forget); entries = []; lastWrites = [:]; persist() }
    private func forget(_ entry: HistoryEntry) { entry.source.forgetCredential(); entry.subtitles.forEach { $0.forgetCredential() } }
    private func persist() { defaults.set(try? JSONEncoder().encode(entries), forKey: "history.v1") }
}
