// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Libmpv

private final class SMBOpenFile {
    let file: OpaquePointer
    let status: SMBStreamStatus
    init(file: OpaquePointer, status: SMBStreamStatus) { self.file = file; self.status = status }
}

final class SMBPlaybackStream {
    let status = SMBStreamStatus()
    private let lock = NSLock()
    private var routes: [String: URLComponents] = [:]

    func register(with handle: OpaquePointer) -> Int32 {
        mpv_stream_cb_add_ro(handle, "iinasmb", Unmanaged.passUnretained(self).toOpaque()) { context, uri, info in
            guard let context, let uri, let info else { return MPV_ERROR_LOADING_FAILED.rawValue }
            let router = Unmanaged<SMBPlaybackStream>.fromOpaque(context).takeUnretainedValue()
            guard let token = URLComponents(string: String(cString: uri))?.host,
                  let url = router.location(for: token), let host = url.host else { return MPV_ERROR_LOADING_FAILED.rawValue }
            let parts = url.path.split(separator: "/").map(String.init)
            guard let share = parts.first, parts.count > 1 else { return MPV_ERROR_LOADING_FAILED.rawValue }
            let authority = host + (url.port.map { ":\($0)" } ?? "")
            let rawLogin = (url.user ?? "").split(separator: ";", maxSplits: 1).map(String.init)
            let login = SMBLogin(username: rawLogin.last ?? "", domain: rawLogin.count > 1 ? rawLogin[0] : "")
            guard let file = iina_smb_open(authority, share, parts.dropFirst().joined(separator: "/"), login.domain, login.username, url.password ?? "") else {
                router.status.record(.current())
                return MPV_ERROR_LOADING_FAILED.rawValue
            }
            info.pointee.cookie = Unmanaged.passRetained(SMBOpenFile(file: file, status: router.status)).toOpaque()
            info.pointee.read_fn = { cookie, buffer, size in
                guard let cookie, let buffer else { return -1 }
                let open = Unmanaged<SMBOpenFile>.fromOpaque(cookie).takeUnretainedValue()
                let result = iina_smb_read(open.file, buffer, size)
                if result < 0, iina_smb_last_error_code() != 0 { open.status.record(.current()) }
                return result
            }
            info.pointee.seek_fn = { cookie, position in
                guard let cookie else { return -1 }
                return iina_smb_seek(Unmanaged<SMBOpenFile>.fromOpaque(cookie).takeUnretainedValue().file, position)
            }
            info.pointee.size_fn = { cookie in
                guard let cookie else { return -1 }
                return iina_smb_size(Unmanaged<SMBOpenFile>.fromOpaque(cookie).takeUnretainedValue().file)
            }
            info.pointee.cancel_fn = { cookie in
                if let cookie { iina_smb_cancel(Unmanaged<SMBOpenFile>.fromOpaque(cookie).takeUnretainedValue().file) }
            }
            info.pointee.close_fn = { cookie in
                if let cookie { iina_smb_close(Unmanaged<SMBOpenFile>.fromOpaque(cookie).takeRetainedValue().file) }
            }
            return 0
        }
    }
    func mediaPath(_ url: URL) -> String {
        if url.isFileURL { return url.path }
        guard url.scheme?.lowercased() == "smb", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        let token = UUID().uuidString.lowercased()
        lock.lock(); routes[token] = parts; lock.unlock()
        // Keep credentials and the original Unicode path out of mpv's URL parser.
        var routed = URLComponents()
        routed.scheme = "iinasmb"; routed.host = token; routed.path = "/" + url.lastPathComponent
        return routed.url!.absoluteString
    }
    func location(for token: String) -> URLComponents? { lock.lock(); defer { lock.unlock() }; return routes[token] }
    func reset() { lock.lock(); routes = [:]; lock.unlock(); status.reset() }
}
