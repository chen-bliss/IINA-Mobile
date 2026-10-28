// SPDX-License-Identifier: GPL-3.0-or-later
import AVKit
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
                var remaining = max(0, end - offset)
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
            if !request.isCancelled { request.finishLoading() }
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
    let player = AVPlayer()
    private weak var engine: PlayerEngine?
    private var loader: SMBAssetLoader?
    private var controller: AVPictureInPictureController?
    private var statusObservation: NSKeyValueObservation?
    private var task: Task<Void, Never>?
    private var restoredInterface = false
    private var initialPosition: Double = 0
    private var initialPlaying = false
    private var positioned = false
    private var initialSpeed: Float = 1

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
    func begin(url: URL, engine: PlayerEngine) {
        guard !routing else { controller?.stopPictureInPicture(); return }
        diagnostic("request; systemSupported=\(AVPictureInPictureController.isPictureInPictureSupported())")
        guard AVPictureInPictureController.isPictureInPictureSupported() else { engine.error = L("这台设备不支持画中画。"); return }
        guard Self.supports(url) else { engine.error = L("画中画支持系统可解码的 MP4、MOV、M4V 和 HLS。此文件请继续使用主播放器。"); return }
        self.engine = engine
        diagnostic("begin; supported=true")
        initialPosition = engine.position; initialPlaying = engine.isPlaying; initialSpeed = Float(engine.speed)
        restoredInterface = false; positioned = false
        let asset: AVURLAsset
        if url.scheme?.lowercased() == "smb" {
            let loader = SMBAssetLoader(source: url); self.loader = loader
            asset = AVURLAsset(url: URL(string: "iinapip://\(UUID().uuidString)/video.\(url.pathExtension)")!)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        } else { asset = AVURLAsset(url: url) }
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        preparing = true; routing = true
        engine.beginNativePlayback(self)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for tick in 0..<300 {
                    if tick % 20 == 0 { diagnostic("prepare; status=\(item.status.rawValue); controller=\(controller != nil)") }
                    try Task.checkCancellation()
                    if item.status == .failed { throw item.error ?? URLError(.cannotDecodeContentData) }
                    if item.status == .readyToPlay, controller != nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard item.status == .readyToPlay else { throw URLError(.timedOut) }
                await player.seek(to: CMTime(seconds: initialPosition, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                positioned = true
                await applySelection(asset: asset, item: item, settings: engine.videoSettings)
                if initialPlaying { player.playImmediately(atRate: initialSpeed) }
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
            catch { fail(L("无法开启画中画，请确认文件编码受系统支持后重试。")) }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed { DispatchQueue.main.async { self?.fail(L("画中画播放失败，已返回主播放器。")) } }
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
        let resume = player.rate != 0
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
        controller?.delegate = nil; controller = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        loader?.stop(); loader = nil
        preparing = false; active = false; routing = false
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
