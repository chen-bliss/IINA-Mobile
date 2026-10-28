// SPDX-License-Identifier: GPL-3.0-or-later
// Color property mapping adapted from IINA PlayerCore.setVideoEqualizer (GPLv3).
// Metal integration follows MPVKit's iOS example (see THIRD_PARTY.md).
import AVFoundation
import Combine
import Libmpv
import Metal
import UIKit

final class VideoLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if newValue.width > 1 && newValue.height > 1 { super.drawableSize = newValue } }
    }
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            // MoltenVK changes this on its rendering thread. UIKit needs the main thread.
            if Thread.isMainThread { super.wantsExtendedDynamicRangeContent = newValue }
            else { DispatchQueue.main.sync { self.wantsExtendedDynamicRangeContent = newValue } }
        }
    }
}

final class PlayerEngine: NSObject, ObservableObject {
    @Published var picture = AppPreferences.load().picture
    @Published var title = L("尚未播放")
    @Published var isPlaying = false
    @Published var isLoaded = false
    @Published var isBuffering = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var tracks: [MediaTrack] = []
    @Published var subtitleID = "auto"
    @Published var audioID = "auto"
    @Published var subtitleDelay: Double = 0
    @Published var subtitleSize: Double = 40
    @Published var speed: Double = 1
    @Published var sourceHDR = false
    @Published var outputHDR = false
    @Published var screenHeadroom: Double = 1
    @Published var videoDetails = ""
    @Published var error: String?
    @Published var lastAppliedColor = ""
    @Published var display = AppPreferences.load().display
    @Published var renderingMode = AppPreferences.load().rendering
    @Published var thermalProtectionActive = false
    var limitsRenderResolution: Bool { renderingMode == .energy || thermalProtectionActive }
    @Published var renderDimensions = CGSize.zero
    @Published var surfaceDimensions = CGSize.zero
    @Published var videoRectangle = CGRect.zero
    private var previewRegion: CGRect?

    private let worker = DispatchQueue(label: "org.iinamobile.player", qos: .userInitiated)
    private var handle: OpaquePointer?
    private let smbStreams = SMBPlaybackStream()
    private var activeDisplay = AppPreferences.load().display
    private var activeRenderingMode = AppPreferences.load().rendering
    private var activeSubtitlePreference = AppPreferences.load().subtitles
    private var thermalConstrained = false
    private var qualityRenderingOptions: [String: String] = [:]
    private let smoothRenderingOptions = ["scale": "bilinear", "dscale": "bilinear", "correct-downscaling": "no",
                                          "linear-downscaling": "no", "sigmoid-upscaling": "no", "hdr-compute-peak": "no"]
    private var resizeWork: DispatchWorkItem?
    private var requestedViewport = CGSize.zero
    private var renderLayer: VideoLayer?
    private var pendingURL: URL?
    private var currentURL: URL?
    private var scopedURLs: [URL] = []
    private var restorePosition: Double = 0
    private var restorePaused = false
    private var openedExternalSubtitles: [URL] = []
    private var rememberedSubtitle = RememberedTrack(mode: "auto")
    private var rememberedAudio = RememberedTrack(mode: "auto")
    @Published private(set) var videoSettings = VideoPlaybackSettings()
    private(set) var externalSubtitleURLs: [URL] = []

    private func rememberChanges() {
        var updated = videoSettings
        updated.picture = picture; updated.display = display; updated.rendering = renderingMode
        updated.subtitleDelay = subtitleDelay; updated.subtitleSize = subtitleSize; updated.speed = speed
        if updated != videoSettings { videoSettings = updated }
    }
    private var activeSettings = AppPreferences.load().picture
    private var activeSpeed: Double = 1
    private var activeSubtitleDelay: Double = 0
    private var activeSubtitleSize: Double = 40
    private var timer: Timer?
    private var nativePlayback: PictureInPictureSession?
    private var needsNativeRestore = false
    private var nativeOutputSuspended = false
    private var lifecycleTokens: [NSObjectProtocol] = []
    #if DEBUG
    private let playbackDiagnostics = PlaybackDiagnostics()
    private var subtitleFontLog = ""
    #endif

