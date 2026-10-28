// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

@main
struct IINAMobileApp: App {
    var body: some Scene { WindowGroup { HomeView().preferredColorScheme(.dark) } }
}

private let accent = Color(red: 0.37, green: 0.86, blue: 0.78)

struct HomeView: View {
    @StateObject private var library = LibraryModel()
    @StateObject private var player = PlayerEngine()
    @StateObject private var preferences = PreferencesStore()
    @StateObject private var history = PlaybackHistory()
    @State private var playback: PlaybackItem?
    @State private var importing = false
    @State private var addingServer = false
    @State private var editingServer: SMBServer?
    @State private var openingLink = false
    @State private var showingAbout = false
    @State private var showingSettings = false
    @State private var showingHistory = false
    @State private var link = ""
    @State private var message: String?
    @State private var previewOpened = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 9) {
                        Image(systemName: "play.rectangle.on.rectangle.fill")
                            .font(.system(size: 36)).foregroundStyle(accent).padding(.bottom, 10)
                        Text("IINA Mobile").font(.system(size: 36, weight: .bold, design: .rounded))
                        Text("自由播放，随心调色。").font(.title3).foregroundStyle(.secondary)
                    }.padding(.top, 20)
                    HStack(spacing: 12) {
                        sourceCard("打开视频", detail: "本地与文件", icon: "folder", id: "openLocal") { importing = true }
                        sourceCard("网络链接", detail: "直接播放", icon: "link", id: "openLink") { openingLink = true }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("最近播放").font(.title2.bold())
                            Spacer()
                            if !history.entries.isEmpty { Button("全部") { showingHistory = true }.accessibilityIdentifier("showHistory") }
                        }
                        if history.entries.isEmpty {
                            Text("播放过的视频会出现在这里，可以继续上次进度。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(Array(history.entries.prefix(5))) { entry in
                            Button { openHistory(entry) } label: { HistoryRow(entry: entry).padding(14).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18)) }
                                .buttonStyle(.plain).accessibilityIdentifier("history_\(entry.title)")
                                .contextMenu { Button("移除记录", role: .destructive) { history.remove(entry.id) } }
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("我的服务器").font(.title2.bold())
                            Spacer()
                            Button { editingServer = nil; addingServer = true } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                                .accessibilityLabel("添加 SMB 服务器").accessibilityIdentifier("addServer")
                        }
                        if library.servers.isEmpty {
                            Button { addingServer = true } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "externaldrive.connected.to.line.below").font(.title).foregroundStyle(accent)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("连接 SMB 服务器").font(.headline).foregroundStyle(.primary)
                                        Text("浏览 NAS 或电脑共享中的视频").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }.padding(20).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
                            }.buttonStyle(.plain)
                        }
                        ForEach(library.servers) { server in
                            NavigationLink {
                                SMBDirectoryView(server: server, path: server.rootURL?.path ?? "/", subtitlesOnly: false) { url, subtitles in
                                    playback = PlaybackItem(url: url, subtitles: subtitles)
                                }
                            } label: {
                                HStack(spacing: 15) {
                                    Image(systemName: "server.rack").font(.title2).foregroundStyle(accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(server.name).font(.headline).foregroundStyle(.primary)
                                        Text(server.host + (server.share.isEmpty ? "" : " · " + server.share))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }.padding(18).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
                            }.accessibilityIdentifier("server_\(server.name)").contextMenu {
                                Button("编辑并测试连接") { editingServer = server; addingServer = true }
                                Button("删除服务器", role: .destructive) { library.remove(server.id) }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("体验画质控制").font(.title2.bold())
                        Text("用内置测试片段试试调色与字幕。").foregroundStyle(.secondary).font(.subheadline)
                        HStack(spacing: 12) {
                            Button("SDR 测试片段") { openSample("Sample-SDR") }
                                .accessibilityIdentifier("sampleSDR")
                            Button("HDR 测试片段") { openSample("Sample-HDR") }
                                .accessibilityIdentifier("sampleHDR")
                        }.buttonStyle(.bordered).tint(accent)
                    }
                    Text("色彩调整、字幕选择、SMB 播放，全部免费。")
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
                }.padding(24)
            }
            .background(Color(red: 0.055, green: 0.065, blue: 0.085))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置").accessibilityIdentifier("openSettings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAbout = true } label: { Image(systemName: "info.circle") }.accessibilityLabel("关于")
                }
            }
            .sheet(isPresented: $addingServer) { ServerEditor(library: library, server: editingServer) }
            .sheet(isPresented: $openingLink) { linkSheet }
            .sheet(isPresented: $showingAbout) { AboutView() }
            .sheet(isPresented: $showingSettings) { SettingsScreen(preferences: preferences, history: history) }
            .sheet(isPresented: $showingHistory) {
                HistoryScreen(history: history) { entry in
                    showingHistory = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openHistory(entry) }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .data]) { result in
                switch result {
                case .success(let url): playback = PlaybackItem(url: url)
                case .failure(let error): message = error.localizedDescription
                }
            }
            .fullScreenCover(item: $playback) { item in
                PlayerScreen(player: player, library: library, history: history, item: item)
            }
            .onOpenURL { url in playback = PlaybackItem(url: url) }
            .alert("无法打开", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(message ?? "") }
            .onAppear {
                #if DEBUG
                if !previewOpened && ProcessInfo.processInfo.arguments.contains("--diagnose-smb-qa") {
                    previewOpened = true
                    Task {
                        let host = ProcessInfo.processInfo.environment["IINA_QA_HOST"] ?? "127.0.0.1"
                        let port = Int(ProcessInfo.processInfo.environment["IINA_QA_PORT"] ?? "1445") ?? 1445
                        let server = SMBServer(name: "SMB QA", host: host, share: "QA", username: "iinaqa", port: port)
                        let reportURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("SMB-QA.txt")
                        do {
                            let entries = try await SMBService.shared.list(server: server, path: "/QA", password: "fixture-only")
                            guard let video = entries.first(where: { $0.isVideo }),
                                  let url = server.playbackURL(path: video.path, password: "fixture-only") else { throw URLError(.fileDoesNotExist) }
                            playback = PlaybackItem(url: url)
                            try await Task.sleep(for: .seconds(10))
                            let report = "entries=\(entries.count); loaded=\(player.isLoaded); position=\(player.position); duration=\(player.duration); render=\(player.renderDimensions); error=\(player.error ?? "none")"
                            try report.write(to: reportURL, atomically: true, encoding: .utf8)
                        } catch { try? error.localizedDescription.write(to: reportURL, atomically: true, encoding: .utf8) }
                    }
                }
                if !previewOpened && ProcessInfo.processInfo.arguments.contains("--diagnose-smb") {
                    previewOpened = true
                    Task {
                        var results: [String] = ["Started: \(Date().ISO8601Format())"]
                        for server in library.servers {
                            results.append("\(server.name): \(await SMBDiagnostics.transport(server: server))")
                            do {
                                let entries = try await SMBService.shared.list(server: server, path: server.rootURL?.path ?? "/")
                                results.append("\(server.name): OK (\(entries.count) entries)")
                            } catch {
                                let status = (error as? SMBFailure).map { String(format: " (NTSTATUS=0x%08X)", $0.ntStatus) } ?? ""
                                results.append("\(server.name): \(error.localizedDescription)\(status)")
                            }
                        }
                        let report = results.joined(separator: "\n")
                        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("SMB-Diagnostics.txt")
                        try? report.write(to: file, atomically: true, encoding: .utf8)
                        NSLog("SMB diagnostics finished")
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--smb-qa") && !library.servers.contains(where: { $0.name == "SMB QA" }) {
                    let server = SMBServer(name: "SMB QA", host: "127.0.0.1", share: "QA", username: "iinaqa", port: 1445)
                    do { try library.save(server, password: "fixture-only") }
                    catch { message = error.localizedDescription }
                }
                if !previewOpened && ProcessInfo.processInfo.arguments.contains("--preview-sdr") {
                    previewOpened = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { openSample("Sample-SDR") }
                }
                #endif
                if ProcessInfo.processInfo.arguments.contains("--uitesting") {
                    if !ProcessInfo.processInfo.arguments.contains("--preserve-defaults") { preferences.value = AppPreferences() }
                    player.resetColors()
                    player.setDisplay(fit: .fit, aspect: .original)
                    if player.picture.hdrMode != .automatic { player.setHDRMode(.automatic) }
                }
            }
        }.tint(accent)
    }

    private func sourceCard(_ title: String, detail: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
    private func openHistory(_ entry: HistoryEntry) {
        do { playback = try history.playback(for: entry, servers: library.servers) }
        catch { message = error.localizedDescription }
    }
    private func openSample(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mkv") else { message = "测试片段未包含在此构建中。"; return }
        let sub = Bundle.main.url(forResource: "Sample", withExtension: "ass")
        playback = PlaybackItem(url: url, subtitles: sub.map { [$0] } ?? [])
    }
    private var linkSheet: some View {
        NavigationStack {
            Form {
                Section("视频地址") {
                    TextField("https://example.com/video.mkv", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                Button("播放") {
                    guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
                          ["http", "https", "smb", "rtsp"].contains(url.scheme?.lowercased() ?? "") else { message = "请输入有效的视频链接。"; return }
                    openingLink = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { playback = PlaybackItem(url: url) }
                }
            }.navigationTitle("打开网络链接").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { openingLink = false } } }
        }.tint(accent)
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("IINA Mobile").font(.title.bold())
                    Text("基于 IINA 的功能与源码实现的独立 iPhone 移植项目。非 IINA 官方发行版。")
                    Text("所有画质、字幕与 SMB 功能免费，无广告、无订阅。")
                }
                Section("开源组件") {
                    Link("IINA · GPLv3", destination: URL(string: "https://github.com/iina/iina")!)
                    Link("MPVKit · GPLv3 构建", destination: URL(string: "https://github.com/mpvkit/MPVKit")!)
                    Text("播放引擎包含 mpv、FFmpeg、libplacebo、libass、Samba 和 MoltenVK。完整来源与许可证见随附源码。")
                }
                Section("HDR") {
                    Text("自动 HDR 使用设备支持的扩展动态范围输出。实际效果取决于屏幕、片源和播放引擎；播放面板会分别显示片源 HDR 和输出状态。也可以将 HDR 映射到 SDR。")
                }
            }.navigationTitle("关于").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
