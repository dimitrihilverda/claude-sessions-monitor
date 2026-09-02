//  Notifier.swift -- the beep, and the rule about when not to beep.
//
//  The rule is the whole point of this file. A session that wants you stays
//  orange until you deal with it, and we poll every two seconds; announcing
//  the state rather than the change would beep at you thirty times a minute.

import Foundation
import AppKit
import UserNotifications

/// Remembers what each session was doing last time, and answers one question:
/// which of these just started waiting for you?
///
/// Deliberately free of AppKit so the tests can drive it directly.
struct AttentionWatcher {
    private var previous: [String: String] = [:]

    /// Sessions that went from something else to `attention` since last time.
    ///
    /// A session we have never seen before counts as a transition: it turned up
    /// already waiting, which is exactly the case you want to hear about.
    /// A snoozed one never counts -- that is what snoozing is.
    mutating func newlyWaiting(_ sessions: [Session]) -> [Session] {
        var fresh: [Session] = []
        for s in sessions where s.wantsAttention && !s.snoozed {
            if previous[s.sessionId] != "attention" { fresh.append(s) }
        }
        // Rebuild rather than update: a session that disappeared should be
        // forgotten, so that the same id coming back later beeps again.
        previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0.state) })
        return fresh
    }
}

/// Turns "these just started waiting" into a sound and a notification.
final class Notifier {
    private var watcher = AttentionWatcher()
    private var mayPost = false

    init() {
        // Asking for permission from a bundle that macOS does not recognise
        // throws rather than returning an error, so this is wrapped and the
        // sound is kept independent of it: no permission still means a beep.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { ok, _ in
                DispatchQueue.main.async { self.mayPost = ok }
            }
    }

    func handle(_ sessions: [Session]) {
        let fresh = watcher.newlyWaiting(sessions)
        guard !fresh.isEmpty else { return }

        if let sound = NSSound(named: "Submarine") { sound.play() } else { NSSound.beep() }

        guard mayPost else { return }
        for s in fresh {
            let c = UNMutableNotificationContent()
            c.title = s.name.isEmpty ? s.folder : s.name
            c.body  = s.why.isEmpty ? "wacht op jou" : s.why
            let req = UNNotificationRequest(identifier: s.sessionId + "-" + s.since,
                                            content: c, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }
}
