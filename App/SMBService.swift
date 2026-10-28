// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

private final class EntryCollector {
    var entries: [(String, Bool)] = []
}

final class SMBService {
    static let shared = SMBService()
    private let queue = DispatchQueue(label: "org.iinamobile.smb", qos: .userInitiated)
    func list(server: SMBServer, path: String, password suppliedPassword: String? = nil) async throws -> [SMBEntry] {
        guard let root = server.rootURL, var c = URLComponents(url: root, resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "SMB", code: 1, userInfo: [NSLocalizedDescriptionKey: L("服务器地址无效。")])
        }
        c.path = path.isEmpty ? "/" : path
        guard c.url != nil else { throw URLError(.badURL) }
        let pieces = path.split(separator: "/").map(String.init)
        let share = pieces.first ?? ""
        let relativePath = pieces.dropFirst().joined(separator: "/")
        let authority = server.host + (server.port.map { ":\($0)" } ?? "")
        let password = suppliedPassword ?? KeychainStore.password(for: server.id)
        let login = SMBLogin(username: server.username, domain: server.domain)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let collector = EntryCollector()
                let code = iina_smb_list(authority, share, relativePath, login.domain, login.username, password,
                                        Unmanaged.passUnretained(collector).toOpaque()) { raw, name, isDir in
                    guard let raw, let name else { return }
                    let c = Unmanaged<EntryCollector>.fromOpaque(raw).takeUnretainedValue()
                    c.entries.append((String(cString: name), isDir != 0))
                }
                if code != 0 {
                    continuation.resume(throwing: SMBFailure.current(fallback: code))
                } else {
                    let entries = collector.entries.map { name, directory in
                        SMBEntry(name: name, path: (path as NSString).appendingPathComponent(name), isDirectory: directory)
                    }.sorted {
                        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    continuation.resume(returning: entries)
                }
            }
        }
    }
}
