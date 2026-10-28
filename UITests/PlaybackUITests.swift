// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import UIKit
import Vision

final class PlaybackUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--show-player-settings"]
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        return app
    }
    func testFreeColorControlsAndSubtitleSelection() {
        let app = launch()
        app.buttons["sampleSDR"].tap()
        let pause = app.buttons["togglePlayback"]
        XCTAssertTrue(pause.waitForExistence(timeout: 30))
        let loaded = app.staticTexts["playbackState"]
        let loadedExpectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'loaded'"), object: loaded)
        XCTAssertEqual(XCTWaiter.wait(for: [loadedExpectation], timeout: 30), .completed)
        XCTAssertFalse(app.alerts["播放提示"].exists)
        pause.tap()
        let original = app.otherElements["videoSurface"].screenshot()
        let saturation = app.sliders["color_saturation"]
        XCTAssertTrue(saturation.exists)
        saturation.adjust(toNormalizedSliderPosition: 0)
        let readback = app.staticTexts["colorReadback"]
        app.swipeUp()
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'saturation=-100'"), object: readback)
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 10), .completed)
        let changed = app.otherElements["videoSurface"].screenshot()
        XCTAssertNotEqual(original.pngRepresentation, changed.pngRepresentation, "The rendered video should change when saturation changes.")
        XCTAssertGreaterThan(chroma(original), 15, "The unmodified color bars should contain color.")
        XCTAssertLessThan(chroma(changed), chroma(original) * 0.25, "Saturation -100 should make the rendered bars grayscale.")
        for (name, screenshot) in [("Color-before", original), ("Color-after", changed)] {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        app.swipeDown()
        app.buttons["resetColors"].tap()
        XCTAssertEqual(app.staticTexts["value_saturation"].label, "0")
        app.segmentedControls["settingsTabs"].buttons["字幕"].tap()
        XCTAssertTrue(app.buttons["关闭字幕"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'subtitleTrack_' ")).firstMatch.exists)
        app.buttons["关闭字幕"].tap()
        app.buttons["自动选择"].tap()
        app.buttons["closePlayer"].tap()
        XCTAssertTrue(app.buttons["sampleSDR"].waitForExistence(timeout: 10))
    }
    func testHDRSourceAndSDRMapping() {
        let app = launch()
        app.buttons["sampleHDR"].tap()
        XCTAssertTrue(app.buttons["togglePlayback"].waitForExistence(timeout: 30))
        app.swipeUp()
        let status = app.staticTexts["hdrStatus"]
        let hdr = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'HDR 片源'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [hdr], timeout: 30), .completed)
        app.segmentedControls["hdrMode"].buttons["映射到 SDR"].tap()
        let sdr = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '当前未启用 EDR'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [sdr], timeout: 30), .completed)
        app.segmentedControls["hdrMode"].buttons["自动 HDR"].tap()
    }
    func testChineseSubtitlesAndHiddenCloseButton() throws {
        let app = launch()
        app.buttons["sampleSDR"].tap()
        let loaded = app.staticTexts["playbackState"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'loaded'"), object: loaded)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        app.segmentedControls["settingsTabs"].buttons["字幕"].tap()
        let subtitle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'subtitleTrack_' ")).firstMatch
        XCTAssertTrue(subtitle.waitForExistence(timeout: 10))
        subtitle.tap()
        app.buttons["togglePlayback"].tap()
        let surface = app.otherElements["videoSurface"]
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["closePlayer"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["togglePlayback"].exists)
        assertViewportMatches(surface)
        let screenshot = surface.screenshot()
        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("IINA-Chinese-subtitles.png")
        try screenshot.pngRepresentation.write(to: pngURL)
        print("CHINESE_SCREENSHOT_PATH=\(pngURL.path)")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.minimumTextHeight = 0.001
        request.regionOfInterest = CGRect(x: 0, y: 0.3, width: 1, height: 0.2)
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(data: screenshot.pngRepresentation)
        try handler.perform([request])
        let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
        XCTAssertTrue(text.contains("字幕测试") || text.contains("切换字幕"), "Rendered Chinese must be readable, not missing-glyph boxes. OCR: \(text)")
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Chinese-subtitles-controls-hidden"; attachment.lifetime = .keepAlways; add(attachment)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(app.buttons["closePlayer"].waitForExistence(timeout: 5))
        app.buttons["closePlayer"].tap()
        XCTAssertTrue(app.buttons["sampleSDR"].waitForExistence(timeout: 5))
    }
    func testSMBServerFormRejectsInvalidAddress() {
        let app = launch()
        app.buttons["addServer"].tap()
        XCTAssertTrue(app.textFields["serverName"].waitForExistence(timeout: 5))
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["请填写名称与服务器 IP 或主机名，地址中不需要 smb://。"].exists)
        app.alerts["服务器设置"].buttons["好"].tap()
        app.buttons["取消"].tap()
    }
    func testRenderingModeSwitchKeepsHDRPlaybackLoaded() {
        let app = launch()
        app.buttons["sampleHDR"].tap()
        let loaded = app.staticTexts["playbackState"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'loaded'"), object: loaded)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        let modes = app.segmentedControls["renderingMode"]
        XCTAssertTrue(modes.buttons["流畅优先"].waitForExistence(timeout: 5))
        modes.buttons["流畅优先"].tap()
        XCTAssertTrue(modes.buttons["流畅优先"].isSelected)
        XCTAssertEqual(loaded.label, "loaded")
        XCTAssertTrue(app.staticTexts["hdrStatus"].label.contains("HDR 片源"))
        modes.buttons["画质优先"].tap()
        XCTAssertTrue(modes.buttons["画质优先"].isSelected)
        XCTAssertEqual(loaded.label, "loaded")
        XCTAssertFalse(app.alerts["播放提示"].exists)
    }
    func testSMBVideoPlayback() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--show-player-settings", "--smb-qa"]
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let server = app.buttons["server_SMB QA"]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        server.tap()
        let video = app.buttons["Sample-SDR.mkv"]
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        video.tap()
        XCTAssertTrue(app.buttons["togglePlayback"].waitForExistence(timeout: 20))
        app.swipeUp()
        let loaded = app.staticTexts["playbackState"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'loaded'"), object: loaded)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        XCTAssertFalse(app.alerts["播放提示"].exists)
    }
    func testHistoryResumeAndSettingsEntry() {
        let app = launch()
        app.buttons["openSettings"].tap()
        XCTAssertTrue(app.staticTexts["settingsTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["defaultRendering"].exists || app.otherElements["defaultRendering"].exists)
        app.buttons["完成"].tap()
        app.buttons["sampleSDR"].tap()
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '暂停'"), object: app.buttons["togglePlayback"])
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 20), .completed)
        app.buttons["前进十秒"].tap()
        app.buttons["closePlayer"].tap()
        let recent = app.buttons["history_Sample-SDR.mkv"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.tap()
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '暂停'"), object: app.buttons["togglePlayback"])
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 20), .completed)
        let progress = app.sliders["播放进度"]
        XCTAssertFalse(app.alerts["播放提示"].exists)
        XCTAssertTrue(progress.exists)
        XCTAssertFalse((progress.value as? String ?? "").hasPrefix("0%"), "History should resume beyond the beginning.")
    }
    func testDefaultPlayerHidesSettingsAndAutoHidesBackButton() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--test-auto-hide"]
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        app.buttons["sampleSDR"].tap()
        XCTAssertFalse(app.segmentedControls["settingsTabs"].exists)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["closePlayer"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 12), .completed)
        let surface = app.otherElements["videoSurface"]
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(app.buttons["toggleSettings"].waitForExistence(timeout: 5))
        app.buttons["toggleSettings"].tap()
        XCTAssertTrue(app.segmentedControls["settingsTabs"].waitForExistence(timeout: 5))
    }
    func testPowerSavingModeConstrainsOutputResolution() {
        let app = launch()
        app.buttons["sampleHDR"].tap()
        let loaded = app.staticTexts["playbackState"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'loaded'"), object: loaded)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        app.segmentedControls["renderingMode"].buttons["省电优先"].tap()
        XCTAssertTrue(app.segmentedControls["renderingMode"].buttons["省电优先"].isSelected)
        app.buttons["toggleSettings"].tap()
        let surface = app.otherElements["videoSurface"]
        let constrained = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = surface.value as? String, let first = value.components(separatedBy: ";").first else { return false }
            let dimensions = first.replacingOccurrences(of: "render=", with: "").split(separator: ",").compactMap { Int($0) }
            return dimensions.count == 2 && dimensions.min()! > 0 && dimensions.max()! <= 1921
        }, object: surface)
        XCTAssertEqual(XCTWaiter.wait(for: [constrained], timeout: 20), .completed, surface.value as? String ?? "No viewport value")
        XCTAssertFalse(app.alerts["播放提示"].exists)
    }
    func testSettingsDefaultsApplyToNewVideoAndPersist() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--show-player-settings", "--preserve-defaults"]
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        app.buttons["openSettings"].tap()
        app.buttons["defaultRendering"].tap()
        app.buttons["省电优先"].tap()
        for _ in 0..<6 where !app.buttons["defaultSubtitles"].exists { app.swipeUp() }
        app.buttons["defaultSubtitles"].tap()
        app.buttons["默认关闭"].tap()
        XCTAssertTrue(app.buttons["完成"].exists, app.debugDescription)
        app.buttons["完成"].tap()
        app.buttons["sampleSDR"].tap()
        XCTAssertTrue(app.segmentedControls["renderingMode"].buttons["省电优先"].isSelected)
        app.segmentedControls["settingsTabs"].buttons["字幕"].tap()
        XCTAssertEqual(app.buttons["关闭字幕"].value as? String, "已选择")
        app.buttons["closePlayer"].tap()
        app.terminate(); app.launchArguments += ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        app.buttons["sampleSDR"].tap()
        XCTAssertTrue(app.segmentedControls["renderingMode"].buttons["省电优先"].isSelected)
        app.segmentedControls["settingsTabs"].buttons["字幕"].tap()
        XCTAssertEqual(app.buttons["关闭字幕"].value as? String, "已选择")
    }
    func testFullScreenResizeAndDisplayModes() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch()
        app.buttons["sampleSDR"].tap()
        XCTAssertTrue(app.buttons["toggleSettings"].waitForExistence(timeout: 20))
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '暂停'"), object: app.buttons["togglePlayback"])
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 20), .completed)
        app.buttons["togglePlayback"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let surface = app.otherElements["videoSurface"]
        assertViewportMatches(surface)
        let narrowWidth = surface.frame.width
        app.buttons["toggleSettings"].tap()
        assertViewportMatches(surface)
        XCTAssertEqual(surface.frame.width, narrowWidth, accuracy: 1)
        for mode in ["填满屏幕（裁切）", "拉伸铺满", "适应屏幕"] {
            app.buttons["displayMenu"].tap()
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", mode)).firstMatch.tap()
            assertViewportMatches(surface)
            XCTAssertFalse(app.alerts["播放提示"].exists)
            let expectedLetterbox = mode == "适应屏幕"
            let pixelsReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let brightness = self.letterboxBrightness(surface.screenshot())
                return expectedLetterbox ? brightness < 15 : brightness > 40
            }, object: surface)
            XCTAssertEqual(XCTWaiter.wait(for: [pixelsReady], timeout: 8), .completed, "The rendered pixels must reflect the selected screen mode.")
            let image = XCTAttachment(screenshot: surface.screenshot())
            image.name = mode; image.lifetime = .keepAlways; add(image)
        }
        app.buttons["displayMenu"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS '4:3'")).firstMatch.tap()
        app.buttons["toggleSettings"].tap()
        assertViewportMatches(surface)
        XCTAssertLessThan(surface.frame.width, narrowWidth * 1.15)
        app.buttons["toggleSettings"].tap()
        XCUIDevice.shared.orientation = .portrait
        assertViewportMatches(surface)
        XCTAssertGreaterThan(surface.frame.height, surface.frame.width)
        app.buttons["displayMenu"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS '原始比例'")).firstMatch.tap()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Full-screen-player"; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func assertViewportMatches(_ surface: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = surface.value as? String else { return false }
            let parts = value.components(separatedBy: ";surface=")
            guard parts.count == 2, parts[1] != "0,0" else { return false }
            return parts[0] == "render=" + parts[1]
        }, object: surface)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, surface.value as? String ?? "No viewport", file: file, line: line)
    }
    private func chroma(_ screenshot: XCUIScreenshot) -> Double {
        guard let image = screenshot.image.cgImage else { return 0 }
        let w = 64, h = 64
        var pixels = [UInt8](repeating: 0, count: w*h*4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var values: [Double] = []
        for y in 20..<36 {
            for x in 10..<54 {
                let i = (y*w+x)*4
                let channels = [Double(pixels[i]), Double(pixels[i+1]), Double(pixels[i+2])]
                values.append(channels.max()! - channels.min()!)
            }
        }
        return values.reduce(0,+)/Double(values.count)
    }
    private func letterboxBrightness(_ screenshot: XCUIScreenshot) -> Double {
        // Landscape screenshots can store portrait pixels with UIImage orientation
        // metadata. Normalize orientation before choosing a physical screen edge.
        let source = screenshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: source.size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: source.size))
        }
        guard let image = normalized.cgImage else { return -1 }
        var pixels = [UInt8](repeating: 0, count: 64*64*4)
        guard let context = CGContext(data: &pixels, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let xs = image.width > image.height ? 1..<3 : 24..<40
        let ys = image.width > image.height ? Array(20..<30) : Array(10..<14) + Array(50..<54)
        var samples: [Double] = []
        for y in ys {
            for x in xs {
                let i = (y*64+x)*4
                samples.append(Double(max(pixels[i], pixels[i+1], pixels[i+2])))
            }
        }
        return samples.reduce(0,+)/Double(samples.count)
    }
}