    override init() {
        super.init()
        let center = NotificationCenter.default
        lifecycleTokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.nativePlayback == nil { self?.setPaused(true) }
        })
        lifecycleTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setPaused(true)
        })
        lifecycleTokens.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshThermalProtection()
        })
    }

    deinit {
        timer?.invalidate()
        lifecycleTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(_ layer: VideoLayer) {
        screenHeadroom = Double(layer.delegate.flatMap { ($0 as? UIView)?.window?.screen.potentialEDRHeadroom } ?? UIScreen.main.potentialEDRHeadroom)
        let settings = picture
        worker.async { [self] in
            if let previous = renderLayer {
                guard previous !== layer else { return }
                renderLayer = layer
                if let handle {
                    var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
                    withExtendedLifetime(previous) {
                        check(mpv_set_property(handle, "wid", MPV_FORMAT_INT64, &wid), L("更新播放画面"))
                    }
                }
                return
            }
            renderLayer = layer
            activeSettings = settings
            createHandle()
            if let url = pendingURL { pendingURL = nil; loadOnWorker(url) }
        }
    }

    private func createHandle() {
        guard let renderLayer, let mpv = mpv_create() else { publishError(L("无法创建播放引擎。")); return }
        handle = mpv
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting") || ProcessInfo.processInfo.arguments.contains("--diagnose-subtitles") {
            mpv_request_log_messages(mpv, "v")
        }
        #endif
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(renderLayer).toOpaque()))
        check(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid), L("视频输出"))
        var options = [
            "vo": "gpu-next", "gpu-api": "vulkan", "gpu-context": "moltenvk",
            "hwdec": "videotoolbox", "keep-open": "yes", "idle": "yes",
            "input-default-bindings": "no", "input-vo-keyboard": "no",
            "terminal": "no", "msg-level": "all=no", "config": "no",
            "cache": "yes", "demuxer-max-bytes": "128MiB", "network-timeout": "15",
            "demuxer-readahead-secs": "30", "cache-pause-initial": "yes", "cache-pause-wait": "3",
            "sub-auto": "fuzzy", "slang": activeSubtitlePreference.languages, "alang": "zh,en",
            "target-colorspace-hint": activeSettings.hdrMode == .automatic ? "yes" : "no",
            "tone-mapping": activeSettings.toneMapping
        ]
        if let fonts = SubtitleFonts.directory {
            options["sub-fonts-dir"] = fonts.path
            options["sub-font"] = "Noto Sans CJK SC"
            options["osd-font"] = "Noto Sans CJK SC"
        }
        for (key, value) in options { check(mpv_set_option_string(mpv, key, value), key) }
        if activeSettings.hdrMode == .sdr {
            check(mpv_set_option_string(mpv, "target-trc", "srgb"), L("SDR 色彩"))
            check(mpv_set_option_string(mpv, "target-prim", "bt.709"), L("SDR 色域"))
        }
        for color in ColorControl.allCases {
            check(mpv_set_option_string(mpv, color.rawValue, String(Int(activeSettings[color]))), color.title)
        }
        let result = mpv_initialize(mpv)
        guard result >= 0 else {
            publishError(LF("播放引擎初始化失败：%@", message(result)))
            mpv_terminate_destroy(mpv); handle = nil; return
        }
        check(smbStreams.register(with: mpv), L("SMB 播放"))
        // Capture this mpv build's own defaults so returning to quality mode
        // restores every rendering option without touching HDR or color values.
        qualityRenderingOptions = smoothRenderingOptions.keys.reduce(into: [:]) { result, key in
            result[key] = string("options/\(key)")
        }
        applyRenderingMode()
        applyDisplaySettings()
        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx else { return }
            let engine = Unmanaged<PlayerEngine>.fromOpaque(ctx).takeUnretainedValue()
            engine.worker.async { [weak engine] in engine?.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func open(_ url: URL, subtitles: [URL] = [], startAt: Double = 0, settings saved: VideoPlaybackSettings? = nil) {
        let defaults = AppPreferences.load()
        let settings = saved ?? VideoPlaybackSettings(defaults: defaults)
        videoSettings = settings; externalSubtitleURLs = subtitles
        picture = settings.picture; display = settings.display; renderingMode = settings.rendering
        subtitleSize = settings.subtitleSize; subtitleDelay = settings.subtitleDelay; speed = settings.speed
        subtitleID = settings.subtitle.mode == "no" ? "no" : "auto"
        position = max(0, startAt); duration = 0
        setControlsVisible(true)
        refreshThermalProtection()
        error = nil
        isLoaded = false
        isBuffering = true
        sourceHDR = false; outputHDR = false; tracks = []; videoDetails = ""
        title = MediaPrivacy.safeTitle(url)
        UIApplication.shared.isIdleTimerDisabled = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { self.error = LF("无法启动音频：%@", error.localizedDescription) }
        for resource in [url] + subtitles where resource.isFileURL {
            if resource.startAccessingSecurityScopedResource() { scopedURLs.append(resource) }
        }
        worker.async { [self] in
            let recreate = handle != nil && activeSettings.hdrMode != settings.picture.hdrMode
            activeSettings = settings.picture; activeDisplay = settings.display; activeRenderingMode = settings.rendering
            activeSubtitlePreference = defaults.subtitles; activeSubtitleSize = settings.subtitleSize; activeSubtitleDelay = settings.subtitleDelay
            activeSpeed = settings.speed
            rememberedSubtitle = settings.subtitle; rememberedAudio = settings.audio
            restorePosition = max(0, startAt); restorePaused = false
            openedExternalSubtitles = subtitles
            smbStreams.status.reset()
            if recreate { destroyHandle(); createHandle() }
            if handle != nil {
                for color in ColorControl.allCases { setString(color.rawValue, String(Int(activeSettings[color]))) }
                setString("tone-mapping", activeSettings.toneMapping)
                setString("slang", activeSubtitlePreference.languages)
                applyRenderingMode(); applyDisplaySettings()
            }
            if handle == nil { pendingURL = url }
            else { loadOnWorker(url) }
        }
    }

    private func loadOnWorker(_ url: URL) {
        currentURL = url
        setString("pause", "no")
        command(["loadfile", smbStreams.mediaPath(url), "replace"])
    }

    func close() {
        nativePlayback?.stop()
        needsNativeRestore = false
        timer?.invalidate(); timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        isPlaying = false; isLoaded = false; isBuffering = false
        let scopes = scopedURLs; scopedURLs = []
        worker.async { [self] in
            destroyHandle()
            nativeOutputSuspended = false; previewRegion = nil
            smbStreams.reset()
            renderLayer = nil; currentURL = nil; pendingURL = nil; openedExternalSubtitles = []
            DispatchQueue.main.async { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
        }
    }

    func setDisplay(fit: VideoFitMode? = nil, aspect: VideoAspect? = nil) {
        if let fit { display.fit = fit }
        if let aspect { display.aspect = aspect }
        rememberChanges()
        let settings = display
        worker.async { [self] in activeDisplay = settings; applyDisplaySettings() }
    }

    func setRenderingMode(_ mode: RenderingMode) {
        renderingMode = mode
        rememberChanges()
        worker.async { [self] in activeRenderingMode = mode; applyRenderingMode() }
    }
    private func applyRenderingMode() {
        let options = activeRenderingMode != .quality || thermalConstrained ? smoothRenderingOptions : qualityRenderingOptions
        for (key, value) in options { setString(key, value) }
    }
    func setControlsVisible(_ visible: Bool) {
        let interval = visible ? 0.5 : 2.0
        if timer?.timeInterval == interval { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = interval * 0.2
    }
    private func refreshThermalProtection() {
        let state = ProcessInfo.processInfo.thermalState
        let constrained = AppPreferences.load().adaptToHeat && state != .nominal
        thermalProtectionActive = constrained
        worker.async { [self] in thermalConstrained = constrained; if handle != nil { applyRenderingMode() } }
    }

    func setPreviewRegion(_ rect: CGRect, canvas: CGSize) {
        guard canvas.width > 1, canvas.height > 1 else { return }
        let full = CGRect(origin: .zero, size: canvas)
        let clipped = rect.intersection(full)
        guard !clipped.isEmpty else { return }
        let normalized: CGRect? = rect == full ? nil : CGRect(x: clipped.minX / canvas.width, y: clipped.minY / canvas.height,
                                                             width: clipped.width / canvas.width, height: clipped.height / canvas.height)
        worker.async { [self] in
            guard previewRegion != normalized else { return }
            previewRegion = normalized
            applyDisplaySettings()
        }
    }
    private func applyDisplaySettings() {
        let preview = previewRegion != nil
        setString("keepaspect", !preview && activeDisplay.fit == .stretch ? "no" : "yes")
        setString("panscan", !preview && activeDisplay.fit == .fill ? "1" : "0")
        let region = previewRegion ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        setString("video-margin-ratio-left", String(Double(region.minX)))
        setString("video-margin-ratio-right", String(Double(1 - region.maxX)))
        setString("video-margin-ratio-top", String(Double(region.minY)))
        setString("video-margin-ratio-bottom", String(Double(1 - region.maxY)))
        setString("sub-use-margins", preview ? "no" : "yes")
        setString("video-aspect-override", activeDisplay.aspect.mpvValue)
    }

    func beginNativePlayback(_ session: PictureInPictureSession) {
        nativePlayback = session
        worker.async { [self] in nativeOutputSuspended = true; setString("pause", "yes"); setString("vo", "null") }
    }
    func endNativePlayback(position: Double, resume: Bool) {
        nativePlayback = nil
        self.position = position
        let foreground = UIApplication.shared.applicationState == .active
        needsNativeRestore = !foreground
        worker.async { [self] in
            if foreground { nativeOutputSuspended = false; setString("vo", "gpu-next"); applyDisplaySettings() }
            command(["seek", String(max(0, position)), "absolute+exact"])
            setString("pause", resume && foreground ? "no" : "yes")
        }
    }
    func refreshAfterForeground() {
        if needsNativeRestore {
            needsNativeRestore = false
            worker.async { [self] in nativeOutputSuspended = false; setString("vo", "gpu-next"); applyDisplaySettings() }
        }
        setControlsVisible(true)
        refreshThermalProtection()
        worker.async { [self] in refreshViewportIfNeeded() }
    }

    func viewportDidResize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        if surfaceDimensions != size { surfaceDimensions = size }
        worker.async { [self] in
            requestedViewport = size
            resizeWork?.cancel()
            let task = DispatchWorkItem { [weak self] in self?.refreshViewportIfNeeded() }
            resizeWork = task
            worker.asyncAfter(deadline: .now() + 0.15, execute: task)
        }
    }

    private func refreshViewportIfNeeded() {
        guard !nativeOutputSuspended, handle != nil, currentURL != nil, double("video-params/w") > 0 else { return }
        let width = double("osd-dimensions/w"), height = double("osd-dimensions/h")
        guard abs(width - requestedViewport.width) > 2 || abs(height - requestedViewport.height) > 2 else { return }
        // The bundled MoltenVK context has no resize event handler. Recreate only the
        // video output so its reconfig callback reads the layer's new drawableSize.
        // Demuxing, the SMB stream, audio, and the selected tracks remain in the player.
        setString("vo", "null")
        setString("vo", "gpu-next")
        applyDisplaySettings()
    }

    private func destroyHandle() {
        guard let handle else { return }
        mpv_set_wakeup_callback(handle, nil, nil)
        mpv_terminate_destroy(handle)
        self.handle = nil
    }

    func setColor(_ control: ColorControl, value: Double) {
        picture[control] = value.rounded()
        rememberChanges()
        let applied = picture[control]
        worker.async { [self] in
            activeSettings[control] = applied
            // Same mpv properties and -100...100 range as IINA's VideoEqualizerType.
            setString(control.rawValue, String(Int(applied)))
            let rawReadback = string(control.rawValue) ?? ""
            let readback = Double(rawReadback).map { String(Int($0.rounded())) } ?? rawReadback
            DispatchQueue.main.async { self.lastAppliedColor = "\(control.rawValue)=\(readback)" }
        }
    }
    func resetColors() { for color in ColorControl.allCases { setColor(color, value: 0) } }
    func setHDRMode(_ mode: HDRMode) {
        guard picture.hdrMode != mode else { return }
        picture.hdrMode = mode
        rememberChanges()
        let settings = picture
        isBuffering = true
        worker.async { [self] in
            restorePosition = double("time-pos"); restorePaused = flag("pause")
            activeSettings = settings
            guard renderLayer != nil else {
                DispatchQueue.main.async { self.isBuffering = false }
                return
            }
            let url = currentURL
            // target-colorspace-hint is init-only. Recreate instead of pretending a live toggle worked.
            destroyHandle(); createHandle()
            if let url { loadOnWorker(url) }
        }
    }
    func setToneMapping(_ algorithm: String) {
        guard ["auto", "bt.2390", "hable", "reinhard", "clip"].contains(algorithm) else { return }
        picture.toneMapping = algorithm
        rememberChanges()
        worker.async { [self] in activeSettings.toneMapping = algorithm; setString("tone-mapping", algorithm) }
    }
    func togglePause() {
        if let nativePlayback {
            if nativePlayback.player.rate == 0 { nativePlayback.player.playImmediately(atRate: Float(speed)) }
            else { nativePlayback.player.pause() }
            return
        }
        worker.async { [self] in
            if flag("eof-reached") { command(["seek", "0", "absolute"]); setString("pause", "no") }
            else { setString("pause", flag("pause") ? "no" : "yes") }
        }
    }
    func setPaused(_ paused: Bool) { if let nativePlayback { if paused { nativePlayback.player.pause() }; return }; worker.async { [self] in setString("pause", paused ? "yes" : "no") } }
    func seek(_ time: Double) { if let nativePlayback { nativePlayback.player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600)); return }; worker.async { [self] in command(["seek", String(max(0, time)), "absolute+exact"]) } }
    func skip(_ seconds: Double) { if nativePlayback != nil { seek(position + seconds); return }; worker.async { [self] in command(["seek", String(seconds), "relative"]) } }
    func setSpeed(_ value: Double) {
        speed = value
        if let nativePlayback, nativePlayback.player.rate != 0 { nativePlayback.player.rate = Float(value) }
        rememberChanges()
        worker.async { [self] in activeSpeed = value; setString("speed", String(value)) }
    }
    func selectSubtitle(_ id: String) {
        subtitleID = id
        let selection = RememberedTrack.capture(id, tracks: tracks, type: "sub")
        videoSettings.subtitle = selection
        worker.async { [self] in rememberedSubtitle = selection; setString("sid", id) }
    }
    func selectAudio(_ id: String) {
        audioID = id
        let selection = RememberedTrack.capture(id, tracks: tracks, type: "audio")
        videoSettings.audio = selection
        worker.async { [self] in rememberedAudio = selection; setString("aid", id) }
    }
    func setSubtitleDelay(_ value: Double) {
        subtitleDelay = value
        rememberChanges()
        worker.async { [self] in activeSubtitleDelay = value; setString("sub-delay", String(value)) }
    }
    func setSubtitleSize(_ value: Double) {
        subtitleSize = value
        rememberChanges()
        worker.async { [self] in activeSubtitleSize = value; setString("sub-font-size", String(value)) }
    }
    func addSubtitle(_ url: URL) {
        externalSubtitleURLs.append(url)
        if url.isFileURL && url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        worker.async { [self] in
            openedExternalSubtitles.append(url)
            command(["sub-add", smbStreams.mediaPath(url), "select"])
            let id = string("sid") ?? "auto"
            let all = MediaTrack.decode(string("track-list") ?? "[]")
            rememberedSubtitle = .capture(id, tracks: all, type: "sub")
            let selection = rememberedSubtitle
            DispatchQueue.main.async { self.videoSettings.subtitle = selection }
        }
    }
    func screenshot() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let target = directory.appendingPathComponent("IINA-\(Int(Date().timeIntervalSince1970)).png")
        worker.async { [self] in command(["screenshot-to-file", target.path, "subtitles"]) }
    }

    private func drainEvents() {
        guard let handle else { return }
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            #if DEBUG
            case MPV_EVENT_LOG_MESSAGE:
                if let data = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self) {
                    let prefix = String(cString: data.pointee.prefix)
                    let message = String(cString: data.pointee.text)
                    if (message.lowercased().contains("font") || message.contains("Glyph")) && subtitleFontLog.count < 30_000 {
                        subtitleFontLog += "\(prefix): \(message)"
                        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Subtitle-Fonts.txt")
                        try? subtitleFontLog.write(to: file, atomically: true, encoding: .utf8)
                    }
                }
            #endif
            case MPV_EVENT_FILE_LOADED:
                if restorePosition > 0 { command(["seek", String(restorePosition), "absolute+exact"]) }
                setString("pause", restorePaused ? "yes" : "no")
                for url in openedExternalSubtitles {
                    command(["sub-add", smbStreams.mediaPath(url), "auto"])
                }
                let loadedTracks = MediaTrack.decode(string("track-list") ?? "[]")
                setString("sid", rememberedSubtitle.resolve(in: loadedTracks, type: "sub"))
                setString("aid", rememberedAudio.resolve(in: loadedTracks, type: "audio"))
                setString("speed", String(activeSpeed))
                setString("sub-delay", String(activeSubtitleDelay))
                setString("sub-font-size", String(activeSubtitleSize))
                restorePosition = 0
                refreshViewportIfNeeded()
                DispatchQueue.main.async { self.isLoaded = true; self.isBuffering = false }
            case MPV_EVENT_END_FILE:
                if let data = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self), data.pointee.error < 0 {
                    let code = data.pointee.error
                    publishError(smbStreams.status.latest?.localizedDescription ?? LF("无法播放视频：%@。请检查文件格式、服务器权限和网络连接。", message(code)))
                }
                DispatchQueue.main.async { self.isBuffering = false }
            default: break
            }
        }
    }

    private func poll() {
        if let nativePlayback {
            let value = nativePlayback.player.currentTime().seconds
            if value.isFinite { position = value }
            isPlaying = nativePlayback.player.rate != 0
            isBuffering = nativePlayback.preparing || nativePlayback.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            return
        }
        worker.async { [weak self] in
            guard let self, handle != nil else { return }
            #if DEBUG
            playbackDiagnostics.record(read: string)
            #endif
            let pos = double("time-pos"), length = double("duration")
            let playing = !flag("pause") && !flag("idle-active") && !flag("eof-reached")
            let buffering = flag("paused-for-cache")
            let allTracks = MediaTrack.decode(string("track-list") ?? "[]")
            let sid = string("sid") ?? "auto", aid = string("aid") ?? "auto"
            let gamma = string("video-params/gamma") ?? ""
            let primaries = string("video-params/primaries") ?? ""
            let width = Int(double("video-params/w")), height = Int(double("video-params/h"))
            let codec = string("video-codec") ?? ""
            let dimensions = CGSize(width: double("osd-dimensions/w"), height: double("osd-dimensions/h"))
            let rectangle = CGRect(x: double("osd-dimensions/ml"), y: double("osd-dimensions/mt"),
                                   width: max(0, dimensions.width - double("osd-dimensions/ml") - double("osd-dimensions/mr")),
                                   height: max(0, dimensions.height - double("osd-dimensions/mt") - double("osd-dimensions/mb")))
            let outputLayer = renderLayer
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.position != pos { self.position = pos }
                if self.duration != length { self.duration = length }
                if self.isPlaying != playing { self.isPlaying = playing }
                if self.isLoaded && self.isBuffering != buffering { self.isBuffering = buffering }
                if self.tracks != allTracks { self.tracks = allTracks }
                if self.subtitleID != sid { self.subtitleID = sid }
                if self.audioID != aid { self.audioID = aid }
                let sourceHDR = ["pq", "hlg"].contains(gamma)
                let outputHDR = outputLayer?.wantsExtendedDynamicRangeContent ?? false
                let headroom = Double(UIScreen.main.potentialEDRHeadroom)
                let details = width > 0 ? "\(width) × \(height) · \(codec) · \(primaries) · \(gamma)" : ""
                if self.sourceHDR != sourceHDR { self.sourceHDR = sourceHDR }
                if self.outputHDR != outputHDR { self.outputHDR = outputHDR }
                if self.screenHeadroom != headroom { self.screenHeadroom = headroom }
                if self.videoDetails != details { self.videoDetails = details }
                if self.renderDimensions != dimensions { self.renderDimensions = dimensions }
                if self.videoRectangle != rectangle { self.videoRectangle = rectangle }
            }
        }
    }

    private func command(_ args: [String]) {
        guard let handle else { return }
        let allocated = args.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = allocated.map { $0.map { UnsafePointer($0) } } + [nil]
        check(mpv_command(handle, &pointers), L("播放命令"))
    }
    private func setString(_ key: String, _ value: String) {
        guard let handle else { return }
        check(mpv_set_property_string(handle, key, value), key)
    }
    private func string(_ key: String) -> String? {
        guard let handle, let value = mpv_get_property_string(handle, key) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }
    private func double(_ key: String) -> Double {
        guard let handle else { return 0 }
        var value: Double = 0
        guard mpv_get_property(handle, key, MPV_FORMAT_DOUBLE, &value) >= 0, value.isFinite else { return 0 }
        return value
    }
    private func flag(_ key: String) -> Bool {
        guard let handle else { return false }
        var value: Int32 = 0
        return mpv_get_property(handle, key, MPV_FORMAT_FLAG, &value) >= 0 && value != 0
    }
    private func check(_ code: Int32, _ operation: String) {
        if code < 0 { publishError("\(operation)：\(message(code))") }
    }
    private func message(_ code: Int32) -> String { String(cString: mpv_error_string(code)) }
    private func publishError(_ text: String) {
        #if DEBUG
        NSLog("IINAMobile: %@", text)
        #endif
        DispatchQueue.main.async { [weak self] in self?.error = text }
    }
}

