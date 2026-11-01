// SPDX-License-Identifier: GPL-3.0-or-later
import AVKit
import Network
import Libmpv
import CryptoKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

// AVFoundation requests byte ranges directly. Credentials never appear in the
// asset URL, and the complete SMB file is never downloaded into memory.
final class SMBAssetLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let source: URL
    let queue = DispatchQueue(label: "org.iinamobile.pip.smb", qos: .userInitiated)
    private let lock = NSLock()
    private var file: OpaquePointer?
    private var stopped = false
    init(source: URL) { self.source = source }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        queue.async { [self] in serve(request) }
        return true
    }
    private func serve(_ request: AVAssetResourceLoadingRequest) {
        guard !request.isCancelled else { return }
        lock.lock(); let isStopped = stopped; lock.unlock()
        guard !isStopped else { request.finishLoading(with: URLError(.cancelled)); return }
        do {
            if file == nil {
                guard let c = URLComponents(url: source, resolvingAgainstBaseURL: false), let host = c.host else { throw URLError(.badURL) }
                let parts = c.path.split(separator: "/").map(String.init)
                guard parts.count > 1 else { throw URLError(.badURL) }
                let raw = (c.user ?? "").split(separator: ";", maxSplits: 1).map(String.init)
                let login = SMBLogin(username: raw.last ?? "", domain: raw.count > 1 ? raw[0] : "")
                let opened = iina_smb_open(host + (c.port.map { ":\($0)" } ?? ""), parts[0], parts.dropFirst().joined(separator: "/"), login.domain, login.username, c.password ?? "")
                guard let opened else { throw SMBFailure.current() }
                lock.lock(); file = opened; let cancelled = stopped; lock.unlock()
                if cancelled { throw URLError(.cancelled) }
            }
            guard let file else { throw URLError(.cannotOpenFile) }
            let size = iina_smb_size(file)
            guard size >= 0 else { throw SMBFailure.current() }
            if let info = request.contentInformationRequest {
                info.contentType = (UTType(filenameExtension: source.pathExtension) ?? .mpeg4Movie).identifier
                info.contentLength = size
                info.isByteRangeAccessSupported = true
            }
            if let data = request.dataRequest {
                let offset = max(data.requestedOffset, data.currentOffset)
                let end = data.requestsAllDataToEndOfResource ? size : min(size, data.requestedOffset + Int64(data.requestedLength))
                guard offset >= 0, offset <= size, iina_smb_seek(file, offset) == offset else { throw URLError(.badServerResponse) }
                var remaining = min(max(0, end - offset), 512 * 1024)
                var buffer = [CChar](repeating: 0, count: 256 * 1024)
                while remaining > 0 && !request.isCancelled {
                    lock.lock(); let cancelled = stopped; lock.unlock()
                    if cancelled { throw URLError(.cancelled) }
                    let count = iina_smb_read(file, &buffer, UInt64(min(remaining, Int64(buffer.count))))
                    guard count > 0 else { throw SMBFailure.current() }
                    data.respond(with: Data(bytes: buffer, count: Int(count)))
                    remaining -= count
                }
            }
            if !request.isCancelled {
                if let data = request.dataRequest {
                    let end = data.requestsAllDataToEndOfResource ? size : min(size, data.requestedOffset + Int64(data.requestedLength))
                    if data.currentOffset < end { queue.async { [self] in serve(request) }; return }
                }
                request.finishLoading()
            }
        } catch { if !request.isCancelled { request.finishLoading(with: error) } }
    }
    func stop() {
        lock.lock(); stopped = true; if let file { iina_smb_cancel(file) }; lock.unlock()
        queue.async { [self] in
            lock.lock(); let closing = file; file = nil; lock.unlock()
            if let closing { iina_smb_close(closing) }
        }
    }
}

