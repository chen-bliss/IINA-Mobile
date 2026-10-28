// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ServerEditor: View {
    @EnvironmentObject private var language: LanguageStore
    @ObservedObject var library: LibraryModel
    let existingServer: SMBServer?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var port = ""
    @State private var error: String?
    @State private var testing = false
    @State private var connectionMessage: String?
    init(library: LibraryModel, server: SMBServer? = nil) {
        self.library = library; self.existingServer = server
        _name = State(initialValue: server?.name ?? "")
        _host = State(initialValue: server?.host ?? "")
        _share = State(initialValue: server?.share ?? "")
        _username = State(initialValue: server?.username ?? "")
        _domain = State(initialValue: server?.domain ?? "")
        _port = State(initialValue: server?.port.map(String.init) ?? "")
        _password = State(initialValue: server.map { KeychainStore.password(for: $0.id) } ?? "")
    }
    var body: some View {
        let _ = language.selection
        NavigationStack {
            Form {
                Section(L("服务器")) {
                    TextField(L("名称，例如：家里的 NAS"), text: $name).accessibilityIdentifier("serverName")
                    TextField(L("地址，例如：192.168.1.10"), text: $host).accessibilityIdentifier("serverHost")
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(L("共享名称，留空可浏览共享列表"), text: $share)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(L("端口，默认 445"), text: $port).keyboardType(.numberPad)
                }
                Section(L("登录")) {
                    TextField(L("用户名，访客可留空"), text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(L("密码"), text: $password)
                    TextField(L("域，可选"), text: $domain).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section { Text(L("密码保存在 iPhone 钥匙串中。支持 SMB2 和 SMB3。手机需要能访问服务器所在网络。")).font(.footnote).foregroundStyle(.secondary) }
                Section {
                    Button {
                        guard let server = formServer() else { return }
                        testing = true; connectionMessage = nil; error = nil
                        Task {
                            do {
                                let entries = try await SMBService.shared.list(server: server, path: server.rootURL?.path ?? "/", password: password)
                                connectionMessage = LF("连接成功，找到 %@ 个项目。", entries.count)
                            } catch { self.error = error.localizedDescription }
                            testing = false
                        }
                    } label: {
                        HStack { Text(L("测试连接")); Spacer(); if testing { ProgressView() } }
                    }.disabled(testing).accessibilityIdentifier("testSMBConnection")
                    if let connectionMessage { Text(connectionMessage).foregroundStyle(.green) }
                }
            }.navigationTitle(existingServer == nil ? L("添加 SMB 服务器") : L("编辑 SMB 服务器")).navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
                .alert(L("服务器设置"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button(L("好"), role: .cancel) { error = nil }
                } message: { Text(error ?? "") }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L("取消")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("保存")) {
                            guard let server = formServer() else { return }
                            do { try library.save(server, password: password); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }.bold()
                    }
                }
        }
    }
    private func formServer() -> SMBServer? {
        if !port.isEmpty && Int(port) == nil { error = L("端口应为 1 至 65535 的整数。"); return nil }
        var server = SMBServer(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                               host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                               share: share.trimmingCharacters(in: .whitespacesAndNewlines),
                               username: username, domain: domain, port: Int(port))
        if let existingServer { server.id = existingServer.id }
        guard server.isValid else { error = L("请填写名称与服务器 IP 或主机名，地址中不需要 smb://。"); return nil }
        return server
    }
}

struct SMBDirectoryView: View {
    @EnvironmentObject private var language: LanguageStore
    let server: SMBServer
    let path: String
    let subtitlesOnly: Bool
    let onSelect: (URL, [URL]) -> Void
    @State private var entries: [SMBEntry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""
    var body: some View {
        let _ = language.selection
        Group {
            if loading {
                VStack(spacing: 16) { ProgressView(); Text(LF("正在连接 %@…", server.name)).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label(L("无法读取目录"), systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: { Button(L("重试")) { Task { await load() } } }
            } else {
                List {
                    if visibleEntries.isEmpty { Text(LF("此目录没有%@文件。", subtitlesOnly ? L("字幕") : L("视频"))).foregroundStyle(.secondary) }
                    ForEach(visibleEntries) { entry in
                        if entry.isDirectory {
                            NavigationLink {
                                SMBDirectoryView(server: server, path: entry.path, subtitlesOnly: subtitlesOnly, onSelect: onSelect)
                            } label: { row(entry) }
                        } else {
                            Button { select(entry) } label: { row(entry) }.buttonStyle(.plain)
                        }
                    }
                }.searchable(text: $query, prompt: L("搜索当前目录")).refreshable { await load() }
            }
        }
        .navigationTitle(path == "/" || path == server.rootURL?.path ? server.name : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: path) { await load() }
    }
    private var visibleEntries: [SMBEntry] {
        entries.filter { ($0.isDirectory || (subtitlesOnly ? $0.isSubtitle : $0.isVideo)) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }
    private func row(_ entry: SMBEntry) -> some View {
        Label(entry.name, systemImage: entry.isDirectory ? "folder.fill" : (subtitlesOnly ? "captions.bubble" : "film"))
            .padding(.vertical, 7).lineLimit(2)
    }
    private func load() async {
        loading = true; error = nil
        do { entries = try await SMBService.shared.list(server: server, path: path) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
    private func select(_ entry: SMBEntry) {
        let password = KeychainStore.password(for: server.id)
        guard let url = server.playbackURL(path: entry.path, password: password) else { error = L("文件地址无效。"); return }
        let base = (entry.name as NSString).deletingPathExtension
        let subtitles = subtitlesOnly ? [] : entries.filter {
            $0.isSubtitle && (($0.name as NSString).deletingPathExtension == base || $0.name.hasPrefix(base + "."))
        }.compactMap { server.playbackURL(path: $0.path, password: password) }
        onSelect(url, subtitles)
    }
}