final class PlayerSurfaceView: UIView {
    let videoLayer = VideoLayer()
    var onResize: ((CGSize) -> Void)?
    var onSafeAreaChange: ((UIEdgeInsets) -> Void)?
    private var previousSafeArea = UIEdgeInsets.zero
    private var previousDrawableSize = CGSize.zero
    var constrainResolution = false { didSet { if oldValue != constrainResolution { setNeedsLayout() } } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        videoLayer.device = MTLCreateSystemDefaultDevice()
        videoLayer.pixelFormat = .bgra8Unorm
        videoLayer.framebufferOnly = true
        videoLayer.isOpaque = true
        videoLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let safe = window?.safeAreaInsets ?? safeAreaInsets
        if safe != previousSafeArea {
            previousSafeArea = safe
            DispatchQueue.main.async { [weak self] in self?.onSafeAreaChange?(safe) }
        }
        let nativeScale = window?.screen.nativeScale ?? traitCollection.displayScale
        let scale = RenderResolution.scale(size: bounds.size, nativeScale: nativeScale, constrained: constrainResolution)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        videoLayer.contentsScale = scale
        videoLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        CATransaction.commit()
        if videoLayer.drawableSize != previousDrawableSize {
            previousDrawableSize = videoLayer.drawableSize
            onResize?(previousDrawableSize)
        }
    }
}
