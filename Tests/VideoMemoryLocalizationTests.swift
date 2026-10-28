// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import AVFoundation
@testable import IINAMobile

final class VideoMemoryLocalizationTests: XCTestCase {
    func testPreviewAndPanelDoNotOverlapAcrossScreenSizes() {
        for size in [CGSize(width: 393, height: 852), CGSize(width: 852, height: 393), CGSize(width: 728, height: 1036), CGSize(width: 1036, height: 728)] {
            let layout = PlayerLayout(size: size, safe: UIEdgeInsets(top: size.height > size.width ? 59 : 0, left: 0, bottom: 34, right: 0))
            XCTAssertFalse(layout.preview.intersects(layout.panel))
            XCTAssertGreaterThan(layout.preview.width, 100)
            XCTAssertGreaterThan(layout.preview.height, 100)
            XCTAssertLessThanOrEqual(layout.panel.maxY, size.height - 132)
        }
    }
    func testArabicLandscapePreviewMirrorsWithoutOverlap() {
        let size = CGSize(width: 852, height: 393)
        let layout = PlayerLayout(size: size, safe: .zero, rightToLeft: true)
        XCTAssertLessThan(layout.panel.maxX, layout.preview.minX)
        XCTAssertFalse(layout.preview.intersects(layout.panel))
        XCTAssertLessThanOrEqual(layout.preview.maxX, size.width)
    }
    func testRememberExactEnglishVersionAndTrackRemapping() {
        let tracks = [MediaTrack(id: 2, type: "sub", title: "English Main", language: "eng", codec: "subrip"),
                      MediaTrack(id: 3, type: "sub", title: "English SDH", language: "eng", codec: "subrip")]
        let selected = RememberedTrack.capture("3", tracks: tracks, type: "sub")
        XCTAssertEqual(selected.resolve(in: tracks, type: "sub"), "3")
        let remapped = [MediaTrack(id: 8, type: "sub", title: "English SDH", language: "eng", codec: "subrip"), tracks[0]]
        XCTAssertEqual(selected.resolve(in: remapped, type: "sub"), "8")
        XCTAssertEqual(RememberedTrack.capture("auto", tracks: tracks, type: "sub").mode, "auto")
        XCTAssertEqual(RememberedTrack.capture("no", tracks: tracks, type: "sub").resolve(in: tracks, type: "sub"), "no")
        XCTAssertEqual(selected.resolve(in: [], type: "sub"), "auto")
    }
    func testExternalTrackIdentitySurvivesNewNumericID() {
        let track = MediaTrack(id: 5, type: "sub", title: "release-b.srt", language: "eng", codec: "subrip", external: true)
        let saved = RememberedTrack.capture("5", tracks: [track], type: "sub")
        let embedded = MediaTrack(id: 5, type: "sub", title: "English", language: "eng", codec: "subrip")
        let moved = MediaTrack(id: 9, type: "sub", title: track.title, language: track.language, codec: track.codec, external: true)
        XCTAssertEqual(saved.resolve(in: [embedded, moved], type: "sub"), "9")
    }
    func testPerVideoSettingsPersistIndependentlyAndApplyOutsideHistoryList() throws {
        let name = "IINA-Memory-\(UUID())"
        let storage = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { storage.removePersistentDomain(forName: name) }
        let original = UserDefaults.standard.data(forKey: AppPreferences.storageKey)
        defer { UserDefaults.standard.set(original, forKey: AppPreferences.storageKey) }
        AppPreferences().save()
        let a = PlaybackItem(url: try XCTUnwrap(Bundle.main.url(forResource: "QA-Tracks", withExtension: "mkv")))
        let b = PlaybackItem(url: try XCTUnwrap(Bundle.main.url(forResource: "Sample-HDR", withExtension: "mkv")))
        let history = PlaybackHistory(defaults: storage)
        let id = try XCTUnwrap(history.opened(a, servers: []))
        var saved = VideoPlaybackSettings()
        saved.picture[.gamma] = 21; saved.picture.hdrMode = .sdr; saved.picture.toneMapping = "hable"
        saved.rendering = .energy; saved.display.fit = .fill; saved.display.aspect = .classic
        saved.subtitle = RememberedTrack(mode: "track", id: 3, title: "English SDH", language: "eng", codec: "subrip")
        saved.audio = RememberedTrack(mode: "track", id: 1, title: "Commentary", language: "eng", codec: "aac")
        saved.speed = 1.25; saved.subtitleDelay = -0.5; saved.subtitleSize = 48
        let sub = try XCTUnwrap(Bundle.main.url(forResource: "Sample", withExtension: "ass"))
        history.saveSettings(saved, subtitles: [sub], for: id, servers: [])
        let reloaded = PlaybackHistory(defaults: storage)
        let entry = try XCTUnwrap(reloaded.entries.first)
        XCTAssertEqual(try reloaded.playback(for: entry, servers: []).settings, saved)
        XCTAssertEqual(reloaded.prepared(a, servers: []).settings, saved)
        XCTAssertEqual(reloaded.prepared(a, servers: []).subtitles, [sub])
        XCTAssertNil(reloaded.prepared(b, servers: []).settings)
        XCTAssertEqual(AppPreferences.load().picture[.gamma], 0)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        old.removeValue(forKey: "settings")
        XCTAssertNil(try JSONDecoder().decode(HistoryEntry.self, from: JSONSerialization.data(withJSONObject: old)).settings)
    }
    func testDeviceLanguageResolutionAndEnglishFallback() {
        for (source, expected) in [("en-GB","en"),("zh-Hant-HK","zh-Hans"),("fr-CA","fr"),("es-MX","es"),("ru-RU","ru"),("ar-SA","ar"),("ja-JP","en"),("de-DE","en")] {
            XCTAssertEqual(AppLanguage.resolve([source, "zh-Hans"]), expected)
        }
        XCTAssertEqual(AppLanguage.resolve([]), "en")
    }
    func testManualLanguageOverridesDeviceLanguage() {
        XCTAssertEqual(AppLanguage.resolveSelection("fr", preferred: ["zh-Hans"]), "fr")
        XCTAssertEqual(AppLanguage.resolveSelection("ar", preferred: ["en"]), "ar")
        XCTAssertEqual(AppLanguage.resolveSelection("system", preferred: ["ru-RU"]), "ru")
        XCTAssertEqual(AppLanguage.resolveSelection("system", preferred: ["ja"]), "en")
        XCTAssertEqual(AppLanguage.resolveSelection("invalid", preferred: ["es"]), "es")
    }
    func testAllSixTranslationBundlesHaveCompleteKeysAndFormatArguments() throws {
        func dictionary(_ language: String) throws -> [String: String] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: "\(language).lproj"))
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try dictionary("en")
        XCTAssertGreaterThan(english.count, 180)
        for language in AppLanguage.supported {
            let values = try dictionary(language)
            XCTAssertEqual(Set(values.keys), Set(english.keys), language)
            for (key, value) in values {
                XCTAssertFalse(value.isEmpty)
                XCTAssertEqual(key.components(separatedBy: "%@").count, value.components(separatedBy: "%@").count, "\(language): \(key)")
            }
        }
    }
    func testPictureInPictureFormatBoundaries() throws {
        XCTAssertTrue(PictureInPictureSession.supports(URL(fileURLWithPath: "/video.MP4")))
        XCTAssertTrue(PictureInPictureSession.supports(try XCTUnwrap(URL(string: "smb://nas/share/movie.mov"))))
        XCTAssertTrue(PictureInPictureSession.supports(try XCTUnwrap(URL(string: "https://video.test/stream.m3u8?token=test"))))
        XCTAssertFalse(PictureInPictureSession.supports(URL(fileURLWithPath: "/movie.mkv")))
        XCTAssertFalse(PictureInPictureSession.supports(try XCTUnwrap(URL(string: "rtsp://video.test/movie.mp4"))))
    }
    func testAVFoundationReadsSMBByteRangesForNativePlayback() async throws {
        guard ProcessInfo.processInfo.environment["IINA_SMB_QA"] == "1" else { throw XCTSkip("Requires isolated SMB fixture") }
        let source = try XCTUnwrap(URL(string: "smb://iinaqa:fixture-only@127.0.0.1:1445/QA/QA-PiP.mp4"))
        let loader = SMBAssetLoader(source: source)
        defer { loader.stop() }
        let asset = AVURLAsset(url: try XCTUnwrap(URL(string: "iinapip://fixture/video.mp4")))
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        XCTAssertTrue(playable)
        XCTAssertGreaterThan(duration.seconds, 20)
        let generator = AVAssetImageGenerator(asset: asset)
        let image = try await generator.image(at: CMTime(seconds: 12, preferredTimescale: 600)).image
        XCTAssertGreaterThan(image.width, 300, "Native decoder must read and seek SMB media, not just recognize its header.")
    }
}
