// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import IINAMobile

final class PreferencesHistoryTests: XCTestCase {
    func testDefaultsRoundTripAndPowerSavingResolution() throws {
        let name = "IINA-Defaults-\(UUID())"
        let storage = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { storage.removePersistentDomain(forName: name) }
        var settings = AppPreferences()
        settings.picture[.contrast] = 24; settings.picture.hdrMode = .sdr
        settings.rendering = .energy; settings.subtitles = .off; settings.display.fit = .fill
        settings.save(to: storage)
        XCTAssertEqual(AppPreferences.load(from: storage), settings)
        let size = CGSize(width: 440, height: 956)
        let scale = RenderResolution.scale(size: size, nativeScale: 3, constrained: true)
        XCTAssertEqual(max(size.width, size.height) * scale, 1920, accuracy: 0.01)
        XCTAssertLessThan(scale * scale / 9, 0.5, "The constrained output should use less than half the pixels on this display.")
        XCTAssertEqual(RenderResolution.scale(size: size, nativeScale: 3, constrained: false), 3)
    }
    @MainActor
    func testTemporaryPlayerAdjustmentsDoNotOverwriteDefaults() {
        let storage = UserDefaults.standard
        let original = storage.data(forKey: AppPreferences.storageKey)
        defer { storage.set(original, forKey: AppPreferences.storageKey) }
        var settings = AppPreferences()
        settings.picture[.brightness] = 10; settings.rendering = .energy
        settings.save()
        let engine = PlayerEngine()
        engine.setColor(.brightness, value: 70)
        engine.setRenderingMode(.quality)
        engine.setDisplay(fit: .stretch)
        XCTAssertEqual(AppPreferences.load(), settings)
    }
    func testSMBHistoryUsesCurrentKeychainPasswordWithoutPersistingIt() throws {
        let server = SMBServer(name: "Test NAS", host: "nas.test", share: "电影", username: "viewer")
        try KeychainStore.set("initial-secret", for: server.id)
        defer { KeychainStore.remove(server.id) }
        let url = try XCTUnwrap(server.playbackURL(path: "/电影/中文 #1.mkv", password: "initial-secret"))
        let resource = try HistoryResource.capture(url, servers: [server])
        XCTAssertEqual(resource.kind, .server)
        XCTAssertEqual(resource.serverID, server.id)
        let json = String(data: try JSONEncoder().encode(resource), encoding: .utf8)!
        XCTAssertFalse(json.contains("initial-secret")); XCTAssertFalse(json.contains("smb://"))
        try KeychainStore.set("updated-secret", for: server.id)
        let resolved = try resource.resolve(servers: [server])
        XCTAssertEqual(URLComponents(url: resolved, resolvingAgainstBaseURL: false)?.password, "updated-secret")
        XCTAssertEqual(resolved.path, "/电影/中文 #1.mkv")
        XCTAssertThrowsError(try resource.resolve(servers: []))
    }
    func testHistoryProgressPersistenceAndRemoval() throws {
        let name = "IINA-History-\(UUID())"
        let storage = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { storage.removePersistentDomain(forName: name) }
        let original = UserDefaults.standard.data(forKey: AppPreferences.storageKey)
        defer { UserDefaults.standard.set(original, forKey: AppPreferences.storageKey) }
        AppPreferences().save()
        let history = PlaybackHistory(defaults: storage)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Sample-SDR", withExtension: "mkv"))
        let item = PlaybackItem(url: url)
        let id = try XCTUnwrap(history.opened(item, servers: []))
        history.update(id, position: 12, duration: 120, force: true)
        let reopened = PlaybackHistory(defaults: storage)
        XCTAssertEqual(reopened.entries.count, 1)
        XCTAssertEqual(try reopened.playback(for: reopened.entries[0], servers: []).startPosition, 12)
        _ = history.opened(item, servers: [])
        XCTAssertEqual(history.entries.count, 1, "Replaying a video must not duplicate its history row.")
        history.remove(id)
        XCTAssertTrue(PlaybackHistory(defaults: storage).entries.isEmpty)
        var finished = HistoryEntry(title: "Finished", source: .init(kind: .sample, location: "Sample-SDR.mkv"))
        finished.position = 119; finished.duration = 120
        XCTAssertEqual(finished.resumePosition, 0)
    }
    func testNetworkHistoryDoesNotPersistPasswordsOrURLTokens() throws {
        let url = try XCTUnwrap(URL(string: "https://viewer:login-secret@video.test/movie.mkv?access_token=query-secret"))
        let source = try HistoryResource.capture(url, servers: [])
        defer { source.forgetCredential() }
        let json = String(data: try JSONEncoder().encode(source), encoding: .utf8)!
        XCTAssertFalse(json.contains("login-secret")); XCTAssertFalse(json.contains("query-secret"))
        XCTAssertEqual(try source.resolve(servers: []), url)
    }
}
