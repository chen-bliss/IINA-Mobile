// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

struct VideoSurface: UIViewRepresentable {
    let player: PlayerEngine
    let constrainResolution: Bool
    func makeUIView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.constrainResolution = constrainResolution
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
    @ObservedObject var player: PlayerEngine
    @ObservedObject var library: LibraryModel
    @ObservedObject var history: PlaybackHistory
    let item: PlaybackItem
    @Environment(\.dismiss) private var dismiss
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
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let showSettings = settingsVisible && controlsVisible
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            // Preserve the UIKit/Metal surface when switching between horizontal
            // and vertical layouts; recreating it would leave mpv on the old layer.
            layout {
                videoArea.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: !landscape && showSettings ? max(210, geo.size.height * 0.39) : nil)
                if showSettings {
                    settingsPanel.frame(width: landscape ? min(340, geo.size.width * 0.4) : nil)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
        }
        .ignoresSafeArea(.container, edges: settingsVisible && controlsVisible ? [] : .all)
        .statusBarHidden(!(settingsVisible && controlsVisible))
        .preferredColorScheme(.dark)
        .tint(Color(red: 0.37, green: 0.86, blue: 0.78))
        .onAppear {
            guard !started else { return }
            started = true
            historyID = history.opened(item, servers: library.servers)
            player.open(item.url, subtitles: item.subtitles, startAt: item.startPosition)
        }
        .onDisappear { saveProgress(force: true); player.close() }
        .onChange(of: player.position) { _, _ in if player.isLoaded { saveProgress() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveProgress(force: true) } }
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
                }.navigationTitle("选择字幕服务器")
                    .overlay { if library.servers.isEmpty { ContentUnavailableView("尚未添加服务器", systemImage: "server.rack", description: Text("请先在首页添加 SMB 服务器。")) } }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { browsingSubtitle = false } } }
            }.preferredColorScheme(.dark)
        }
        .alert("播放提示", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
            Button("好", role: .cancel) { player.error = nil }
        } message: { Text(player.error ?? "") }
    }

    private func saveProgress(force: Bool = false) {
        history.update(historyID, position: player.position, duration: player.duration, force: force)
    }

    private var videoArea: some View {
        ZStack {
            VideoSurface(player: player, constrainResolution: player.limitsRenderResolution).accessibilityIdentifier("videoSurface")
                .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--uitesting") ?
                    "render=\(Int(player.renderDimensions.width)),\(Int(player.renderDimensions.height));surface=\(Int(player.surfaceDimensions.width)),\(Int(player.surfaceDimensions.height))" : player.display.fit.title)
                .onTapGesture(count: 2) { player.togglePause() }
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() } }
            if player.isBuffering { ProgressView().tint(.white).scaleEffect(1.4).allowsHitTesting(false) }
            VStack {
                HStack(spacing: 12) {
                    if controlsVisible {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down").font(.headline).frame(width: 40, height: 40).background(.black.opacity(0.5), in: Circle())
                        }.accessibilityLabel("关闭播放器").accessibilityIdentifier("closePlayer")
                        Text(player.title).font(.subheadline.weight(.medium)).lineLimit(1).shadow(radius: 3)
                        Spacer(minLength: 0)
                        if player.sourceHDR { Text(player.outputHDR ? "HDR 输出" : "HDR 片源").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 5).background(.black.opacity(0.5), in: Capsule()) }
                        displayMenu
                        Button { withAnimation(.easeInOut(duration: 0.2)) { settingsVisible.toggle() } } label: {
                            Image(systemName: settingsVisible ? "sidebar.right" : "slider.horizontal.3")
                                .frame(width: 40, height: 40).background(.black.opacity(0.5), in: Circle())
                        }.accessibilityLabel(settingsVisible ? "隐藏播放设置" : "播放设置").accessibilityIdentifier("toggleSettings")
                    } else { Spacer() }
                }.padding(12)
                Spacer()
                if controlsVisible { transport.padding(14).background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)) }
            }.foregroundStyle(.white)
        }.background(.black).clipped()
    }

    private var displayMenu: some View {
        Menu {
            Section("画面大小") {
                ForEach(VideoFitMode.allCases) { mode in
                    Button { player.setDisplay(fit: mode) } label: {
                        if player.display.fit == mode { Label(mode.title, systemImage: "checkmark") }
                        else { Text(mode.title) }
                    }.accessibilityIdentifier("display_\(mode.rawValue)")
                }
            }
            Section("画面比例") {
                ForEach(VideoAspect.allCases) { aspect in
                    Button { player.setDisplay(aspect: aspect) } label: {
                        if player.display.aspect == aspect { Label(aspect.title, systemImage: "checkmark") }
                        else { Text(aspect.title) }
                    }.accessibilityIdentifier("aspect_\(aspect.rawValue)")
                }
            }
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .frame(width: 40, height: 40).background(.black.opacity(0.5), in: Circle())
        }.accessibilityLabel("画面大小与比例").accessibilityIdentifier("displayMenu")
    }

    private var transport: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(time(seeking ? seekPosition : player.position)).monospacedDigit()
                Slider(value: Binding(get: { seeking ? seekPosition : min(player.position, max(player.duration, 1)) }, set: { seekPosition = $0 }),
                       in: 0...max(player.duration, 1), onEditingChanged: { editing in
                    if editing { seekPosition = player.position; seeking = true }
                    else { player.seek(seekPosition); seeking = false }
                }).accessibilityLabel("播放进度").disabled(player.duration <= 0)
                Text(time(player.duration)).monospacedDigit()
            }.font(.caption)
            HStack(spacing: 30) {
                Menu {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                        Button("\(speed.formatted())×") { player.setSpeed(speed) }
                    }
                } label: { Text("\(player.speed.formatted())×").font(.subheadline.bold()).frame(width: 42) }
                Spacer(minLength: 0)
                Button { player.skip(-10) } label: { Image(systemName: "gobackward.10").font(.title2) }.accessibilityLabel("后退十秒")
                Button { player.togglePause() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30)).frame(width: 42) }
                    .accessibilityLabel(player.isPlaying ? "暂停" : "播放").accessibilityIdentifier("togglePlayback")
                Button { player.skip(10) } label: { Image(systemName: "goforward.10").font(.title2) }.accessibilityLabel("前进十秒")
                Spacer(minLength: 0)
                Button { player.screenshot() } label: { Image(systemName: "camera").font(.title3).frame(width: 42) }.accessibilityLabel("截图到文件")
            }
        }
    }

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            Picker("播放设置", selection: $panel) {
                Text("画质").tag(0)
                Text("字幕").tag(1)
                Text("音轨").tag(2)
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
                Text("色彩调整").font(.headline)
                Spacer()
                Button("重置") { player.resetColors() }.font(.subheadline).accessibilityIdentifier("resetColors")
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
                Text("播放表现").font(.headline)
                Picker("播放表现", selection: Binding(get: { player.renderingMode }, set: { player.setRenderingMode($0) })) {
                    ForEach(RenderingMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("renderingMode")
                Text(player.renderingMode == .energy ? "省电优先降低画面输出尺寸，清晰度可能降低。HDR 仍按当前动态范围设置输出。" : "4K HDR 卡顿时可选流畅优先，减轻画面处理负担。")
                    .font(.caption).foregroundStyle(.secondary)
                if player.thermalProtectionActive {
                    Text("设备较热，正在暂时降低画面处理负担。")
                        .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("thermalProtection")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("动态范围").font(.headline)
                Picker("动态范围", selection: Binding(get: { player.picture.hdrMode }, set: { player.setHDRMode($0) })) {
                    ForEach(HDRMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("hdrMode")
                HStack(spacing: 6) {
                    Circle().fill(player.outputHDR ? .green : .secondary).frame(width: 6, height: 6)
                    Text(player.sourceHDR ? (player.outputHDR ? "HDR 片源 · EDR 输出已启用" : "HDR 片源 · 当前未启用 EDR 输出") : "SDR 片源")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("hdrStatus")
                }
                if player.screenHeadroom <= 1 { Text("当前屏幕未报告 HDR 亮度空间。").font(.caption).foregroundStyle(.secondary) }
                Picker("色调映射", selection: Binding(get: { player.picture.toneMapping }, set: { player.setToneMapping($0) })) {
                    Text("自动").tag("auto")
                    Text("BT.2390").tag("bt.2390")
                    Text("Hable").tag("hable")
                    Text("Reinhard").tag("reinhard")
                    Text("裁切高光").tag("clip")
                }.font(.subheadline)
                Text("切换动态范围会短暂重新加载，并恢复播放位置。").font(.caption).foregroundStyle(.secondary)
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
            Text("字幕选择").font(.headline)
            VStack(spacing: 0) {
                trackButton("关闭字幕", selected: player.subtitleID == "no") { player.selectSubtitle("no") }
                trackButton("自动选择", selected: player.subtitleID == "auto") { player.selectSubtitle("auto") }
                ForEach(player.tracks.filter { $0.type == "sub" }) { track in
                    trackButton(track.label, selected: player.subtitleID == String(track.id)) { player.selectSubtitle(String(track.id)) }
                        .accessibilityIdentifier("subtitleTrack_\(track.id)")
                }
            }
            HStack {
                Button { importingSubtitle = true } label: { Label("本地字幕", systemImage: "plus") }.accessibilityIdentifier("addLocalSubtitle")
                Spacer()
                Button { browsingSubtitle = true } label: { Label("SMB 字幕", systemImage: "server.rack") }
            }.font(.subheadline).buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: 14) {
                Stepper(value: Binding(get: { player.subtitleDelay }, set: { player.setSubtitleDelay($0) }), in: -60...60, step: 0.1) {
                    Text("延迟 \(player.subtitleDelay.formatted(.number.precision(.fractionLength(1)))) 秒").monospacedDigit()
                }
                Text("字号 \(Int(player.subtitleSize))").font(.subheadline)
                Slider(value: Binding(get: { player.subtitleSize }, set: { player.setSubtitleSize($0) }), in: 16...72, step: 1).accessibilityLabel("字幕字号")
                Text("ASS 字幕可能包含自己的字体、位置与样式。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var audioPanel: some View {
        Group {
            Text("音轨选择").font(.headline)
            trackButton("自动选择", selected: player.audioID == "auto") { player.selectAudio("auto") }
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
        }.buttonStyle(.plain).accessibilityValue(selected ? "已选择" : "未选择")
    }
    private func time(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
