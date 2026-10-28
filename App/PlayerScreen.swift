// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

struct VideoSurface: UIViewRepresentable {
    let player: PlayerEngine
    let constrainResolution: Bool
    var onSafeAreaChange: ((UIEdgeInsets) -> Void)? = nil
    func makeUIView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.constrainResolution = constrainResolution
        view.onSafeAreaChange = onSafeAreaChange
        view.onResize = { [weak player] size in player?.viewportDidResize(size) }
        // Give the layer a nonzero initial extent before mpv creates its swapchain.
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        view.layoutIfNeeded()
        player.attach(view.videoLayer)
        return view
    }
    func updateUIView(_ uiView: PlayerSurfaceView, context: Context) {
        uiView.constrainResolution = constrainResolution
    }
}

struct PlayerScreen: View {
    @EnvironmentObject private var language: LanguageStore
    @ObservedObject var player: PlayerEngine
    @ObservedObject var library: LibraryModel
    @ObservedObject var history: PlaybackHistory
    let item: PlaybackItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var direction
    @StateObject private var pip = PictureInPictureSession()
    @State private var confirmingPiP = false
    @State private var controlInsets = UIEdgeInsets.zero
    @State private var panel = 0
    @State private var importingSubtitle = false
    @State private var browsingSubtitle = false
    @State private var seeking = false
    @State private var seekPosition: Double = 0
    @State private var controlsVisible = true
    @State private var settingsVisible = ProcessInfo.processInfo.arguments.contains("--show-player-settings")
    @State private var started = false
    @State private var historyID: UUID?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let _ = language.selection
        GeometryReader { geo in
            let layout = PlayerLayout(size: geo.size, safe: controlInsets, rightToLeft: direction == .rightToLeft)
            let preview = settingsVisible && controlsVisible
            // Keep the Metal drawable fixed. mpv's video margins reserve the
            // preview rectangle without a swapchain resize or output restart.
            ZStack(alignment: .topLeading) {
                videoArea
                if preview {
                    settingsPanel
                        .frame(width: layout.panel.width, height: layout.panel.height)
                        .position(x: layout.panel.midX, y: layout.panel.midY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Color.black)
            .onChange(of: preview ? layout.preview : CGRect(origin: .zero, size: geo.size), initial: true) { _, region in
                player.setPreviewRegion(region, canvas: geo.size)
            }
            .onChange(of: geo.size) { _, _ in controlsVisible = true }
        }
        .ignoresSafeArea(.container)
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .tint(Color(red: 0.37, green: 0.86, blue: 0.78))
        .onAppear {
            guard !started else { return }
            started = true
            let prepared = history.prepared(item, servers: library.servers)
            historyID = history.opened(prepared, servers: library.servers)
            player.open(prepared.url, subtitles: prepared.subtitles, startAt: prepared.startPosition, settings: prepared.settings)
        }
        .onDisappear { saveProgress(force: true); player.close() }
        .onChange(of: player.position) { _, _ in if player.isLoaded { saveProgress() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controlsVisible = true; player.refreshAfterForeground() }
            else { saveProgress(force: true) }
        }
        .onChange(of: player.videoSettings) { _, _ in saveVideoSettings() }
        .onChange(of: player.isLoaded) { _, loaded in
            if loaded { saveVideoSettings() }
            #if DEBUG
            if loaded, ProcessInfo.processInfo.arguments.contains("--pip-diagnostics") {
                Task { try? await Task.sleep(for: .seconds(2)); pip.begin(url: item.url, engine: player) }
            }
            #endif
        }
        .onChange(of: controlsVisible) { _, visible in player.setControlsVisible(visible) }
        .task(id: "\(player.isPlaying)-\(controlsVisible)-\(settingsVisible)-\(seeking)") {
            let args = ProcessInfo.processInfo.arguments
            guard AppPreferences.load().autoHideControls, player.isPlaying, controlsVisible, !settingsVisible, !seeking,
                  !args.contains("--uitesting") || args.contains("--test-auto-hide") else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if !Task.isCancelled { controlsVisible = false }
        }
        .fileImporter(isPresented: $importingSubtitle, allowedContentTypes: [.data, .plainText]) { result in
            switch result {
            case .success(let url): player.addSubtitle(url)
            case .failure(let error): player.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $browsingSubtitle) {
            NavigationStack {
                List(library.servers) { server in
                    NavigationLink(server.name) {
                        SMBDirectoryView(server: server, path: server.rootURL?.path ?? "/", subtitlesOnly: true) { url, _ in
                            player.addSubtitle(url); browsingSubtitle = false
                        }
                    }
                }.navigationTitle(L("选择字幕服务器"))
                    .overlay { if library.servers.isEmpty { ContentUnavailableView(L("尚未添加服务器"), systemImage: "server.rack", description: Text(L("请先在首页添加 SMB 服务器。"))) } }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("取消")) { browsingSubtitle = false } } }
            }.preferredColorScheme(.dark)
        }
        .confirmationDialog(L("画中画"), isPresented: $confirmingPiP, titleVisibility: .visible) {
            Button(L("开启画中画")) { settingsVisible = false; pip.begin(url: item.url, engine: player) }
            Button(L("取消"), role: .cancel) { }
        } message: {
            Text(L("系统画中画适用于 MP4、MOV、M4V 和 HLS，支持 SMB。小窗使用系统画质，不应用调色；部分字幕和音轨可能不受支持。返回后会恢复此视频原有设置。"))
        }
        .alert(L("播放提示"), isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
            Button(L("好"), role: .cancel) { player.error = nil }
        } message: { Text(player.error ?? "") }
    }

    private func saveProgress(force: Bool = false) {
        if force && player.isLoaded { saveVideoSettings() }
        history.update(historyID, position: player.position, duration: player.duration, force: force)
    }

    private func saveVideoSettings() {
        guard started, player.isLoaded else { return }
        history.saveSettings(player.videoSettings, subtitles: player.externalSubtitleURLs, for: historyID, servers: library.servers)
    }

    private var videoArea: some View {
        ZStack {
            VideoSurface(player: player, constrainResolution: player.limitsRenderResolution, onSafeAreaChange: { controlInsets = $0 }).accessibilityIdentifier("videoSurface")
                .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--uitesting") ?
                    "render=\(Int(player.renderDimensions.width)),\(Int(player.renderDimensions.height));surface=\(Int(player.surfaceDimensions.width)),\(Int(player.surfaceDimensions.height))" : player.display.fit.title)
                .accessibilityLabel(ProcessInfo.processInfo.arguments.contains("--uitesting") ? "rect=\(player.videoRectangle.minX),\(player.videoRectangle.minY),\(player.videoRectangle.width),\(player.videoRectangle.height)" : L("视频"))
                .onTapGesture(count: 2) { player.togglePause() }
                .onTapGesture { controlsVisible.toggle() }
            if pip.routing { PictureInPictureSurface(session: pip).allowsHitTesting(false) }
            if pip.active {
                VStack(spacing: 16) {
                    Text(L("正在画中画播放")).foregroundStyle(.secondary)
                    Button(L("返回主播放器")) { pip.returnToPlayer() }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("returnFromPiP")
                        .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--uitesting") ? String(Int(player.position)) : "")
                }
            }
            if player.isBuffering { ProgressView().tint(.white).scaleEffect(1.4).allowsHitTesting(false) }
            GeometryReader { controlsGeometry in
            VStack {
                HStack(spacing: 8) {
                    if controlsVisible {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down").font(.headline).frame(width: 52, height: 52).contentShape(Rectangle()).background(.black.opacity(0.5), in: Circle())
                        }.accessibilityLabel(L("关闭播放器")).accessibilityIdentifier("closePlayer")
                        Text(player.title).font(.subheadline.weight(.medium)).lineLimit(1).frame(minWidth: 0).layoutPriority(-1).shadow(radius: 3)
                        Spacer(minLength: 0)
                        if player.sourceHDR && controlsGeometry.size.width > 600 { Text(player.outputHDR ? L("HDR 输出") : L("HDR 片源")).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 5).background(.black.opacity(0.5), in: Capsule()) }
                        Button {
                            if pip.routing { pip.returnToPlayer() } else { confirmingPiP = true }
                        } label: {
                            Image(systemName: pip.active ? "pip.exit" : "pip.enter")
                                .frame(width: 52, height: 52).contentShape(Rectangle()).background(.black.opacity(0.5), in: Circle())
                        }.accessibilityLabel(L("画中画")).accessibilityIdentifier("pictureInPicture").accessibilityValue(pip.active ? "active" : pip.preparing ? "preparing" : "inactive")
                        displayMenu
                        Button { if pip.routing { pip.returnToPlayer() }; settingsVisible.toggle() } label: {
                            Image(systemName: settingsVisible ? "sidebar.right" : "slider.horizontal.3")
                                .frame(width: 52, height: 52).contentShape(Rectangle()).background(.black.opacity(0.5), in: Circle())
                        }.accessibilityLabel(settingsVisible ? L("隐藏播放设置") : L("播放设置")).accessibilityIdentifier("toggleSettings")
                    } else { Spacer() }
                }.padding(.horizontal, 20).padding(.vertical, 12)
                Spacer()
                if controlsVisible { transport.padding(14).background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)) }
            }.buttonStyle(.plain).padding(.top, max(8, controlInsets.top))
                .padding(.bottom, max(12, controlInsets.bottom))
                .padding(.leading, direction == .rightToLeft ? controlInsets.right : controlInsets.left)
                .padding(.trailing, direction == .rightToLeft ? controlInsets.left : controlInsets.right)
                .foregroundStyle(.white)
            }
        }.background(.black).clipped()
    }

    private var displayMenu: some View {
        Menu {
            Section(L("画面大小")) {
                ForEach(VideoFitMode.allCases) { mode in
                    Button { player.setDisplay(fit: mode) } label: {
                        if player.display.fit == mode { Label(mode.title, systemImage: "checkmark") }
                        else { Text(mode.title) }
                    }.accessibilityIdentifier("display_\(mode.rawValue)")
                }
            }
            Section(L("画面比例")) {
                ForEach(VideoAspect.allCases) { aspect in
                    Button { player.setDisplay(aspect: aspect) } label: {
                        if player.display.aspect == aspect { Label(aspect.title, systemImage: "checkmark") }
                        else { Text(aspect.title) }
                    }.accessibilityIdentifier("aspect_\(aspect.rawValue)")
                }
            }
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .frame(width: 52, height: 52).contentShape(Rectangle()).background(.black.opacity(0.5), in: Circle())
        }.accessibilityLabel(L("画面大小与比例")).accessibilityIdentifier("displayMenu")
    }

    private var transport: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(time(seeking ? seekPosition : player.position)).monospacedDigit()
                Slider(value: Binding(get: { seeking ? seekPosition : min(player.position, max(player.duration, 1)) }, set: { seekPosition = $0 }),
                       in: 0...max(player.duration, 1), onEditingChanged: { editing in
                    if editing { seekPosition = player.position; seeking = true }
                    else { player.seek(seekPosition); seeking = false }
                }).accessibilityLabel(L("播放进度")).disabled(player.duration <= 0)
                Text(time(player.duration)).monospacedDigit()
            }.font(.caption)
            HStack(spacing: 30) {
                Menu {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                        Button("\(speed.formatted())×") { player.setSpeed(speed) }
                    }
                } label: { Text("\(player.speed.formatted())×").font(.subheadline.bold()).frame(width: 42) }
                Spacer(minLength: 0)
                Button { player.skip(-10) } label: { Image(systemName: "gobackward.10").font(.title2) }.accessibilityLabel(L("后退十秒"))
                Button { player.togglePause() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30)).frame(width: 42) }
                    .accessibilityLabel(player.isPlaying ? L("暂停") : L("播放")).accessibilityIdentifier("togglePlayback")
                Button { player.skip(10) } label: { Image(systemName: "goforward.10").font(.title2) }.accessibilityLabel(L("前进十秒"))
                Spacer(minLength: 0)
                Button { player.screenshot() } label: { Image(systemName: "camera").font(.title3).frame(width: 42) }.accessibilityLabel(L("截图到文件"))
            }
        }
    }

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            Picker(L("播放设置"), selection: $panel) {
                Text(L("画质")).tag(0)
                Text(L("字幕")).tag(1)
                Text(L("音轨")).tag(2)
            }.pickerStyle(.segmented).padding(16).accessibilityIdentifier("settingsTabs")
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if panel == 0 { picturePanel }
                    else if panel == 1 { subtitlePanel }
                    else { audioPanel }
                }.padding(.horizontal, 20).padding(.bottom, 25)
            }
        }.background(Color(red: 0.07, green: 0.08, blue: 0.10))
    }

    private var picturePanel: some View {
        Group {
            HStack {
                Text(L("色彩调整")).font(.headline)
                Spacer()
                Button(L("重置")) { player.resetColors() }.font(.subheadline).accessibilityIdentifier("resetColors")
            }
            VStack(spacing: 16) {
                ForEach(ColorControl.allCases) { control in
                    VStack(spacing: 7) {
                        HStack {
                            Text(control.title).font(.subheadline)
                            Spacer()
                            Text(String(Int(player.picture[control]))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .accessibilityIdentifier("value_\(control.rawValue)")
                        }
                        Slider(value: Binding(get: { player.picture[control] }, set: { player.setColor(control, value: $0) }), in: -100...100, step: 1)
                            .accessibilityLabel(control.title).accessibilityIdentifier("color_\(control.rawValue)")
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(L("播放表现")).font(.headline)
                Picker(L("播放表现"), selection: Binding(get: { player.renderingMode }, set: { player.setRenderingMode($0) })) {
                    ForEach(RenderingMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("renderingMode")
                Text(player.renderingMode == .energy ? L("省电优先降低画面输出尺寸，清晰度可能降低。HDR 仍按当前动态范围设置输出。") : L("4K HDR 卡顿时可选流畅优先，减轻画面处理负担。"))
                    .font(.caption).foregroundStyle(.secondary)
                if player.thermalProtectionActive {
                    Text(L("设备较热，正在暂时降低画面处理负担。"))
                        .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("thermalProtection")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(L("动态范围")).font(.headline)
                Picker(L("动态范围"), selection: Binding(get: { player.picture.hdrMode }, set: { player.setHDRMode($0) })) {
                    ForEach(HDRMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("hdrMode")
                HStack(spacing: 6) {
                    Circle().fill(player.outputHDR ? .green : .secondary).frame(width: 6, height: 6)
                    Text(player.sourceHDR ? (player.outputHDR ? L("HDR 片源 · EDR 输出已启用") : L("HDR 片源 · 当前未启用 EDR 输出")) : L("SDR 片源"))
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("hdrStatus")
                }
                if player.screenHeadroom <= 1 { Text(L("当前屏幕未报告 HDR 亮度空间。")).font(.caption).foregroundStyle(.secondary) }
                Picker(L("色调映射"), selection: Binding(get: { player.picture.toneMapping }, set: { player.setToneMapping($0) })) {
                    Text(L("自动")).tag("auto")
                    Text("BT.2390").tag("bt.2390")
                    Text("Hable").tag("hable")
                    Text("Reinhard").tag("reinhard")
                    Text(L("裁切高光")).tag("clip")
                }.font(.subheadline)
                Text(L("切换动态范围会短暂重新加载，并恢复播放位置。")).font(.caption).foregroundStyle(.secondary)
            }
            if !player.videoDetails.isEmpty { Text(player.videoDetails).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled).accessibilityIdentifier("videoDetails") }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--uitesting") {
                Text(player.lastAppliedColor).font(.caption2).accessibilityIdentifier("colorReadback")
                Text(player.isLoaded ? "loaded" : "loading").accessibilityIdentifier("playbackState")
                Text("\(Int(player.renderDimensions.width))x\(Int(player.renderDimensions.height))").accessibilityIdentifier("renderDimensions")
            }
            #endif
        }
    }

    private var subtitlePanel: some View {
        Group {
            Text(L("字幕选择")).font(.headline)
            VStack(spacing: 0) {
                trackButton(L("关闭字幕"), selected: player.subtitleID == "no") { player.selectSubtitle("no") }
                trackButton(L("自动选择"), selected: player.subtitleID == "auto") { player.selectSubtitle("auto") }
                ForEach(player.tracks.filter { $0.type == "sub" }) { track in
                    trackButton(track.label, selected: player.subtitleID == String(track.id)) { player.selectSubtitle(String(track.id)) }
                        .accessibilityIdentifier("subtitleTrack_\(track.id)")
                }
            }
            HStack {
                Button { importingSubtitle = true } label: { Label(L("本地字幕"), systemImage: "plus") }.accessibilityIdentifier("addLocalSubtitle")
                Spacer()
                Button { browsingSubtitle = true } label: { Label(L("SMB 字幕"), systemImage: "server.rack") }
            }.font(.subheadline).buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: 14) {
                Stepper(value: Binding(get: { player.subtitleDelay }, set: { player.setSubtitleDelay($0) }), in: -60...60, step: 0.1) {
                    Text(LF("延迟 %@ 秒", player.subtitleDelay.formatted(.number.precision(.fractionLength(1))))).monospacedDigit()
                }
                Text(LF("字号 %@", Int(player.subtitleSize))).font(.subheadline)
                Slider(value: Binding(get: { player.subtitleSize }, set: { player.setSubtitleSize($0) }), in: 16...72, step: 1).accessibilityLabel(L("字幕字号"))
                Text(L("ASS 字幕可能包含自己的字体、位置与样式。")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var audioPanel: some View {
        Group {
            Text(L("音轨选择")).font(.headline)
            trackButton(L("自动选择"), selected: player.audioID == "auto") { player.selectAudio("auto") }
            ForEach(player.tracks.filter { $0.type == "audio" }) { track in
                trackButton(track.label, selected: player.audioID == String(track.id)) { player.selectAudio(String(track.id)) }
            }
        }
    }
    private func trackButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title).font(.subheadline).multilineTextAlignment(.leading); Spacer(); if selected { Image(systemName: "checkmark") } }
                .foregroundStyle(selected ? Color(red: 0.37, green: 0.86, blue: 0.78) : .white)
                .padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).accessibilityValue(selected ? L("已选择") : L("未选择"))
    }
    private func time(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
