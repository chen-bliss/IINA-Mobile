// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CoreText
@testable import IINAMobile

final class PlayerModelTests: XCTestCase {
    func testBundledSubtitleFontContainsSimplifiedAndTraditionalChinese() throws {
        let folder = try XCTUnwrap(SubtitleFonts.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("NotoSansCJKsc-Regular.otf").path))
        let font = CTFontCreateWithName("NotoSansCJKsc-Regular" as CFString, 24, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, "NotoSansCJKsc-Regular")
        let characters = Array("字幕测试繁體中文".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count))
        XCTAssertFalse(glyphs.contains(0), "Every Chinese character must resolve to a real glyph.")
    }
    func testIINAColorRangesAndReset() {
        var picture = PictureSettings()
        for control in ColorControl.allCases {
            picture[control] = 150
            XCTAssertEqual(picture[control], 100)
            picture[control] = -150
            XCTAssertEqual(picture[control], -100)
            picture[control] = .nan
            XCTAssertEqual(picture[control], 0)
        }
        picture[.contrast] = 32
        picture.hdrMode = .sdr
        picture.resetColors()
        XCTAssertEqual(picture[.contrast], 0)
        XCTAssertEqual(picture.hdrMode, .sdr)
    }
    func testColorPersistenceRoundTrip() throws {
        var picture = PictureSettings()
        picture[.gamma] = 37
        picture.toneMapping = "bt.2390"
        XCTAssertEqual(try JSONDecoder().decode(PictureSettings.self, from: JSONEncoder().encode(picture)), picture)
    }
    func testSMBURLPreservesNonASCIIAndEscapesCredentials() throws {
        let server = SMBServer(name: "NAS", host: "192.168.8.2", share: "电影", username: "a@b", domain: "WORKGROUP")
        let url = try XCTUnwrap(server.playbackURL(path: "/电影/我的电影 #1.mkv", password: "p@:/#?%"))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "192.168.8.2")
        XCTAssertEqual(parts.path, "/电影/我的电影 #1.mkv")
        XCTAssertEqual(parts.user, "WORKGROUP;a@b")
        XCTAssertEqual(parts.password, "p@:/#?%")
        XCTAssertFalse(MediaPrivacy.safeTitle(url).contains("p@"))
        XCTAssertEqual(MediaPrivacy.safeTitle(url), "我的电影 #1.mkv")
    }
    func testServerPersistenceNeverIncludesPassword() throws {
        let server = SMBServer(name: "NAS", host: "nas.local", share: "Videos", username: "viewer")
        let json = String(data: try JSONEncoder().encode(server), encoding: .utf8)!
        XCTAssertFalse(json.contains("password"))
        XCTAssertTrue(server.isValid)
        XCTAssertFalse(SMBServer(name: "NAS", host: "smb://nas.local", share: "", username: "").isValid)
    }
    func testTrackListIncludesEmbeddedAudioAndSubtitle() {
        let tracks = MediaTrack.decode("""
        [{"id":1,"type":"video","codec":"hevc"},{"id":2,"type":"audio","lang":"en"},{"id":3,"type":"sub","lang":"zh","title":"简体中文","codec":"ass"}]
        """)
        XCTAssertEqual(tracks.count, 3)
        XCTAssertEqual(tracks.last?.label, "简体中文 · zh · ass")
        XCTAssertEqual(MediaTrack.decode("not JSON"), [])
    }
    func testWindowsDomainLoginAndOpaqueSMBRoute() throws {
        XCTAssertEqual(SMBLogin(username: "OFFICE\\viewer", domain: ""), SMBLogin(username: "viewer", domain: "OFFICE"))
        let server = SMBServer(name: "NAS", host: "nas.local", share: "电影", username: "OFFICE\\viewer")
        let original = try XCTUnwrap(server.playbackURL(path: "/电影/片段 #100% .mkv", password: "p@:/#?%"))
        let router = SMBPlaybackStream()
        let routed = router.mediaPath(original)
        XCTAssertFalse(routed.contains("viewer"))
        XCTAssertFalse(routed.contains("p@"))
        let token = try XCTUnwrap(URLComponents(string: routed)?.host)
        let restored = try XCTUnwrap(router.location(for: token))
        XCTAssertEqual(restored.path, "/电影/片段 #100% .mkv")
        XCTAssertEqual(restored.password, "p@:/#?%")
    }
    func testDisplayPreferencesRemainIndependentFromColorReset() throws {
        let display = VideoDisplaySettings(fit: .fill, aspect: .classic)
        XCTAssertEqual(try JSONDecoder().decode(VideoDisplaySettings.self, from: JSONEncoder().encode(display)), display)
        XCTAssertEqual(display.aspect.mpvValue, "4:3")
        XCTAssertEqual(VideoAspect.original.mpvValue, "-1")
    }
}
