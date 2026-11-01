// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import AVFoundation
import Vision
@testable import IINAMobile

final class SMBIntegrationTests: XCTestCase {
    private func fixture() throws -> SMBServer {
        guard ProcessInfo.processInfo.environment["IINA_SMB_QA"] == "1" else {
            throw XCTSkip("Run the isolated SMB fixture and use the SMBQA scheme to test networking.")
        }
        let server = SMBServer(name: "SMB QA", host: "127.0.0.1", share: "QA", username: "iinaqa", port: 1445)
        try KeychainStore.set("fixture-only", for: server.id)
        return server
    }
    func testAirPlayTranscodesSMBMatroska() async throws {
        guard ProcessInfo.processInfo.environment["IINA_SMB_QA"] == "1" else { throw XCTSkip("Requires isolated SMB fixture") }
        let source = try XCTUnwrap(URL(string: "smb://iinaqa:fixture-only@127.0.0.1:1445/QA/QA-Tracks.mkv"))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("airplay-smb-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let track = RememberedTrack(mode: "track", id: 1, title: "English Main", language: "eng", codec: "subrip")
        try await AirPlayTranscoder().convert(source: source, output: output, audioID: "auto", subtitle: track)
        let asset = AVURLAsset(url: output)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let image = try AVAssetImageGenerator(asset: asset).copyCGImage(at: CMTime(seconds: 2, preferredTimescale: 600), actualTime: nil)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("english") && text.contains("main"), "Expected SMB subtitle, got: \(text)")
    }

