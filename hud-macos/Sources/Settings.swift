//  Settings.swift -- where the window was, and which switches you left on.
//
//  Lives next to the service's own files so that uninstalling ClaudeDeck takes
//  this with it. It is a separate file from actions.json on purpose: that one
//  is yours to edit and the HUD never writes to it.

import Foundation

struct Settings: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 340
    var topmost: Bool = true
    var compact: Bool = false
    var onlyAttention: Bool = false
    var hidden: [String] = []

    /// A window that has never been placed. Nil-able coordinates would say this
    /// more plainly, but they would also mean an Optional in every arithmetic
    /// expression that positions the thing.
    var hasPosition: Bool { x != 0 || y != 0 }

    static var folder = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudeDeck")

    // var rather than let so the tests can point both at a temporary folder;
    // nothing in the app changes them.
    static var file = folder.appendingPathComponent("hud-macos.json")

    /// Never throws. A missing file is the normal first run, and a corrupt one
    /// is not worth refusing to start over -- you would lose the window rather
    /// than the settings.
    static func load() -> Settings {
        guard let data = try? Data(contentsOf: file),
              let s = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return s
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Settings.folder,
                                                 withIntermediateDirectories: true)
        try? data.write(to: Settings.file, options: .atomic)
    }

    func isHidden(_ sid: String) -> Bool { hidden.contains(sid) }

    mutating func hide(_ sid: String) {
        guard !hidden.contains(sid) else { return }
        hidden.append(sid)
    }

    mutating func unhideAll() { hidden.removeAll() }

    /// Everything the window should draw, in the order it should draw it.
    ///
    /// One function rather than a filter in the view, because "which rows do
    /// you see" is the question two of the three switches answer, and having
    /// that in one place is what makes it testable.
    func visible(_ snapshot: Snapshot) -> [Session] {
        snapshot.sorted.filter { s in
            if isHidden(s.sessionId) { return false }
            if onlyAttention && !s.wantsAttention { return false }
            return true
        }
    }
}

/// Reads the token out of the service's actions.json, if you set one.
///
/// Read once at startup and not watched: changing it means restarting the
/// service anyway, and the menu has a Restart.
enum ActionsConfig {
    static func token() -> String {
        let url = Settings.folder.appendingPathComponent("actions.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["token"] as? String
        else { return "" }
        return t
    }
}