final class PictureInPictureSession: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published private(set) var routing = false
    @Published private(set) var active = false
    @Published private(set) var preparing = false
    @Published private(set) var airPlayMode = false
    @Published private(set) var externalPlaybackActive = false
    @Published private(set) var wantsPlayback = false
    @Published private(set) var convertingForAirPlay = false
    @Published private(set) var conversionProgress: Double?
    @Published private(set) var checkingConversionCache = false
    let player = AVPlayer()
    private weak var engine: PlayerEngine?
    private var loader: SMBAssetLoader?
    private var httpBridge: SMBHTTPBridge?
    private var transcoder: AirPlayTranscoder?
    private var convertedURL: URL?
    private var controller: AVPictureInPictureController?
    private var statusObservation: NSKeyValueObservation?
    private var externalPlaybackObservation: NSKeyValueObservation?
    private var loopObserver: Any?
    private var task: Task<Void, Never>?
    private var restoredInterface = false
    private var initialPosition: Double = 0
    private var initialPlaying = false
    private var positioned = false
    private var initialSpeed: Float = 1

    override init() {
        super.init()
        externalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            DispatchQueue.main.async {
                guard let self else { return }
                self.externalPlaybackActive = active
                if active && self.airPlayMode && self.wantsPlayback && !self.preparing {
                    self.player.play()
                }
            }
        }
    }

    private func diagnostic(_ message: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--uitesting") || ProcessInfo.processInfo.arguments.contains("--pip-diagnostics") else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("PiP-QA.txt")
        let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (previous + message + "\n").write(to: url, atomically: true, encoding: .utf8)
        #endif
    }
    static func supports(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if url.pathExtension.lowercased() == "m3u8" { return ["http", "https"].contains(scheme) }
        return ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) &&
            (url.isFileURL || ["smb", "http", "https"].contains(scheme))
    }
    func begin(url: URL, engine: PlayerEngine, airPlay: Bool = false) {
        guard !routing else { controller?.stopPictureInPicture(); return }
        diagnostic("request; systemSupported=\(AVPictureInPictureController.isPictureInPictureSupported())")
        guard airPlay || AVPictureInPictureController.isPictureInPictureSupported() else { engine.error = L("这台设备不支持画中画。"); return }
        let scheme = url.scheme?.lowercased() ?? ""
        let airPlayCandidate = (url.isFileURL || ["smb", "http", "https"].contains(scheme)) && !(scheme == "smb" && url.pathExtension.lowercased() == "m3u8")
        guard airPlay ? airPlayCandidate : Self.supports(url) else { engine.error = L("此视频来源暂不支持当前播放方式。"); return }
        self.engine = engine
        airPlayMode = airPlay
        diagnostic("begin; supported=true")
        initialPosition = engine.position; initialPlaying = engine.isPlaying; initialSpeed = Float(engine.speed)
        wantsPlayback = initialPlaying
        restoredInterface = false; positioned = false
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        preparing = true; routing = true
        engine.beginNativePlayback(self)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let asset: AVURLAsset
                if airPlay, url.pathExtension.lowercased() == "mkv" {
                    let conversion = AirPlayTranscoder(); transcoder = conversion
                    convertingForAirPlay = true; conversionProgress = nil; checkingConversionCache = true
                    let selectedSubtitle = RememberedTrack.capture(engine.subtitleID, tracks: engine.tracks, type: "sub")
                    let subtitle = selectedSubtitle.mode == "auto" ? engine.videoSettings.subtitle : selectedSubtitle
                    let subtitles = engine.externalSubtitleURLs
                    let subtitleDelay = engine.subtitleDelay, subtitleSize = engine.subtitleSize
                    let audioID = engine.audioID
                    let cache = AirPlayConversionCache()
                    let key = try await Task.detached(priority: .userInitiated) {
                        try cache.key(source: url, audioID: audioID, subtitle: subtitle, externalSubtitles: subtitles,
                                      subtitleDelay: subtitleDelay, subtitleSize: subtitleSize)
                    }.value
                    try Task.checkCancellation()
                    let cached = try key.map { try cache.url(for: $0) }
                    let reusable: URL?
                    if let key { reusable = try await cache.reusableURL(for: key) } else { reusable = nil }
                    try Task.checkCancellation()
                    checkingConversionCache = false
                    let output: URL
                    if let reusable {
                        output = reusable
                    } else {
                        let directory = try cache.directory()
                        let partial = directory.appendingPathComponent("partial-\(UUID().uuidString).mp4")
                        convertedURL = partial
                        try await conversion.convert(source: url, output: partial, audioID: audioID,
                                                     subtitle: subtitle, externalSubtitles: subtitles,
                                                     subtitleDelay: subtitleDelay, subtitleSize: subtitleSize) { [weak self, weak conversion] fraction in
                            DispatchQueue.main.async {
                                guard let self, let conversion, self.transcoder === conversion, self.convertingForAirPlay else { return }
                                self.conversionProgress = fraction
                            }
                        }
                        try Task.checkCancellation()
                        if let key, let cached {
                            let current = try await Task.detached(priority: .userInitiated) {
                                try cache.key(source: url, audioID: audioID, subtitle: subtitle, externalSubtitles: subtitles,
                                              subtitleDelay: subtitleDelay, subtitleSize: subtitleSize)
                            }.value
                            try Task.checkCancellation()
                            guard current == key else { throw NSError(domain: "AirPlayConversion", code: 3, userInfo: [NSLocalizedDescriptionKey: L("转换期间原视频或字幕发生变化，请重试。")]) }
                            if FileManager.default.fileExists(atPath: cached.path) { try FileManager.default.removeItem(at: cached) }
                            try FileManager.default.moveItem(at: partial, to: cached)
                            convertedURL = nil
                            output = cached
                        } else { output = partial }
                    }
                    convertingForAirPlay = false
                    asset = AVURLAsset(url: output)
                } else if url.scheme?.lowercased() == "smb", airPlay {
                    let bridge = SMBHTTPBridge(source: url); self.httpBridge = bridge
                    let bridgeURL = try await bridge.start()
                    try Task.checkCancellation()
                    asset = AVURLAsset(url: bridgeURL)
                } else if url.scheme?.lowercased() == "smb" {
                    let loader = SMBAssetLoader(source: url); self.loader = loader
                    asset = AVURLAsset(url: URL(string: "iinapip://\(UUID().uuidString)/video.\(url.pathExtension)")!)
                    asset.resourceLoader.setDelegate(loader, queue: loader.queue)
                } else { asset = AVURLAsset(url: url) }
                let item = AVPlayerItem(asset: asset)
                player.replaceCurrentItem(with: item)
                statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    if item.status == .failed { DispatchQueue.main.async { self?.fail(L("视频播放失败，已返回主播放器。")) } }
                }
                for tick in 0..<300 {
                    if tick % 20 == 0 { diagnostic("prepare; status=\(item.status.rawValue); controller=\(controller != nil)") }
                    try Task.checkCancellation()
                    if item.status == .failed { throw item.error ?? URLError(.cannotDecodeContentData) }
                    if item.status == .readyToPlay, airPlay || controller != nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard item.status == .readyToPlay else { throw URLError(.timedOut) }
                await player.seek(to: CMTime(seconds: initialPosition, preferredTimescale: 600), toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600))
                positioned = true
                updateLoop(a: engine.loopA, b: engine.loopB)
                await applySelection(asset: asset, item: item, settings: engine.videoSettings)
                player.defaultRate = initialSpeed
                if wantsPlayback { player.play() }
                if airPlay { preparing = false; return }
                for tick in 0..<80 {
                    if tick % 20 == 0 { diagnostic("ready; possible=\(controller?.isPictureInPicturePossible ?? false); rate=\(player.rate)") }
                    try Task.checkCancellation()
                    if controller?.isPictureInPicturePossible == true {
                        controller?.startPictureInPicture()
                        try await Task.sleep(for: .seconds(5))
                        if !active { fail(L("无法开启画中画，请确认文件编码受系统支持后重试。")) }
                        return
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw URLError(.timedOut)
            } catch is CancellationError { }
            catch { fail(airPlay ? LF("无法准备 AirPlay：%@", error.localizedDescription) : L("无法开启画中画，请确认文件编码受系统支持后重试。")) }
        }
    }
    private func applySelection(asset: AVAsset, item: AVPlayerItem, settings: VideoPlaybackSettings) async {
        for (type, selection) in [(AVMediaCharacteristic.legible, settings.subtitle), (.audible, settings.audio)] {
            guard let group = try? await asset.loadMediaSelectionGroup(for: type) else { continue }
            if selection.mode == "no", group.allowsEmptySelection { item.select(nil, in: group) }
            else if selection.mode == "track" {
                // System and mpv track IDs differ; only select a unique metadata match.
                let exact = group.options.filter { $0.displayName == selection.title && ($0.extendedLanguageTag == selection.language || $0.locale?.language.languageCode?.identifier == selection.language) }
                if exact.count == 1 { item.select(exact[0], in: group) }
                else if type == .legible, group.allowsEmptySelection { item.select(nil, in: group) }
            }
        }
    }
    func setPlaybackWanted(_ wanted: Bool, speed: Double) {
        wantsPlayback = wanted
        player.defaultRate = Float(speed)
        if wanted { player.play() } else { player.pause() }
    }
    func updateLoop(a: Double?, b: Double?) {
        if let loopObserver { player.removeTimeObserver(loopObserver); self.loopObserver = nil }
        guard let a, let b, b > a else { return }
        let boundary = CMTime(seconds: b, preferredTimescale: 600)
        loopObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: boundary)], queue: .main) { [weak self] in
            guard let self, self.routing else { return }
            self.player.seek(to: CMTime(seconds: a, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
    func attach(_ layer: AVPlayerLayer) {
        diagnostic("attached; layer=\(layer.bounds.size)")
        layer.player = player
        controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        diagnostic("active")
        preparing = false; active = true
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        fail(L("无法开启画中画，请确认文件编码受系统支持后重试。"))
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        restoredInterface = true
        completionHandler(true)
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        finish(resume: restoredInterface && player.rate != 0)
    }
    func returnToPlayer() {
        let resume = airPlayMode ? wantsPlayback : player.timeControlStatus != .paused
        controller?.delegate = nil
        controller?.stopPictureInPicture()
        finish(resume: resume)
    }
    func stop() {
        controller?.delegate = nil
        controller?.stopPictureInPicture()
        finish(resume: false)
    }
    private func fail(_ message: String) {
        guard routing else { return }
        diagnostic("failed; " + message)
        let target = engine
        finish(resume: initialPlaying)
        target?.error = message
    }
    private func finish(resume: Bool) {
        guard routing else { return }
        let seconds = player.currentTime().seconds
        let position = positioned && seconds.isFinite ? seconds : initialPosition
        task?.cancel(); task = nil; statusObservation = nil
        if let loopObserver { player.removeTimeObserver(loopObserver); self.loopObserver = nil }
        controller?.delegate = nil; controller = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        loader?.stop(); loader = nil
        httpBridge?.stop(); httpBridge = nil
        transcoder?.cancel(); transcoder = nil
        if let convertedURL { try? FileManager.default.removeItem(at: convertedURL); self.convertedURL = nil }
        convertingForAirPlay = false; conversionProgress = nil; checkingConversionCache = false
        preparing = false; active = false; routing = false; airPlayMode = false
        engine?.endNativePlayback(position: position, resume: resume)
        engine = nil
    }
}

struct PictureInPictureSurface: UIViewRepresentable {
    let session: PictureInPictureSession
    func makeUIView(context: Context) -> NativeVideoView {
        let view = NativeVideoView()
        session.attach(view.playerLayer)
        return view
    }
    func updateUIView(_ view: NativeVideoView, context: Context) { }
}
final class NativeVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct AirPlayPicker: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = .systemTeal
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) { }
}

