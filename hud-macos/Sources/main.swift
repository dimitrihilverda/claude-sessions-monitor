//  main.swift -- tie the pieces together and get out of the way.

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: SessionStore!
    private var panel: HUDPanel!
    private var menu: DeckMenu!

    func applicationDidFinishLaunching(_ note: Notification) {
        store = SessionStore()
        menu = DeckMenu(store: store) { [weak self] in self?.settingsChanged() }
        panel = HUDPanel(store: store, menuProvider: { [weak self] in
            self?.menu.build() ?? NSMenu()
        })
        panel.orderFrontRegardless()
        store.start()
        if ProcessInfo.processInfo.environment["HUD_DEBUG"] != nil { report() }
    }

    /// HUD_DEBUG=1 prints where the window ended up and what the menu would
    /// say. Worth keeping: a borderless panel that lands on the wrong screen is
    /// indistinguishable from one that never opened, and clicking about on
    /// someone else's Mac is not a way to tell the two apart.
    private func report() {
        func say(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        say("frame=\(panel.frame) visible=\(panel.isVisible) level=\(panel.level.rawValue)")
        for screen in NSScreen.screens {
            say("screen \(screen.localizedName): \(screen.visibleFrame)")
        }
        func dump(_ m: NSMenu, _ indent: String) {
            for i in m.items {
                if i.isSeparatorItem { say(indent + "---"); continue }
                say(indent + (i.state == .on ? "[x] " : "") + i.title)
                if let sub = i.submenu { dump(sub, indent + "    ") }
            }
        }
        say("menu:")
        dump(menu.build(), "  ")
    }

    private func settingsChanged() {
        panel.applySettings()
        panel.fit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}

// Top-level code is not on the main actor as far as the compiler is concerned,
// but this is the main thread and nothing has started yet, so saying so is
// honest rather than a way round the check.
let app = MainActor.assumeIsolated { () -> NSApplication in
    let app = NSApplication.shared
    // .accessory, not .regular: no dock icon and no menu bar of its own. A HUD
    // that took over the menu bar every time you clicked it would be a strange
    // sort of always-on-top.
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    // The delegate is the only strong reference; NSApplication does not keep one.
    objc_setAssociatedObject(app, "hud.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    return app
}
app.run()
