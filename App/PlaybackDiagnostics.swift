// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Foundation

final class PlaybackDiagnostics {
    private let enabled = ProcessInfo.processInfo.arguments.contains("--diagnose-playback")
    private var samples: [[String: String]] = []
    private var ticks = 0
    init() {
        if enabled {
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Playback-Diagnostics.json")
            try? FileManager.default.removeItem(at: file)
        }
    }
    func record(read: (String) -> String?) {
        guard enabled else { return }
        ticks += 1
        guard ticks % 4 == 0 else { return }
        var sample = ["time": Date().ISO8601Format()]
        // Deliberately exclude media paths, titles and SMB credentials.
        for key in ["time-pos", "duration", "hwdec-current", "video-codec", "video-params/w", "video-params/h",
                    "container-fps", "estimated-vf-fps", "decoder-frame-drop-count", "frame-drop-count", "mistimed-frame-count",
                    "avsync", "paused-for-cache", "demuxer-cache-duration", "demuxer-cache-state", "pause", "idle-active"] {
            sample[key] = read(key) ?? "unavailable"
        }
        samples.append(sample)
        if samples.count > 120 { samples.removeFirst() }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Playback-Diagnostics.json")
        if let data = try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
#endif
