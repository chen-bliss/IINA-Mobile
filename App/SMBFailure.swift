// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct SMBFailure: LocalizedError {
    let code: Int32
    let stage: Int32
    var ntStatus: UInt32 = 0
    var errorDescription: String? {
        let action: String
        switch stage {
        case 2: action = "读取共享列表"
        case 3: action = "读取文件夹"
        case 4: action = "打开视频文件"
        case 5: action = "读取文件大小"
        case 6: action = "读取视频数据"
        default: action = "登录服务器"
        }
        let help: String
        switch code {
        case 13, 1:
            help = stage == 1 ? "服务器拒绝了 SMB 登录。请检查账号、密码，以及该账号的 SMB 文件共享权限。Mac 的 SSH 登录成功不代表已开启该用户的 SMB 访问。" : "账号没有访问权限，请检查共享和文件权限。"
        case 2: help = "共享名称、文件夹或文件不存在。"
        case 60, 65, 50, 61, 110:
            help = "服务器不可达、拒绝连接或连接超时。请检查网络、端口和文件共享服务。"
        default: help = "SMB 操作未完成，请检查网络、端口和服务器的 SMB2 或 SMB3 服务。"
        }
        let specific = stage == 2 ? "若服务器不允许列出共享，请在服务器设置中手动填写共享名称。" : ""
        return "\(action)失败（错误 \(code)）。\(help)\(specific)"
    }
    static func current(fallback code: Int32 = 5) -> Self {
        let last = iina_smb_last_error_code()
        return Self(code: last == 0 ? code : last, stage: iina_smb_last_error_stage(), ntStatus: iina_smb_last_nt_status())
    }
}

final class SMBStreamStatus {
    private let lock = NSLock()
    private var failure: SMBFailure?
    func record(_ failure: SMBFailure) { lock.lock(); self.failure = failure; lock.unlock() }
    func reset() { lock.lock(); failure = nil; lock.unlock() }
    var latest: SMBFailure? { lock.lock(); defer { lock.unlock() }; return failure }
}
