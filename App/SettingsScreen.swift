// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var language: LanguageStore
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var history: PlaybackHistory
    @Environment(\.dismiss) private var dismiss
    @State private var clearingHistory = false
    @State private var showingDefaultPlayerGuide = false
    @State private var removingDefaultPlayer = false
    @State private var sampleMessage: String?

    var body: some View {
        let _ = language.selection
        VStack(spacing: 0) {
            // Keep dismissal outside the scrolling form. On changing/foldable
            // displays, a navigation toolbar can lose its items after scrolling.
            HStack {
                Text(L("设置")).font(.title2.bold()).accessibilityIdentifier("settingsTitle")
                Spacer()
                Button(L("完成")) { dismiss() }
                    .frame(minWidth: 52, minHeight: 52).contentShape(Rectangle())
                    .accessibilityIdentifier("dismissSettings")
            }.padding(.horizontal, 20).padding(.vertical, 4)
            Form {
                Section {
                    Button(L("设为默认视频播放器")) {
                        removingDefaultPlayer = false
                        showingDefaultPlayerGuide = true
                    }.accessibilityIdentifier("setDefaultVideoPlayer")
                    Button(L("取消设为默认视频播放器")) {
                        removingDefaultPlayer = true
                        showingDefaultPlayerGuide = true
                    }.accessibilityIdentifier("removeDefaultVideoPlayer")
                    Text(L("默认打开方式由系统“文件”应用管理，需要在那里确认；本应用无法读取或直接更改。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L("SMB 共享可能没有设置入口，请先在“我的 iPhone”或 iCloud 云盘中操作。"))
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text(L("默认视频播放器")) }
                Section(L("语言")) {
                    Picker(L("应用语言"), selection: $language.selection) {
                        Text(L("跟随系统")).tag("system")
                        Text("English").tag("en")
                        Text("简体中文").tag("zh-Hans")
                        Text("Français").tag("fr")
                        Text("Español").tag("es")
                        Text("Русский").tag("ru")
                        Text("العربية").tag("ar")
                    }.pickerStyle(.menu).accessibilityIdentifier("appLanguage")
                    Text(L("立即生效并记住选择。跟随系统时，未支持的语言将使用英文。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker(L("默认播放表现"), selection: $preferences.value.rendering) {
                        ForEach(RenderingMode.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("defaultRendering")
                    Text(L("省电优先降低画面输出尺寸和处理负担，适合长时间观看；细节清晰度可能降低，HDR 仍按下方设置输出。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L("设备升温时自动减轻画面处理"), isOn: $preferences.value.adaptToHeat)
                        .accessibilityIdentifier("adaptToHeat")
                } header: { Text(L("播放与能耗")) }
                Section(L("默认画质")) {
                    Picker(L("动态范围"), selection: $preferences.value.picture.hdrMode) {
                        ForEach(HDRMode.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("defaultHDR")
                    Picker(L("色调映射"), selection: $preferences.value.picture.toneMapping) {
                        Text(L("自动")).tag("auto"); Text("BT.2390").tag("bt.2390"); Text("Hable").tag("hable")
                        Text("Reinhard").tag("reinhard"); Text(L("裁切高光")).tag("clip")
                    }
                    ForEach(ColorControl.allCases) { control in
                        VStack(alignment: .leading) {
                            HStack { Text(control.title); Spacer(); Text("\(Int(preferences.value.picture[control]))").monospacedDigit().foregroundStyle(.secondary) }
                            Slider(value: Binding(get: { preferences.value.picture[control] }, set: { preferences.value.picture[control] = $0 }), in: -100...100, step: 1)
                                .accessibilityIdentifier("default_\(control.rawValue)")
                        }
                    }
                    Button(L("重置默认色彩")) { preferences.value.picture.resetColors() }
                }
                Section(L("默认字幕")) {
                    Picker(L("字幕选择"), selection: $preferences.value.subtitles) {
                        ForEach(SubtitlePreference.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("defaultSubtitles")
                    HStack { Text(L("字幕字号")); Spacer(); Text("\(Int(preferences.value.subtitleSize))").monospacedDigit() }
                    Slider(value: $preferences.value.subtitleSize, in: 16...72, step: 1)
                    Text(L("优先选择片源中对应语言的字幕；字幕自己的排版可能影响字号。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("默认画面")) {
                    Picker(L("画面大小"), selection: $preferences.value.display.fit) {
                        ForEach(VideoFitMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker(L("画面比例"), selection: $preferences.value.display.aspect) {
                        ForEach(VideoAspect.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle(L("播放时自动隐藏控制栏"), isOn: $preferences.value.autoHideControls)
                }
                Section(L("历史播放")) {
                    Toggle(L("记录播放历史"), isOn: $preferences.value.saveHistory).accessibilityIdentifier("saveHistory")
                    Toggle(L("从历史记录继续上次进度"), isOn: $preferences.value.resumePlayback)
                    Button(L("清空播放记录"), role: .destructive) { clearingHistory = true }.disabled(history.entries.isEmpty)
                    Text(L("历史记录仅保存在这部设备，最多保留 100 项。服务器密码仍保存在钥匙串中。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section { Text(L("这些设置用于首次打开的视频。每个视频会记住自己的画质、字幕、音轨、倍速与画面比例，再次打开时优先恢复。"))
                        .font(.footnote).foregroundStyle(.secondary) }
            }
            .confirmationDialog(L("清空所有播放记录？"), isPresented: $clearingHistory, titleVisibility: .visible) {
                Button(L("清空播放记录"), role: .destructive) { history.clear() }
            }
            .sheet(isPresented: $showingDefaultPlayerGuide) {
                NavigationStack {
                    List {
                        Section(L("SMB 共享没有打开方式？")) {
                            Text(L("系统“文件”的 SMB 共享位置可能不显示“打开方式”或“始终使用此应用打开”。请先在“我的 iPhone”或 iCloud 云盘中找到同格式的视频，再设置或取消默认应用。"))
                            Text(L("可使用下方按钮准备本地 MP4、MKV 短片，然后到“文件”→“我的 iPhone”→本应用文件夹→“默认播放器示例”操作。测试版请进入“IINA Mobile 测试版”文件夹。"))
                            Button(L("准备本地 MP4、MKV 示例"), action: prepareDefaultPlayerSamples)
                                .accessibilityIdentifier("prepareDefaultPlayerSamples")
                            Text(L("设置后请返回 SMB 测试是否生效。若系统仍不使用所选应用，可在 IINA Mobile 首页添加同一个 SMB 服务器，直接浏览和播放；无需先下载整段视频。"))
                        }
                        Section {
                            Text(L("在 iOS 26 及以上版本中，打开系统“文件”应用，长按一个视频，选择“显示简介”。"))
                            Text(L(removingDefaultPlayer
                                ? "在“始终使用此应用打开”中改选其他应用，并按系统提示应用到该文件或同类文件。"
                                : "在“始终使用此应用打开”中选择 IINA Mobile，并按系统提示应用到该文件或同类文件。"))
                            Text(L("MP4、MKV 等不同格式需要分别设置。系统可能显示不同的菜单名称。"))
                        }
                        Section {
                            Text(L("较早的 iOS 版本可在“文件”中长按视频，选择“共享”，再选择 IINA Mobile；这些版本不支持上述默认打开设置。"))
                        }
                    }
                    .navigationTitle(L(removingDefaultPlayer ? "取消设为默认视频播放器" : "设为默认视频播放器"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button(L("完成")) { showingDefaultPlayerGuide = false }
                            .accessibilityIdentifier("dismissDefaultPlayerGuide")
                    } }
                    .alert(L("本地示例"), isPresented: Binding(get: { sampleMessage != nil }, set: { if !$0 { sampleMessage = nil } })) {
                        Button(L("好"), role: .cancel) {}
                    } message: { Text(sampleMessage ?? "") }
                }.preferredColorScheme(.dark)
            }
        }.preferredColorScheme(.dark)
    }

    private func prepareDefaultPlayerSamples() {
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = documents.appendingPathComponent("默认播放器示例", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, ext) in [("QA-PiP", "mp4"), ("Sample-SDR", "mkv")] {
                guard let source = Bundle.main.url(forResource: name, withExtension: ext) else { throw CocoaError(.fileNoSuchFile) }
                let target = folder.appendingPathComponent("IINA-Sample.\(ext)")
                if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: source, to: target) }
            }
            sampleMessage = L("已准备好。请到“文件”→“我的 iPhone”→本应用文件夹→“默认播放器示例”，长按示例视频并选择“显示简介”。")
        } catch { sampleMessage = LF("无法准备本地示例：%@", error.localizedDescription) }
    }
}

struct HistoryRow: View {
    @EnvironmentObject private var language: LanguageStore
    let entry: HistoryEntry
    var body: some View {
        let _ = language.selection
        HStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath").font(.title2).foregroundStyle(.mint)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title).font(.headline).lineLimit(1)
                HStack {
                    Text(entry.source.kind == .server ? "SMB" : entry.source.kind == .network ? L("网络视频") : L("本地视频"))
                    Text(entry.duration > 0 ? "\(clock(entry.position)) / \(clock(entry.duration))" : L("刚刚播放"))
                }.font(.caption).foregroundStyle(.secondary)
                if entry.duration > 0 { ProgressView(value: min(1, max(0, entry.position / entry.duration))).tint(.mint) }
            }
            Spacer(minLength: 0)
            Image(systemName: "play.fill").foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
    private func clock(_ value: Double) -> String {
        let seconds = value.isFinite ? max(0, Int(value)) : 0
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct HistoryScreen: View {
    @EnvironmentObject private var language: LanguageStore
    @ObservedObject var history: PlaybackHistory
    let open: (HistoryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let _ = language.selection
        NavigationStack {
            List {
                ForEach(history.entries) { entry in
                    Button { open(entry) } label: { HistoryRow(entry: entry) }.buttonStyle(.plain)
                }.onDelete { indices in indices.map { history.entries[$0].id }.forEach(history.remove) }
            }.overlay { if history.entries.isEmpty { ContentUnavailableView(L("暂无播放记录"), systemImage: "clock") } }
                .navigationTitle(L("播放历史"))
                .toolbar(.visible, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}
