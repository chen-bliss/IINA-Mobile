// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

final class LibraryModel: ObservableObject {
    @Published private(set) var servers: [SMBServer]
    init() {
        if let data = UserDefaults.standard.data(forKey: "servers.v1"),
           let saved = try? JSONDecoder().decode([SMBServer].self, from: data) { servers = saved }
        else { servers = [] }
    }
    func save(_ server: SMBServer, password: String) throws {
        try KeychainStore.set(password, for: server.id)
        if let i = servers.firstIndex(where: { $0.id == server.id }) { servers[i] = server }
        else { servers.append(server) }
        persist()
    }
    func remove(_ id: UUID) {
        servers.removeAll { $0.id == id }
        KeychainStore.remove(id)
        persist()
    }
    private func persist() { UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: "servers.v1") }
}

struct PlaybackItem: Identifiable {
    let id = UUID()
    let url: URL
    var subtitles: [URL] = []
    var startPosition: Double = 0
    var settings: VideoPlaybackSettings?
}
