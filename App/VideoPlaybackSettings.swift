// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Persist the selected track's identity, not only its language: a movie can
// contain several English tracks (SDH, commentary, forced, different releases).
struct RememberedTrack: Codable, Equatable {
    var mode: String
    var id: Int?
    var title: String?
    var language: String?
    var codec: String?
    var externalIndex: Int?

    static func capture(_ selection: String, tracks: [MediaTrack], type: String) -> Self {
        guard let id = Int(selection), let track = tracks.first(where: { $0.id == id && $0.type == type }) else {
            return Self(mode: selection == "no" ? "no" : "auto")
        }
        let external = tracks.filter { $0.type == type && $0.external }
        return Self(mode: "track", id: id, title: track.title, language: track.language, codec: track.codec,
                    externalIndex: track.external ? external.firstIndex(where: { $0.id == id }) : nil)
    }
    func resolve(in tracks: [MediaTrack], type: String) -> String {
        guard mode == "track" else { return mode == "no" ? "no" : "auto" }
        let candidates = tracks.filter { $0.type == type && $0.external == (externalIndex != nil) }
        let exact = candidates.filter { $0.title == title && $0.language == language && $0.codec == codec }
        if let sameID = exact.first(where: { $0.id == id }) { return String(sameID.id) }
        if exact.count == 1, let track = exact.first { return String(track.id) }
        if let externalIndex, candidates.indices.contains(externalIndex) { return String(candidates[externalIndex].id) }
        // A removed or changed track should fall back safely to the user's default.
        return "auto"
    }
}

struct VideoPlaybackSettings: Codable, Equatable {
    var picture: PictureSettings
    var display: VideoDisplaySettings
    var rendering: RenderingMode
    var subtitle: RememberedTrack
    var audio: RememberedTrack
    var subtitleDelay: Double
    var subtitleSize: Double
    var speed: Double

    init(defaults: AppPreferences = .load()) {
        picture = defaults.picture; display = defaults.display; rendering = defaults.rendering
        subtitle = RememberedTrack(mode: defaults.subtitles == .off ? "no" : "auto")
        audio = RememberedTrack(mode: "auto")
        subtitleDelay = 0; subtitleSize = defaults.subtitleSize; speed = 1
    }
}