// A temporary, token-protected HTTP bridge gives an AirPlay receiver a normal
// byte-range URL without exposing SMB credentials in the URL.
final class SMBHTTPBridge {
    private let source: URL
    private let token = UUID().uuidString + UUID().uuidString
    private let queue = DispatchQueue(label: "org.iinamobile.airplay.http", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private enum SourceFile { case smb(OpaquePointer), local(FileHandle) }
    private var files: [UUID: SourceFile] = [:]
    private var stopped = false
    init(source: URL) { self.source = source }

    func start() async throws -> URL {
        guard let address = Self.wifiAddress() else { throw URLError(.notConnectedToInternet) }
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            var completed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !completed else { return }
                switch state {
                case .ready:
                    guard let self, let port = listener.port else { completed = true; continuation.resume(throwing: URLError(.cannotConnectToHost)); return }
                    completed = true
                    continuation.resume(returning: URL(string: "http://\(address):\(port.rawValue)/\(self.token)/video.\(self.source.pathExtension)")!)
                case .failed(let error): completed = true; continuation.resume(throwing: error)
                case .cancelled: completed = true; continuation.resume(throwing: URLError(.cancelled))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        receiveHeader(connection, id: id, accumulated: Data())
    }
    private func receiveHeader(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            var bytes = accumulated; if let data { bytes.append(data) }
            guard bytes.count <= 16384, error == nil else { self.finish(id); return }
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { self.finish(id) } else { self.receiveHeader(connection, id: id, accumulated: bytes) }; return
            }
            guard let header = String(data: bytes[..<end.lowerBound], encoding: .utf8) else { self.finish(id); return }
            self.respond(header, connection: connection, id: id)
        }
    }
    private func respond(_ header: String, connection: NWConnection, id: UUID) {
        let lines = header.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2, ["GET", "HEAD"].contains(String(first[0])), first[1] == "/\(token)/video.\(source.pathExtension)" else { finish(id); return }
        let size: Int64
        if source.isFileURL {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
                  let length = attributes[.size] as? NSNumber,
                  let handle = try? FileHandle(forReadingFrom: source) else { finish(id); return }
            size = length.int64Value; files[id] = .local(handle)
        } else {
            guard let c = URLComponents(url: source, resolvingAgainstBaseURL: false), c.scheme?.lowercased() == "smb", let host = c.host else { finish(id); return }
            let parts = c.path.split(separator: "/").map(String.init)
            guard parts.count > 1 else { finish(id); return }
            let raw = (c.user ?? "").split(separator: ";", maxSplits: 1).map(String.init)
            let login = SMBLogin(username: raw.last ?? "", domain: raw.count > 1 ? raw[0] : "")
            guard let file = iina_smb_open(host + (c.port.map { ":\($0)" } ?? ""), parts[0], parts.dropFirst().joined(separator: "/"), login.domain, login.username, c.password ?? "") else { finish(id); return }
            size = iina_smb_size(file); files[id] = .smb(file)
        }
        guard size > 0 else { finish(id); return }
        let range = lines.first { $0.lowercased().hasPrefix("range:") }
        var start: Int64 = 0; var end = size - 1
        if let range {
            let value = range.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("bytes="), !value.contains(",") else { finish(id); return }
            let pair = value.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { finish(id); return }
            if pair[0].isEmpty { guard let suffix = Int64(pair[1]), suffix > 0 else { finish(id); return }; start = max(0, size - suffix) }
            else { guard let value = Int64(pair[0]), value >= 0, value < size else { finish(id); return }; start = value }
            if !pair[1].isEmpty && !pair[0].isEmpty { guard let value = Int64(pair[1]), value >= start else { finish(id); return }; end = min(end, value) }
        }
        guard let file = files[id] else { finish(id); return }
        switch file {
        case .smb(let handle): guard iina_smb_seek(handle, start) == start else { finish(id); return }
        case .local(let handle): do { try handle.seek(toOffset: UInt64(start)) } catch { finish(id); return }
        }
        let mime = DLNAMediaType.forExtension(source.pathExtension)
        let status = range == nil ? "200 OK" : "206 Partial Content"
        let contentRange = range == nil ? "" : "Content-Range: bytes \(start)-\(end)/\(size)\r\n"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(end - start + 1)\r\nAccept-Ranges: bytes\r\n\(contentRange)Connection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil, first[0] == "GET" else { self?.finish(id); return }
            self.sendChunk(connection, id: id, remaining: end - start + 1)
        })
    }
    private func sendChunk(_ connection: NWConnection, id: UUID, remaining: Int64) {
        guard !stopped, remaining > 0, let file = files[id] else { finish(id); return }
        let payload: Data
        switch file {
        case .smb(let handle):
            var buffer = [CChar](repeating: 0, count: Int(min(remaining, 128 * 1024)))
            let count = iina_smb_read(handle, &buffer, UInt64(buffer.count))
            guard count > 0 else { finish(id); return }
            payload = Data(bytes: buffer, count: Int(count))
        case .local(let handle):
            guard let data = try? handle.read(upToCount: Int(min(remaining, 128 * 1024))), !data.isEmpty else { finish(id); return }
            payload = data
        }
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.finish(id) } else { self.sendChunk(connection, id: id, remaining: remaining - Int64(payload.count)) }
        })
    }
    private func finish(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        if let file = files.removeValue(forKey: id) {
            switch file { case .smb(let handle): iina_smb_close(handle); case .local(let handle): try? handle.close() }
        }
    }
    func stop() { queue.async { [self] in stopped = true; listener?.cancel(); listener = nil; Array(connections.keys).forEach { finish($0) } } }
    private static func wifiAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }; defer { freeifaddrs(head) }
        var cursor = head
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard String(cString: item.pointee.ifa_name) == "en0", let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
        }
        return nil
    }
}

