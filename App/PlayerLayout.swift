// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit

struct PlayerLayout: Equatable {
    let size: CGSize
    let safe: UIEdgeInsets
    var rightToLeft = false
    var landscape: Bool { size.width > size.height }
    var panel: CGRect {
        let top = landscape ? safe.top + 76 : max(safe.top + 196, size.height * 0.43)
        let bottom = size.height - safe.bottom - 132
        let width = landscape ? min(360, size.width * 0.42) : max(1, size.width - safe.left - safe.right)
        return CGRect(x: landscape ? (rightToLeft ? safe.left + 12 : size.width - safe.right - width - 12) : safe.left,
                      y: top, width: width, height: max(80, bottom - top))
    }
    var preview: CGRect {
        let x = landscape && rightToLeft ? panel.maxX + 12 : safe.left + 12
        let y = safe.top + 76
        let right = landscape && !rightToLeft ? panel.minX - 12 : size.width - safe.right - 12
        let bottom = landscape ? size.height - safe.bottom - 132 : panel.minY - 8
        return CGRect(x: x, y: y, width: max(1, right - x), height: max(1, bottom - y))
    }
}
