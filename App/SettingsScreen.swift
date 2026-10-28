// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var language: LanguageStore
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var history: PlaybackHistory
    @Environment(\.dismiss) private var dismiss
    @State private var clearingHistory = false

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
        }.preferredColorScheme(.dark)
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
