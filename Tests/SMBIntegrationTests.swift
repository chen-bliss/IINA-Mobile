// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
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
