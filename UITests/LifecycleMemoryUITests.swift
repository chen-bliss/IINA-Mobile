// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

final class LifecycleMemoryUITests: XCTestCase {
    private func launch(_ extra: [String] = [], language: String = "zh-Hans") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(\(language))"] + extra
        app.launch()
        return app
    }
    func testHomeButtonsAfterBackgroundAndOrientationChange() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout: 8))
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.orientation = .landscapeLeft
        app.activate()
        let tappable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["openSettings"].isHittable && app.buttons["openAbout"].isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [tappable], timeout: 5), .completed)
        app.buttons["openSettings"].coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["settingsTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["settingsTitle"].label, "设置")
        app.buttons["完成"].tap()
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.orientation = .portrait
        app.activate()
        let aboutReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["openAbout"])
        XCTAssertEqual(XCTWaiter.wait(for: [aboutReady], timeout: 5), .completed)
        app.buttons["openAbout"].coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["关于"].waitForExistence(timeout: 5))
    }
    func testPanelKeepsPausedVideoBoundsAndViewportUnchanged() {
        let app = launch(["--show-player-settings", "--preview-sdr"])
        let pause = app.buttons["togglePlayback"]
        XCTAssertTrue(pause.waitForExistence(timeout: 20))
        let loaded = app.staticTexts["playbackState"]
        XCTAssertTrue(loaded.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'loaded'"), object: loaded)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed)
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '暂停'"), object: pause)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 5), .completed)
        pause.tap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '播放'"), object: pause)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed)
        let surface = app.otherElements["videoSurface"]
        let before = surface.frame
        let dimensions = surface.value as? String
        app.buttons["toggleSettings"].tap()
        XCTAssertEqual(surface.frame, before)
        XCTAssertEqual(surface.value as? String, dimensions)
        app.buttons["toggleSettings"].tap()
        XCTAssertEqual(surface.frame, before)
        XCTAssertEqual(surface.value as? String, dimensions)
        XCTAssertEqual(pause.label, "播放")
    }
    func testPortraitPreviewAndSettingsButtonHitArea() {
        let app = launch(["--show-player-settings", "--preview-sdr"])
        let surface = app.otherElements["videoSurface"]
        XCTAssertTrue(app.segmentedControls["settingsTabs"].waitForExistence(timeout: 20))
        let preview = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let values = surface.label.replacingOccurrences(of: "rect=", with: "").split(separator: ",").compactMap { Double($0) }
            guard values.count == 4, values[2] > 1, values[3] > 1,
                  let dimensions = (surface.value as? String)?.split(separator: ";").first else { return false }
            let render = dimensions.replacingOccurrences(of: "render=", with: "").split(separator: ",").compactMap { Double($0) }
            guard render.count == 2, render[0] > 0 else { return false }
            let scale = render[0] / surface.frame.width
            return values[1] > 0 && (values[1] + values[3]) / scale < app.segmentedControls["settingsTabs"].frame.minY && values[3] / scale > 100
        }, object: surface)
        XCTAssertEqual(XCTWaiter.wait(for: [preview], timeout: 15), .completed, "The entire preview must fit above the settings panel: " + surface.label)
        let button = app.buttons["toggleSettings"]
        XCTAssertGreaterThanOrEqual(button.frame.width, 50)
        XCTAssertGreaterThanOrEqual(button.frame.height, 50)
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertFalse(app.segmentedControls["settingsTabs"].exists)
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.segmentedControls["settingsTabs"].exists)
    }
    func testExactEnglishSubtitleAndPictureMemoryAcrossRelaunch() {
        let app = launch(["--qa-tracks", "--show-player-settings"])
        XCTAssertTrue(app.sliders["color_contrast"].waitForExistence(timeout: 25))
        let loaded = app.staticTexts["playbackState"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'loaded'"), object: loaded)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed)
        app.sliders["color_contrast"].adjust(toNormalizedSliderPosition: 0.7)
        let contrast = app.staticTexts["value_contrast"].label
        app.segmentedControls["settingsTabs"].buttons["字幕"].tap()
        let english = app.buttons.matching(NSPredicate(format: "label CONTAINS 'English SDH'")).firstMatch
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        english.tap()
        XCTAssertEqual(english.value as? String, "已选择")
        app.buttons["closePlayer"].tap()
        app.terminate()
        app.launchArguments = ["--uitesting", "--preserve-history", "--show-player-settings", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        app.buttons["history_QA-Tracks.mkv"].tap()
        XCTAssertTrue(app.staticTexts["value_contrast"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["value_contrast"].label, contrast)
        app.segmentedControls["settingsTabs"].buttons["字幕"].tap()
        let restored = app.buttons.matching(NSPredicate(format: "label CONTAINS 'English SDH'")).firstMatch
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '已选择'"), object: restored)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 20), .completed)
        app.buttons["closePlayer"].tap()
        app.buttons["sampleHDR"].tap()
        XCTAssertEqual(app.staticTexts["value_contrast"].label, "0", "A different video must keep its own defaults.")
    }
    func testUNLanguagesAndUnsupportedLanguageFallback() {
        for (language, settings, recent) in [("en","Settings","Recently played"),("fr","Réglages","Lectures récentes"),("es","Ajustes","Reproducidos recientemente"),("ru","Настройки","Недавние видео"),("ar","الإعدادات","شُغّل مؤخرًا"),("ja","Settings","Recently played")] {
            let app = launch(language: language)
            XCTAssertTrue(app.staticTexts[recent].waitForExistence(timeout: 8), language)
            XCTAssertEqual(app.buttons["openSettings"].label, settings)
            if language == "ar" { XCTAssertLessThan(app.buttons["openAbout"].frame.minX, app.buttons["openSettings"].frame.minX) }
            app.buttons["openSettings"].tap()
            XCTAssertTrue(app.staticTexts["settingsTitle"].waitForExistence(timeout: 5), language)
            XCTAssertEqual(app.staticTexts["settingsTitle"].label, settings, language)
            app.terminate()
        }
    }
    func testManualLanguageChangesImmediatelyAndPersists() {
        let app = launch()
        app.buttons["openSettings"].tap()
        app.buttons["appLanguage"].tap()
        app.buttons["English"].tap()
        XCTAssertEqual(app.staticTexts["settingsTitle"].label, "Settings")
        app.buttons["appLanguage"].tap()
        app.buttons["العربية"].tap()
        XCTAssertEqual(app.staticTexts["settingsTitle"].label, "الإعدادات")
        app.buttons["appLanguage"].tap()
        app.buttons["English"].tap()
        app.terminate()
        app.launchArguments = ["--uitesting", "--preserve-language", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertEqual(app.buttons["openSettings"].label, "Settings")
        app.buttons["openSettings"].tap()
        app.buttons["appLanguage"].tap()
        app.buttons["Follow system"].tap()
        XCTAssertTrue(app.staticTexts["settingsTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["settingsTitle"].label, "设置")
        app.buttons["完成"].tap()
        XCTAssertEqual(app.buttons["openSettings"].label, "设置")
    }
    func testArabicLandscapeSettingsRemainOnScreen() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(["--preview-sdr", "--show-player-settings"], language: "ar")
        XCTAssertTrue(app.segmentedControls["settingsTabs"].waitForExistence(timeout: 20))
        XCUIDevice.shared.orientation = .landscapeLeft
        let tabs = app.segmentedControls["settingsTabs"]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            tabs.isHittable && tabs.frame.minX >= 0 && tabs.frame.maxX <= app.windows.firstMatch.frame.width + 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 8), .completed)
        app.buttons["toggleSettings"].tap()
        XCTAssertFalse(tabs.exists)
    }
    func testNativePictureInPictureAndBackgroundReturn() throws { try checkPictureInPicture(["--qa-pip"]) }
    func testSMBNativePictureInPictureAndBackgroundReturn() throws {
        guard ProcessInfo.processInfo.environment["IINA_SMB_QA"] == "1" else { throw XCTSkip("Requires isolated SMB fixture") }
        try checkPictureInPicture(["--qa-pip-smb"])
    }
    private func checkPictureInPicture(_ arguments: [String]) throws {
        let app = launch(arguments)
        XCTAssertTrue(app.buttons["pictureInPicture"].waitForExistence(timeout: 20))
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '暂停'"), object: app.buttons["togglePlayback"])
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 20), .completed)
        app.buttons["pictureInPicture"].tap()
        app.buttons["开启画中画"].tap()
        if app.staticTexts["这台设备不支持画中画。"].waitForExistence(timeout: 2) {
            throw XCTSkip("This simulator reports that system Picture in Picture is unsupported. Validate floating-window behavior on supported hardware.")
        }
        let active = app.buttons["pictureInPicture"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'active'"), object: active)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 45), .completed)
        let before = Int(app.buttons["returnFromPiP"].value as? String ?? "0") ?? 0
        XCUIDevice.shared.press(.home)
        // Waiting on a non-UI predicate permits background playback to advance.
        let elapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in false }, object: nil)
        _ = XCTWaiter.wait(for: [elapsed], timeout: 3)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let attachment = XCTAttachment(screenshot: springboard.screenshot())
        attachment.name = "Picture-in-Picture-on-home-screen"; attachment.lifetime = .keepAlways; add(attachment)
        app.activate()
        XCTAssertTrue(active.waitForExistence(timeout: 5))
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (Int(app.buttons["returnFromPiP"].value as? String ?? "0") ?? 0) > before + 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed, "Playback must advance while the app is on the home screen.")
        app.buttons["returnFromPiP"].tap()
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'inactive'"), object: active)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 8), .completed)
        XCTAssertFalse(app.alerts["播放提示"].exists)
    }
}