    func testSMBAirPlayCacheIdentity() throws {
        guard ProcessInfo.processInfo.environment["IINA_SMB_QA"] == "1" else { throw XCTSkip("Requires isolated SMB fixture") }
        let source = try XCTUnwrap(URL(string: "smb://iinaqa:fixture-only@127.0.0.1:1445/QA/QA-Tracks.mkv"))
        let cache = AirPlayConversionCache(), subtitle = RememberedTrack(mode: "no")
        let first = try XCTUnwrap(cache.key(source: source, audioID: "1", subtitle: subtitle, externalSubtitles: [], subtitleDelay: 0, subtitleSize: 40))
        let second = try cache.key(source: source, audioID: "1", subtitle: subtitle, externalSubtitles: [], subtitleDelay: 0, subtitleSize: 40)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.contains("fixture-only"))
        let changed = try cache.key(source: source, audioID: "2", subtitle: subtitle, externalSubtitles: [], subtitleDelay: 0, subtitleSize: 40)
        XCTAssertNotEqual(first, changed)
    }
    func testDLNADiscoveryFindsIsolatedReceiver() async throws {
        guard ProcessInfo.processInfo.environment["IINA_SMB_QA"] == "1" else { throw XCTSkip("Requires isolated DLNA receiver") }
        let locations = try await DLNADiscovery.search()
        XCTAssertTrue(locations.contains { $0.port == 18629 && $0.path == "/device.xml" }, "QA renderer was not discovered")
    }
    func testDLNAEndToEndWithIsolatedReceiver() async throws {
        guard ProcessInfo.processInfo.environment["IINA_SMB_QA"] == "1" else { throw XCTSkip("Requires isolated DLNA receiver") }
        let source = try XCTUnwrap(Bundle.main.url(forResource: "QA-PiP", withExtension: "mp4"))
        let bridge = SMBHTTPBridge(source: source); defer { bridge.stop() }
        let mediaURL = try await bridge.start()
        let description = try XCTUnwrap(URL(string: "http://127.0.0.1:18629/device.xml"))
        let renderer = try await DLNARenderer.load(descriptionURL: description)
        XCTAssertEqual(renderer.name, "QA Renderer")
        try await renderer.setURI(mediaURL)
        try await renderer.play()
        try await renderer.seek(seconds: 12)
        let position = try await renderer.action("GetPositionInfo", arguments: [("InstanceID", "0")])
        XCTAssertEqual(DLNAPosition.read(position)?.position, 12)
        try await renderer.pause()
        let state = try await renderer.action("GetTransportInfo", arguments: [("InstanceID", "0")])
        XCTAssertEqual(DLNAPosition.state(state), "PAUSED_PLAYBACK")
        try await renderer.stop()
    }
    func testDLNAStreamsTranscodedSMBMKV() async throws {
        guard ProcessInfo.processInfo.environment["IINA_SMB_QA"] == "1" else { throw XCTSkip("Requires isolated SMB and DLNA fixtures") }
        let source = try XCTUnwrap(URL(string: "smb://iinaqa:fixture-only@127.0.0.1:1445/QA/QA-Tracks.mkv"))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("dlna-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let subtitle = RememberedTrack(mode: "track", id: 1, title: "English Main", language: "eng", codec: "subrip")
        try await AirPlayTranscoder().convert(source: source, output: output, audioID: "auto", subtitle: subtitle)
        let bridge = SMBHTTPBridge(source: output); defer { bridge.stop() }
        let mediaURL = try await bridge.start()
        let description = try XCTUnwrap(URL(string: "http://127.0.0.1:18629/device.xml"))
        let renderer = try await DLNARenderer.load(descriptionURL: description)
        try await renderer.setURI(mediaURL)
        try await renderer.play()
        try await renderer.seek(seconds: 12)
        let response = try await renderer.action("GetPositionInfo", arguments: [("InstanceID", "0")])
        XCTAssertEqual(DLNAPosition.read(response)?.position, 12)
        try await renderer.stop()
    }
    func testAirPlayHTTPBridgeServesByteRanges() async throws {
        guard ProcessInfo.processInfo.environment["IINA_SMB_QA"] == "1" else { throw XCTSkip("Requires isolated SMB fixture") }
        let source = try XCTUnwrap(URL(string: "smb://iinaqa:fixture-only@127.0.0.1:1445/QA/QA-PiP.mp4"))
        let bridge = SMBHTTPBridge(source: source)
        defer { bridge.stop() }
        let url = try await bridge.start()
        let original = try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "QA-PiP", withExtension: "mp4")))
        var request = URLRequest(url: url)
        request.setValue("bytes=1024-2047", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 1024-2047/\(original.count)")
        XCTAssertEqual(data, original.subdata(in: 1024..<2048))
        var head = URLRequest(url: url); head.httpMethod = "HEAD"
        let (body, headResponse) = try await URLSession.shared.data(for: head)
        XCTAssertTrue(body.isEmpty)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), String(original.count))
    }
    func testAuthenticatedSMB2DirectoryAndSubtitleDiscovery() async throws {
        let server = try fixture()
        defer { KeychainStore.remove(server.id) }
        let entries = try await SMBService.shared.list(server: server, path: "/QA")
        XCTAssertTrue(entries.contains { $0.name == "Sample-SDR.mkv" && $0.isVideo })
        XCTAssertTrue(entries.contains { $0.name == "Sample-HDR.mkv" && $0.isVideo })
        XCTAssertTrue(entries.contains { $0.name == "Sample.ass" && $0.isSubtitle })
    }
    func testIncorrectSMBCredentialsAreRejected() async throws {
        let server = try fixture()
        defer { KeychainStore.remove(server.id) }
        try KeychainStore.set("incorrect-fixture-password", for: server.id)
        do {
            _ = try await SMBService.shared.list(server: server, path: "/QA")
            XCTFail("The server should reject incorrect credentials.")
        } catch {
            let failure = try XCTUnwrap(error as? SMBFailure)
            XCTAssertEqual(failure.stage, 1)
            if failure.ntStatus == 0 {
                // Some test-server versions close the connection without an
                // SMB status response. Do not mislabel that as authentication.
                XCTAssertFalse(failure.localizedDescription.contains("服务器拒绝了 SMB 登录"))
            } else {
                XCTAssertEqual(failure.code, 13)
            }
        }
    }
    func testSMBStreamReadSeekAndCancel() throws {
        let server = try fixture()
        defer { KeychainStore.remove(server.id) }
        let file = try XCTUnwrap(iina_smb_open("127.0.0.1:1445", "QA", "Sample-SDR.mkv", "", "iinaqa", "fixture-only"))
        defer { iina_smb_close(file) }
        let sample = try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "Sample-SDR", withExtension: "mkv")))
        XCTAssertEqual(iina_smb_size(file), Int64(sample.count))
        var bytes = [CChar](repeating: 0, count: 64)
        let count = iina_smb_read(file, &bytes, 64)
        XCTAssertEqual(count, 64)
        XCTAssertEqual(bytes.map { UInt8(bitPattern: $0) }, Array(sample.prefix(64)))
        XCTAssertEqual(iina_smb_seek(file, 1024), 1024)
        XCTAssertEqual(iina_smb_read(file, &bytes, 64), 64)
        XCTAssertEqual(bytes.map { UInt8(bitPattern: $0) }, Array(sample[1024..<1088]))
        iina_smb_cancel(file)
        XCTAssertEqual(iina_smb_read(file, &bytes, 64), -1)
    }
    func testUnavailableEndpointIsNotReportedAsAuthenticationFailure() async throws {
        var server = try fixture()
        defer { KeychainStore.remove(server.id) }
        server.port = 1446 // The isolated fixture listens only on 1445.
        do {
            _ = try await SMBService.shared.list(server: server, path: "/QA")
            XCTFail("An endpoint with no listener must fail.")
        } catch {
            let failure = try XCTUnwrap(error as? SMBFailure)
            XCTAssertEqual(failure.stage, 1)
            XCTAssertEqual(failure.ntStatus, 0)
            XCTAssertFalse([1, 13].contains(failure.code))
            XCTAssertFalse(failure.localizedDescription.contains("服务器拒绝了 SMB 登录"))
        }
    }
    func testSmallSequentialReadsShareOneNetworkRequest() throws {
        let server = try fixture()
        defer { KeychainStore.remove(server.id) }
        let file = try XCTUnwrap(iina_smb_open("127.0.0.1:1445", "QA", "Sample-SDR.mkv", "", "iinaqa", "fixture-only"))
        defer { iina_smb_close(file) }
        let sample = try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "Sample-SDR", withExtension: "mkv")))
        var received = [UInt8]()
        var bytes = [CChar](repeating: 0, count: 32)
        for _ in 0..<128 {
            XCTAssertEqual(iina_smb_read(file, &bytes, 32), 32)
            received += bytes.map { UInt8(bitPattern: $0) }
        }
        XCTAssertEqual(received, Array(sample.prefix(4096)))
        XCTAssertEqual(iina_smb_network_reads(file), 1, "Small demuxer reads must reuse a fetched SMB block.")
        XCTAssertEqual(iina_smb_seek(file, 512), 512)
        XCTAssertEqual(iina_smb_read(file, &bytes, 32), 32)
        XCTAssertEqual(bytes.map { UInt8(bitPattern: $0) }, Array(sample[512..<544]))
        XCTAssertEqual(iina_smb_network_reads(file), 1, "A nearby backward seek should reuse the same block.")
        XCTAssertEqual(iina_smb_seek(file, Int64(sample.count - 16)), Int64(sample.count - 16))
        XCTAssertEqual(iina_smb_read(file, &bytes, 32), 16)
        XCTAssertEqual(bytes.prefix(16).map { UInt8(bitPattern: $0) }, Array(sample.suffix(16)))
        XCTAssertEqual(iina_smb_read(file, &bytes, 32), 0)
        XCTAssertEqual(iina_smb_seek(file, 0), 0)
        XCTAssertEqual(iina_smb_read(file, &bytes, 32), 32)
        XCTAssertEqual(bytes.map { UInt8(bitPattern: $0) }, Array(sample.prefix(32)))
    }
    func testSharedFoldersCanBeListedWithoutEnteringShareName() async throws {
        let server = try fixture()
        defer { KeychainStore.remove(server.id) }
        let entries = try await SMBService.shared.list(server: server, path: "/")
        XCTAssertTrue(entries.contains { $0.name == "QA" && $0.isDirectory })
    }
    func testUnicodePathAndLargeFileOffsets() throws {
        let server = try fixture()
        defer { KeychainStore.remove(server.id) }
        let file = try XCTUnwrap(iina_smb_open("127.0.0.1:1445", "QA", "中文目录/电影 #100% 空格.mkv", "", "iinaqa", "fixture-only"))
        iina_smb_close(file)
        let large = try XCTUnwrap(iina_smb_open("127.0.0.1:1445", "QA", "Large.bin", "", "iinaqa", "fixture-only"))
        defer { iina_smb_close(large) }
        let offset = (Int64(1) << 32) + 1024
        XCTAssertGreaterThan(iina_smb_size(large), offset)
        XCTAssertEqual(iina_smb_seek(large, offset), offset)
        var buffer = [CChar](repeating: 0, count: 17)
        XCTAssertEqual(iina_smb_read(large, &buffer, 17), 17)
        XCTAssertEqual(String(bytes: buffer.map { UInt8(bitPattern: $0) }, encoding: .utf8), "IINA-large-offset")
    }
    func testMissingFolderHasAccurateFailureStage() async throws {
        let server = try fixture()
        defer { KeychainStore.remove(server.id) }
        do {
            _ = try await SMBService.shared.list(server: server, path: "/QA/missing-folder")
            XCTFail("Missing folders must fail.")
        } catch {
            let failure = try XCTUnwrap(error as? SMBFailure)
            XCTAssertEqual(failure.stage, 3)
            XCTAssertEqual(failure.code, 2)
        }
    }
}
