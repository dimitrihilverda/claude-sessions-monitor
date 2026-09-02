//  DeckMenu.swift -- the right-click menu, and the two chores behind it.
//
//  The menu is rebuilt on every press rather than kept in sync. It has to read
//  the current sessions anyway for the hide submenu, and a menu that is built
//  from the truth each time cannot drift from it.

import AppKit

@MainActor
final class DeckMenu: NSObject, NSMenuDelegate {
    private let store: SessionStore
    private let onSettingsChanged: () -> Void

    init(store: SessionStore, onSettingsChanged: @escaping () -> Void) {
        self.store = store
        self.onSettingsChanged = onSettingsChanged
    }

    func build() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false

        add(m, L.t("menu.topmost"), check: store.settings.topmost) { [self] in
            store.settings.topmost.toggle(); onSettingsChanged()
        }
        add(m, L.t("menu.compact"), check: store.settings.compact) { [self] in
            store.settings.compact.toggle(); onSettingsChanged()
        }
        add(m, L.t("menu.onlyAttention"), check: store.settings.onlyAttention) { [self] in
            store.settings.onlyAttention.toggle(); onSettingsChanged()
        }

        m.addItem(hideSubmenu())
        m.addItem(.separator())

        add(m, L.t("menu.statusPage")) {
            NSWorkspace.shared.open(URL(string: "http://localhost:8787/")!)
        }

        let ip = LocalAddress.find()
        if let ip {
            add(m, L.t("menu.addressWith", "\(ip):8787")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("http://\(ip):8787/", forType: .string)
            }
        } else {
            add(m, L.t("menu.addressNone"), enabled: false) {}
        }

        m.addItem(.separator())

        if LaunchAgents.pwsh() == nil {
            add(m, L.t("mac.noPwsh"), enabled: false) {}
        } else {
            let auto = LaunchAgents.enabled
            add(m, L.t("menu.autostart"), check: auto) {
                // Both agents, always. The HUD without the service is an empty
                // window, and two switches for one outcome is one switch too many.
                auto ? LaunchAgents.disable() : LaunchAgents.enable()
            }
        }

        m.addItem(.separator())
        add(m, L.t("menu.restart")) { Relaunch.now() }
        add(m, L.t("menu.quit")) { NSApp.terminate(nil) }
        return m
    }

    private func hideSubmenu() -> NSMenuItem {
        let count = store.settings.hidden.count
        let item = NSMenuItem(title: count > 0
                              ? L.t("menu.hideListWith", String(count))
                              : L.t("menu.hideList"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let rows = store.rows
        if rows.isEmpty {
            add(sub, L.t("menu.hideNone"), enabled: false) {}
        } else {
            for s in rows {
                let title = s.name.isEmpty ? s.folder : s.name
                add(sub, title) { [self] in
                    store.settings.hide(s.sessionId); onSettingsChanged()
                }
            }
        }
        if count > 0 {
            sub.addItem(.separator())
            add(sub, L.t("menu.showAll", String(count))) { [self] in
                store.settings.unhideAll(); onSettingsChanged()
            }
        }
        item.submenu = sub
        return item
    }

    // MARK: - plumbing

    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }
    // The menu is thrown away after each press, so the targets have to be kept
    // alive by something that is not.
    private var actions: [Action] = []

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, check: Bool = false,
                     enabled: Bool = true, _ run: @escaping () -> Void) -> NSMenuItem {
        let a = Action(run)
        actions.append(a)
        if actions.count > 200 { actions.removeFirst(100) }
        let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
        item.target = a
        item.state = check ? .on : .off
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }
}

/// The address the display and your phone need. Same answer as the service's
/// own status line, worked out here so the menu does not have to ask it.
enum LocalAddress {
    static func find() -> String? {
        var out: String?
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: cur.pointee.ifa_name)
            // Skip the tunnels and bridges; en0 and friends are what a phone
            // on your wifi can actually reach.
            guard name.hasPrefix("en") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254") { out = ip; break }
        }
        return out
    }
}

/// Start at login, for the service and the window together.
enum LaunchAgents {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")

    static let apiLabel = "io.github.dimitrihilverda.claude-sessions-monitor.api"
    static let hudLabel = "io.github.dimitrihilverda.claude-sessions-monitor.hud"

    static var enabled: Bool {
        FileManager.default.fileExists(atPath: plist(apiLabel).path)
    }

    static func plist(_ label: String) -> URL {
        dir.appendingPathComponent("\(label).plist")
    }

    /// Homebrew puts pwsh in different places on Intel and Apple silicon, and
    /// the versioned path under Cellar breaks the first time you upgrade.
    static func pwsh() -> String? {
        ["/opt/homebrew/bin/pwsh", "/usr/local/bin/pwsh", "/usr/bin/pwsh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func enable() {
        guard let pwsh = pwsh() else { return }
        let api = Settings.folder.appendingPathComponent("session-api.ps1").path
        write(apiLabel, [pwsh, "-NoProfile", "-File", api])
        write(hudLabel, ["/usr/bin/open", "-a", Bundle.main.bundleURL.path])
        for l in [apiLabel, hudLabel] { launchctl("bootstrap", plist(l).path) }
    }

    static func disable() {
        for l in [apiLabel, hudLabel] {
            launchctl("bootout", plist(l).path)
            try? FileManager.default.removeItem(at: plist(l))
        }
    }

    private static func write(_ label: String, _ args: [String]) {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": args,
            "RunAtLoad": true,
            "KeepAlive": label == apiLabel,   // the window you may close; the service should stay
        ]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict,
                                                             format: .xml, options: 0)
        else { return }
        try? data.write(to: plist(label), options: .atomic)
    }

    private static func launchctl(_ verb: String, _ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = [verb, "gui/\(getuid())", path]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

enum Relaunch {
    static func now() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", "-a", Bundle.main.bundleURL.path]
        // A fresh instance cannot take the same bundle while this one holds it,
        // so hand over rather than race.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { try? p.run() }
        NSApp.terminate(nil)
    }
}
