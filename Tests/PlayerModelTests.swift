// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import CoreText
import AVFoundation
import Vision
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
    func testAirPlayTranscoderProducesPlayableMP4() async throws {
        let source = try XCTUnwrap(Bundle.main.url(forResource: "Sample-SDR", withExtension: "mkv"))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("airplay-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await AirPlayTranscoder().convert(source: source, output: output, audioID: "auto")
        let asset = AVURLAsset(url: output)
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.load(.tracks)
        XCTAssertTrue(playable)
        XCTAssertTrue(tracks.contains { $0.mediaType == .video })
        XCTAssertTrue(tracks.contains { $0.mediaType == .audio })
    }

    func testAirPlayConversionBurnsSelectedSubtitle() async throws {
        let source = try XCTUnwrap(Bundle.main.url(forResource: "QA-Tracks", withExtension: "mkv"))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("airplay-sub-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let track = RememberedTrack(mode: "track", id: 2, title: "English SDH", language: "eng", codec: "subrip")
        try await AirPlayTranscoder().convert(source: source, output: output, audioID: "auto", subtitle: track)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        let image = try generator.copyCGImage(at: CMTime(seconds: 2, preferredTimescale: 600), actualTime: nil)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("english") && text.contains("sdh"), "Expected selected subtitle in video frame, got: \(text)")
    }

    func testAirPlayConversionBurnsExternalSubtitleAndReportsProgress() async throws {
        let source = try XCTUnwrap(Bundle.main.url(forResource: "Sample-SDR", withExtension: "mkv"))
        let external = try XCTUnwrap(Bundle.main.url(forResource: "Sample", withExtension: "ass"))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("airplay-external-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let lock = NSLock()
        var reported: [Double] = []
        let selected = RememberedTrack(mode: "track", externalIndex: 0)
        try await AirPlayTranscoder().convert(source: source, output: output, audioID: "auto", subtitle: selected, externalSubtitles: [external]) { value in
            if let value { lock.withLock { reported.append(value) } }
        }
        let values = lock.withLock { reported }
        XCTAssertEqual(values.last, 1)
        XCTAssertTrue(values.contains { $0 >= 0 && $0 < 1 }, "Expected intermediate progress")
        XCTAssertTrue(values.allSatisfy { (0...1).contains($0) })
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        let image = try generator.copyCGImage(at: CMTime(seconds: 2, preferredTimescale: 600), actualTime: nil)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("mobile") && text.contains("subtitle"), "Expected external subtitle in video frame, got: \(text)")
    }

    func testAirPlayConversionCacheKeyTracksChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("video.mkv"), subtitleFile = dir.appendingPathComponent("sub.srt")
        try Data("video".utf8).write(to: video)
        try Data("subtitle".utf8).write(to: subtitleFile)
        let cache = AirPlayConversionCache()
        let selected = RememberedTrack(mode: "track", externalIndex: 0)
        func key(_ audio: String = "1", _ delay: Double = 0) throws -> String? {
            try cache.key(source: video, audioID: audio, subtitle: selected, externalSubtitles: [subtitleFile], subtitleDelay: delay, subtitleSize: 40)
        }
        let original = try XCTUnwrap(key())
        XCTAssertEqual(try key(), original)
        XCTAssertNotEqual(try key("2"), original)
        XCTAssertNotEqual(try key("1", 1), original)
        try Data("changed subtitle".utf8).write(to: subtitleFile)
        XCTAssertNotEqual(try key(), original)
        try Data("different video".utf8).write(to: video)
        XCTAssertNotEqual(try key(), original)
    }

    func testAirPlayCachePersistsAndRejectsCorruptEntries() async throws {
        let key = "test-" + UUID().uuidString
        let cache = AirPlayConversionCache()
        let destination = try cache.url(for: key)
        defer { try? FileManager.default.removeItem(at: destination) }
        let fixture = try XCTUnwrap(Bundle.main.url(forResource: "QA-PiP", withExtension: "mp4"))
        try FileManager.default.copyItem(at: fixture, to: destination)
        let reused = try await AirPlayConversionCache().reusableURL(for: key)
        XCTAssertEqual(reused, destination)
        try FileManager.default.removeItem(at: destination)
        try Data("incomplete".utf8).write(to: destination)
        let corrupt = try await AirPlayConversionCache().reusableURL(for: key)
        XCTAssertNil(corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSSDPRejectsSpoofedLocation() throws {
        let valid = Data("HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.2:1234/device.xml\r\n\r\n".utf8)
        XCTAssertEqual(DLNADiscovery.location(from: valid, sender: "192.168.1.2")?.host, "192.168.1.2")
        XCTAssertNil(DLNADiscovery.location(from: valid, sender: "192.168.1.3"))
        let malicious = Data("HTTP/1.1 200 OK\r\nLOCATION: file:///private/data\r\n\r\n".utf8)
        XCTAssertNil(DLNADiscovery.location(from: malicious, sender: "192.168.1.2"))
    }
    func testDLNARendererDescriptionAndSOAP() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DLNAURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "http://renderer.local:1234/device.xml"))
        let device = try await DLNARenderer.load(descriptionURL: url, session: session)
        XCTAssertEqual(device.name, "Living Room")
        XCTAssertEqual(device.controlURL.absoluteString, "http://renderer.local:1234/control")
        let media = try XCTUnwrap(URL(string: "http://phone.local/video.mp4?a=1&b=2"))
        try await device.setURI(media, session: session)
        let request = try XCTUnwrap(DLNAURLProtocol.lastRequest())
        XCTAssertEqual(request.value(forHTTPHeaderField: "SOAPACTION"), "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("a=1&amp;b=2"))
        try await device.seek(seconds: 3723, session: session)
        let seek = try XCTUnwrap(DLNAURLProtocol.lastRequest()?.httpBody)
        XCTAssertTrue(String(decoding: seek, as: UTF8.self).contains("01:02:03"))
        let position = try XCTUnwrap(DLNAPosition.read(Data("<root><RelTime>01:02:03</RelTime><TrackDuration>02:00:00</TrackDuration></root>".utf8)))
        XCTAssertEqual(position.position, 3723)
        XCTAssertEqual(position.duration, 7200)
    }
    func testDLNARejectsForeignControlURLAndSOAPFault() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DLNAURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let badDescription = try XCTUnwrap(URL(string: "http://renderer.local:1234/foreign.xml"))
        do { _ = try await DLNARenderer.load(descriptionURL: badDescription, session: session); XCTFail("Foreign control host must be rejected") } catch { }
        let faultURL = try XCTUnwrap(URL(string: "http://renderer.local:1234/fault"))
        let device = DLNARenderer(name: "Test", controlURL: faultURL, serviceType: "urn:schemas-upnp-org:service:AVTransport:1")
        do { try await device.play(session: session); XCTFail("SOAP faults must not be treated as success") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Not supported")) }
    }
    func testLocalFileBridgeServesRange() async throws {
        let source = try XCTUnwrap(Bundle.main.url(forResource: "QA-PiP", withExtension: "mp4"))
        let bridge = SMBHTTPBridge(source: source)
        defer { bridge.stop() }
        let url = try await bridge.start()
        var request = URLRequest(url: url); request.setValue("bytes=16-143", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(data, try Data(contentsOf: source).subdata(in: 16..<144))
    }

}

private final class DLNAURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requestCopy: URLRequest?
    static func lastRequest() -> URLRequest? { lock.withLock { requestCopy } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        Self.lock.withLock { Self.requestCopy = captured }
        let description = """
        <?xml version="1.0"?><root><device><friendlyName>Living Room</friendlyName><serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/control</controlURL></service></serviceList></device></root>
        """
        let foreign = description.replacingOccurrences(of: "/control", with: "http://other.local/control")
        let fault = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><s:Fault><detail><errorDescription>Not supported</errorDescription></detail></s:Fault></s:Body></s:Envelope>"
        let body = request.url?.path == "/fault" ? fault : (request.httpMethod == "POST" ? "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body/></s:Envelope>" : (request.url?.path == "/foreign.xml" ? foreign : description))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
