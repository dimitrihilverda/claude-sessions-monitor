//  HUDPanel.swift -- the window itself.
//
//  An NSPanel rather than an NSWindow: a panel can float above other apps
//  without stealing focus from them, which is the whole behaviour being asked
//  for. A window that came forward every time it had something to say would be
//  worse than no window.

import AppKit
import SwiftUI
import Combine

/// A transparent AppKit view that drags the window when you press it.
///
/// `isMovableByWindowBackground` alone is not enough with SwiftUI content:
/// hosted views swallow the mouseDown before AppKit gets to decide it was a
/// drag. Sitting this behind the content means anything the rows do not claim
/// -- the header, the gaps -- is a grip.
struct WindowDragArea: NSViewRepresentable {
    final class Grip: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        // Right-clicks belong to the panel's menu, not to us.
        override func rightMouseDown(with event: NSEvent) { super.rightMouseDown(with: event) }
    }
    func makeNSView(context: Context) -> NSView { Grip() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Hosts the SwiftUI content and owns the right-click menu.
///
/// SwiftUI does not pass right-clicks anywhere useful unless you attach a
/// `.contextMenu`, and a context menu per row is not what was asked for. The
/// event is caught here instead, one level below SwiftUI.
final class HUDContentView: NSView {
    var menuProvider: (() -> NSMenu)?

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

final class HUDPanel: NSPanel {
    private var store: SessionStore
    private var hosting: NSHostingView<SessionListView>!
    private var container: HUDContentView!
    private var bag = Set<AnyCancellable>()

    init(store: SessionStore, menuProvider: @escaping () -> NSMenu) {
        self.store = store
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        // Follow you between desktops, and do not vanish when something else
        // goes full screen -- the two ways an always-on-top window quietly
        // stops being always on top.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        container = HUDContentView(frame: .zero)
        container.menuProvider = menuProvider
        hosting = NSHostingView(rootView: SessionListView(store: store))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container

        applySettings()
        place()
        fit()

        // The content grows and shrinks with the number of rows, so the window
        // has to follow it. Anchored at the top edge: a list that grew downward
        // from where you left it is the one that stays where you put it.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.fit() }
            .store(in: &bag)

        NotificationCenter.default
            .addObserver(self, selector: #selector(remember),
                         name: NSWindow.didMoveNotification, object: self)
    }

    // Borderless panels refuse key status unless told otherwise, and without it
    // the approve and reject buttons never see a click.
    override var canBecomeKey: Bool { true }

    func applySettings() {
        level = store.settings.topmost ? .floating : .normal
    }

    private func place() {
        let s = store.settings
        if s.hasPosition {
            setFrameOrigin(NSPoint(x: s.x, y: s.y))
        } else if let screen = NSScreen.main {
            // Top right, a thumb's width in from the corner.
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.maxX - 340 - 24, y: f.maxY - 240))
        }
    }

    func fit() {
        let wanted = hosting.fittingSize
        guard wanted.height > 1 else { return }
        let top = frame.maxY
        var f = frame
        f.size = NSSize(width: 340, height: wanted.height)
        f.origin.y = top - wanted.height
        guard f.size != frame.size else { return }
        setFrame(f, display: true, animate: false)
    }

    @objc private func remember() {
        store.settings.x = frame.origin.x
        store.settings.y = frame.origin.y
    }
}