// Conversion is intentionally completed before the system opens the MP4: this
// makes its index and length stable for receiver range requests.
final class AirPlayTranscoder {
    private let queue = DispatchQueue(label: "org.iinamobile.airplay.convert", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func convert(source: URL, output: URL, audioID: String, subtitle: RememberedTrack = RememberedTrack(mode: "no"),
                 externalSubtitles: [URL] = [], subtitleDelay: Double = 0, subtitleSize: Double = 40,
                 progress: @escaping (Double?) -> Void = { _ in }) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                let router = SMBPlaybackStream()
                guard let handle = mpv_create() else { continuation.resume(throwing: URLError(.cannotCreateFile)); return }
                var destroyed = false
                defer { if !destroyed { mpv_terminate_destroy(handle); router.reset() }; if isCancelled() { try? FileManager.default.removeItem(at: output) } }
                var options = [("o", output.path), ("ovc", "h264_videotoolbox"), ("ovcopts", "b=10000000"),
                               ("oac", "aac"), ("oacopts", "b=192000"), ("hwdec", "no"),
                               ("sid", "no"), ("aid", audioID), ("pause", "yes"), ("sub-auto", "no"),
                               ("vf", "sub"), ("sub-delay", String(subtitleDelay)), ("sub-font-size", String(subtitleSize)),
                               ("terminal", "no"), ("config", "no")]
                if let fonts = SubtitleFonts.directory { options.append(("sub-fonts-dir", fonts.path)); options.append(("sub-font", "Noto Sans CJK SC")) }
                for (key, value) in options {
                    let code = mpv_set_option_string(handle, key, value)
                    if code < 0 { continuation.resume(throwing: NSError(domain: "AirPlayConversion", code: Int(code), userInfo: [NSLocalizedDescriptionKey: String(cString: mpv_error_string(code))])); return }
                }
                let initCode = mpv_initialize(handle)
                guard initCode >= 0 else { continuation.resume(throwing: NSError(domain: "AirPlayConversion", code: Int(initCode))); return }
                let registerCode = router.register(with: handle)
                guard registerCode >= 0 else { continuation.resume(throwing: NSError(domain: "AirPlayConversion", code: Int(registerCode))); return }
                let args = ["loadfile", router.mediaPath(source)].map { strdup($0) }
                defer { args.forEach { free($0) } }
                var pointers: [UnsafePointer<CChar>?] = args.map { $0.map { UnsafePointer($0) } } + [nil]
                let loadCode = mpv_command(handle, &pointers)
                guard loadCode >= 0 else { continuation.resume(throwing: NSError(domain: "AirPlayConversion", code: Int(loadCode))); return }
                var nextSpaceCheck = Date.distantPast
                var nextProgress = Date.distantPast
                var configured = false
                while !isCancelled() {
                    if Date() >= nextSpaceCheck {
                        nextSpaceCheck = Date().addingTimeInterval(5)
                        if let capacity = try? output.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
                           capacity < 500 * 1024 * 1024 {
                            continuation.resume(throwing: NSError(domain: "AirPlayConversion", code: 1, userInfo: [NSLocalizedDescriptionKey: L("可用存储空间不足，已停止转换。")]))
                            try? FileManager.default.removeItem(at: output)
                            return
                        }
                    }
                    if Date() >= nextProgress && configured {
                        nextProgress = Date().addingTimeInterval(0.5)
                        var position: Double = 0, duration: Double = 0
                        let posCode = mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &position)
                        let durationCode = mpv_get_property(handle, "duration", MPV_FORMAT_DOUBLE, &duration)
                        if posCode >= 0, durationCode >= 0, position.isFinite, duration.isFinite, duration > 0 {
                            progress(min(0.99, max(0, position / duration)))
                        } else { progress(nil) }
                    }
                    guard let event = mpv_wait_event(handle, 0.25) else { continue }
                    if event.pointee.event_id == MPV_EVENT_FILE_LOADED {
                        for subtitleURL in externalSubtitles {
                            let argv = ["sub-add", router.mediaPath(subtitleURL), "auto"].map { strdup($0) }
                            var ptrs: [UnsafePointer<CChar>?] = argv.map { $0.map { UnsafePointer($0) } } + [nil]
                            let result = mpv_command(handle, &ptrs)
                            argv.forEach { free($0) }
                            guard result >= 0 else { continuation.resume(throwing: NSError(domain: "AirPlayConversion", code: Int(result), userInfo: [NSLocalizedDescriptionKey: L("无法加载外挂字幕。") ])); return }
                        }
                        let tracks: [MediaTrack]
                        if let raw = mpv_get_property_string(handle, "track-list") {
                            tracks = MediaTrack.decode(String(cString: raw)); mpv_free(raw)
                        } else { tracks = [] }
                        let selected = subtitle.resolve(in: tracks, type: "sub")
                        guard subtitle.mode != "track" || selected != "auto" else {
                            continuation.resume(throwing: NSError(domain: "AirPlayConversion", code: 2, userInfo: [NSLocalizedDescriptionKey: L("无法找到当前选择的字幕轨道。") ])); return
                        }
                        let selectCode = mpv_set_property_string(handle, "sid", selected)
                        guard selectCode >= 0 else { continuation.resume(throwing: NSError(domain: "AirPlayConversion", code: Int(selectCode), userInfo: [NSLocalizedDescriptionKey: L("无法选择字幕轨道。") ])); return }
                        configured = true
                        let unpauseCode = mpv_set_property_string(handle, "pause", "no")
                        guard unpauseCode >= 0 else { continuation.resume(throwing: NSError(domain: "AirPlayConversion", code: Int(unpauseCode))); return }
                        continue
                    }
                    guard event.pointee.event_id == MPV_EVENT_END_FILE else { continue }
                    guard let end = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self), end.pointee.error >= 0, end.pointee.reason == MPV_END_FILE_REASON_EOF else {
                        continuation.resume(throwing: router.status.latest ?? URLError(.cannotDecodeContentData)); return
                    }
                    // Destroy flushes the MP4 trailer before AVFoundation opens it.
                    mpv_terminate_destroy(handle)
                    router.reset()
                    destroyed = true
                    progress(1)
                    continuation.resume()
                    return
                }
                continuation.resume(throwing: CancellationError())
            }
        }
    }
}

