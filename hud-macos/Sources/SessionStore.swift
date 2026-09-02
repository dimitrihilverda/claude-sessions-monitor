//  SessionStore.swift -- polls the service and publishes what it found.
//
//  Knows nothing about windows. The one thing worth reading twice is what it
//  does when a poll fails: it drops the `connected` flag and leaves the rows
//  alone, so the view can say what actually happened. An empty list means "no
//  sessions", which is a different problem with a different fix, and showing
//  one when you mean the other is how people end up reinstalling something
//  that was never broken.

import Foundation
import SwiftUI

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var snapshot = Snapshot(sessions: [])
    @Published private(set) var connected = false
    /// Nil until the first answer arrives, so the window can say "verbinden..."
    /// rather than flashing an error it does not yet have grounds for.
    @Published private(set) var everConnected = false
    @Published var settings = Settings.load() { didSet { settings.save() } }
    @Published var notice: String? = nil

    private let notifier = Notifier()
    private var timer: Timer?
    var api: DeckAPI

    init(api: DeckAPI = DeckAPI()) {
        self.api = api
        self.api.token = ActionsConfig.token()
    }

    /// Every two seconds. The display polls at three; a window you are looking
    /// at can afford to be a little quicker, and the service answers from a
    /// cache so the extra poll costs it nothing.
    func start(interval: TimeInterval = 2.0) {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func poll() {
        api.fetch { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let snap):
                    self.snapshot = snap
                    self.connected = true
                    self.everConnected = true
                    self.notifier.handle(snap.sessions)
                case .failure:
                    self.connected = false
                }
            }
        }
    }

    var rows: [Session] { settings.visible(snapshot) }

    /// How many rows the switches are keeping off screen. The menu says this
    /// out loud, because "only what needs me" plus a quiet afternoon looks
    /// exactly like a broken install.
    var hiddenCount: Int { snapshot.sessions.count - rows.count }

    func focus(_ s: Session) {
        api.focus(s.sessionId) { [weak self] answer in
            Task { @MainActor in self?.report(answer) }
        }
    }

    func act(_ s: Session, button: Int) {
        api.action(s.sessionId, button: button) { [weak self] answer in
            Task { @MainActor in self?.report(answer) }
        }
    }

    /// The service answers in prose. Anything that reads like a refusal is
    /// worth showing once; "ok ..." is not worth showing at all.
    private func report(_ answer: String) {
        let t = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.lowercased().hasPrefix("ok") else { return }
        notice = t
        // Long enough to read, short enough that it does not become furniture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            Task { @MainActor in if self?.notice == t { self?.notice = nil } }
        }
    }
}