// Entries are keyed by source identity, modification time and every setting
// that affects the encoded picture or selected audio. Credentials are never
// stored in the filename or in a cache manifest.
struct AirPlayConversionCache {
    private static let cleanInterruptedConversions: Void = {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let directory = root.appendingPathComponent("AirPlayConversions", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("partial-") { try? FileManager.default.removeItem(at: file) }
    }()
    private struct FileIdentity: Codable {
        let location: String
        let size: Int64
        let modified: String
    }
    private struct Identity: Codable {
        let version: Int
        let source: FileIdentity
        let audioID: String
        let subtitle: RememberedTrack
        let subtitles: [FileIdentity]
        let subtitleDelay: Double
        let subtitleSize: Double
    }
    func directory() throws -> URL {
        _ = Self.cleanInterruptedConversions
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("AirPlayConversions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    func url(for key: String) throws -> URL { try directory().appendingPathComponent(key + ".mp4") }
    func reusableURL(for key: String) async throws -> URL? {
        let candidate = try url(for: key)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        if (try? await AVURLAsset(url: candidate).load(.isPlayable)) == true { return candidate }
        try? FileManager.default.removeItem(at: candidate)
        return nil
    }
    func key(source: URL, audioID: String, subtitle: RememberedTrack, externalSubtitles: [URL],
             subtitleDelay: Double, subtitleSize: Double) throws -> String? {
        guard let sourceIdentity = try identity(source) else { return nil }
        var subtitleIdentities: [FileIdentity] = []
        for item in externalSubtitles {
            guard let identity = try identity(item) else { return nil }
            subtitleIdentities.append(identity)
        }
        let payload = Identity(version: 1, source: sourceIdentity, audioID: audioID, subtitle: subtitle,
                               subtitles: subtitleIdentities, subtitleDelay: subtitleDelay, subtitleSize: subtitleSize)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(payload)).map { String(format: "%02x", $0) }.joined()
    }
    private func identity(_ url: URL) throws -> FileIdentity? {
        if url.isFileURL {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = attrs[.size] as? NSNumber, let date = attrs[.modificationDate] as? Date else { return nil }
            return FileIdentity(location: url.standardizedFileURL.path, size: size.int64Value, modified: String(date.timeIntervalSince1970))
        }
        guard url.scheme?.lowercased() == "smb", var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { throw URLError(.badURL) }
        let raw = (c.user ?? "").split(separator: ";", maxSplits: 1).map(String.init)
        let login = SMBLogin(username: raw.last ?? "", domain: raw.count > 1 ? raw[0] : "")
        guard let file = iina_smb_open(host + (c.port.map { ":\($0)" } ?? ""), parts[0], parts.dropFirst().joined(separator: "/"), login.domain, login.username, c.password ?? "") else { throw SMBFailure.current() }
        defer { iina_smb_close(file) }
        let size = iina_smb_size(file), modified = iina_smb_mtime(file), nanoseconds = iina_smb_mtime_nsec(file)
        guard size >= 0, modified > 0 else { return nil }
        c.password = nil
        guard let location = c.string else { return nil }
        return FileIdentity(location: location, size: size, modified: "\(modified).\(nanoseconds)")
    }
}

// Manual UPnP device-description URLs use unicast and do not require iOS's
// restricted multicast entitlement. Discovery can be added when entitled.
struct DLNARenderer {
    let name: String
    let controlURL: URL
    let serviceType: String

    static func load(descriptionURL: URL, session: URLSession = .shared) async throws -> DLNARenderer {
        guard ["http", "https"].contains(descriptionURL.scheme?.lowercased() ?? ""), descriptionURL.host != nil else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: descriptionURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 1024 * 1024 else { throw URLError(.badServerResponse) }
        let parser = DLNADescriptionParser()
        guard XMLParser(data: data).parse(with: parser), let service = parser.services.first(where: { $0.type.hasPrefix("urn:schemas-upnp-org:service:AVTransport:") }),
              let base = URL(string: parser.baseURL ?? "", relativeTo: descriptionURL)?.absoluteURL ?? Optional(descriptionURL),
              let control = URL(string: service.control, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(control.scheme?.lowercased() ?? ""),
              control.host?.lowercased() == descriptionURL.host?.lowercased(),
              service.type.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines) == nil else { throw URLError(.cannotParseResponse) }
        return DLNARenderer(name: parser.friendlyName ?? descriptionURL.host ?? "DLNA", controlURL: control, serviceType: service.type)
    }
    func action(_ name: String, arguments: [(String, String)], session: URLSession = .shared) async throws -> Data {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
        }
        let body = arguments.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        let envelope = "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(name) xmlns:u=\"\(escape(serviceType))\">\(body)</u:\(name)></s:Body></s:Envelope>"
        var request = URLRequest(url: controlURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(serviceType)#\(name)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(envelope.utf8)
        let (data, response) = try await session.data(for: request)
        let fault = DLNASOAPFault.read(data)
        if let fault { throw NSError(domain: "DLNA", code: 1, userInfo: [NSLocalizedDescriptionKey: fault]) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }
    func setURI(_ uri: URL, session: URLSession = .shared) async throws {
        let escapedURI = uri.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let mime = DLNAMediaType.forExtension(uri.pathExtension)
        let metadata = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"1\" parentID=\"0\" restricted=\"1\"><dc:title>Video</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo=\"http-get:*:\(mime):*\">\(escapedURI)</res></item></DIDL-Lite>"
        _ = try await action("SetAVTransportURI", arguments: [("InstanceID", "0"), ("CurrentURI", uri.absoluteString), ("CurrentURIMetaData", metadata)], session: session)
    }
    func play(session: URLSession = .shared) async throws { _ = try await action("Play", arguments: [("InstanceID", "0"), ("Speed", "1")], session: session) }
    func pause(session: URLSession = .shared) async throws { _ = try await action("Pause", arguments: [("InstanceID", "0")], session: session) }
    func stop(session: URLSession = .shared) async throws { _ = try await action("Stop", arguments: [("InstanceID", "0")], session: session) }
    func seek(seconds: Double, session: URLSession = .shared) async throws {
        let n = Int(max(0, seconds)); let target = String(format: "%02d:%02d:%02d", n / 3600, n / 60 % 60, n % 60)
        _ = try await action("Seek", arguments: [("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", target)], session: session)
    }
}

private final class DLNADescriptionParser: NSObject, XMLParserDelegate {
    struct Service { let type: String; let control: String }
    var friendlyName: String?
    var baseURL: String?
    var services: [Service] = []
    private var stack: [String] = []
    private var text = ""
    private var type: String?
    private var control: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        stack.append(elementName); text = ""
        if elementName == "service" { type = nil; control = nil }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "friendlyName": if friendlyName == nil { friendlyName = value }
        case "URLBase": baseURL = value
        case "serviceType": if stack.contains("service") { type = value }
        case "controlURL": if stack.contains("service") { control = value }
        case "service": if let type, let control, !control.isEmpty { services.append(Service(type: type, control: control)) }
        default: break
        }
        if !stack.isEmpty { stack.removeLast() }; text = ""
    }
}
private extension XMLParser {
    func parse(with delegate: XMLParserDelegate) -> Bool { self.delegate = delegate; shouldResolveExternalEntities = false; return parse() }
}

final class DLNAPosition: NSObject, XMLParserDelegate {
    private var current = ""
    private var text = ""
    private var elapsed: Double?
    private var duration: Double = 0
    private var transportState: String?
    static func state(_ data: Data) -> String? {
        let delegate = DLNAPosition(), parser = XMLParser(data: data)
        return parser.parse(with: delegate) ? delegate.transportState : nil
    }
    static func read(_ data: Data) -> (position: Double, duration: Double)? {
        let delegate = DLNAPosition(), parser = XMLParser(data: data)
        guard parser.parse(with: delegate), let elapsed = delegate.elapsed else { return nil }
        return (elapsed, delegate.duration)
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) { current = elementName; text = "" }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "RelTime" { elapsed = Self.seconds(text) }
        if elementName == "TrackDuration" { duration = Self.seconds(text) ?? 0 }
        if elementName == "CurrentTransportState" { transportState = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        current = ""; text = ""
    }
    private static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]), h >= 0, m >= 0, m < 60, s >= 0, s < 60 else { return nil }
        return h * 3600 + m * 60 + s
    }
}

private final class DLNASOAPFault: NSObject, XMLParserDelegate {
    private var isFault = false
    private var faultText: String?
    private var text = ""
    static func read(_ data: Data) -> String? {
        let delegate = DLNASOAPFault(), parser = XMLParser(data: data)
        _ = parser.parse(with: delegate)
        return delegate.isFault ? (delegate.faultText ?? L("接收设备返回错误。")) : nil
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName.split(separator: ":").last == "Fault" { isFault = true }
        text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if ["errorDescription", "faultstring"].contains(String(elementName.split(separator: ":").last ?? "")), !text.isEmpty { faultText = text }
        text = ""
    }
}

private enum DLNAMediaType {
    static func forExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mkv": return "video/x-matroska"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "m3u8": return "application/vnd.apple.mpegurl"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}

struct DLNADiscovery {
    static func location(from data: Data, sender: String) -> URL? {
        guard let message = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let lines = message.components(separatedBy: "\r\n")
        guard let first = lines.first, first.uppercased().hasPrefix("HTTP/1.1 200") || first.uppercased().hasPrefix("HTTP/1.0 200") else { return nil }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "location" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host == sender, url.user == nil, url.password == nil else { return nil }
            return url
        }
        return nil
    }
    static func search() async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard fd >= 0 else { continuation.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))); return }
                defer { Darwin.close(fd) }
                var ttl: UInt8 = 2
                _ = withUnsafePointer(to: &ttl) { setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, $0, socklen_t(MemoryLayout<UInt8>.size)) }
                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                _ = withUnsafePointer(to: &timeout) { setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
                var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); target.sin_family = sa_family_t(AF_INET)
                target.sin_port = in_port_t(1900).bigEndian
                guard inet_pton(AF_INET, "239.255.255.250", &target.sin_addr) == 1 else { continuation.resume(throwing: URLError(.badURL)); return }
                let request = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 3\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
                let data = Data(request.utf8)
                let sent = data.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &target) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                    }
                }
                guard sent == data.count else { continuation.resume(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))); return }
                let end = Date().addingTimeInterval(4)
                var found: Set<URL> = []
                while Date() < end {
                    var sender = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    var buffer = [UInt8](repeating: 0, count: 8192)
                    let count = withUnsafeMutablePointer(to: &sender) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
                    }
                    guard count > 0 else { if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }; break }
                    var address = sender.sin_addr, addressText = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    guard inet_ntop(AF_INET, &address, &addressText, socklen_t(addressText.count)) != nil,
                          let url = location(from: Data(buffer.prefix(count)), sender: String(cString: addressText)) else { continue }
                    found.insert(url)
                }
                continuation.resume(returning: found.sorted { $0.absoluteString < $1.absoluteString })
            }
        }
    }
}
