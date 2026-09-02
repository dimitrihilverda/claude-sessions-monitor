//  Tests -- the logic that has no window.
//
//  Plain asserts rather than XCTest: XCTest wants a test bundle, a bundle
//  wants SwiftPM, and SwiftPM here would exist solely to run eleven checks.
//  Run with ./build.sh test.

import Foundation

var failures = 0
var checks = 0

func check(_ what: String, _ ok: Bool) {
    checks += 1
    if ok {
        print("  ok    \(what)")
    } else {
        failures += 1
        print("  FAIL  \(what)")
    }
}

func group(_ name: String) { print("\n\(name)") }

// ---------------------------------------------------------------- decoding

group("Reading what the service sends")

let real = """
{"generated":"2026-08-31T13:28:22+02:00","attention":1,"active":1,"done":0,"known":2,
 "sessions":[
  {"session_id":"aaa","snoozed":false,"event":"Notification","state":"attention",
   "cwd":"/Users/x/Code/thing","name":"Iets bouwen","folder":"thing","host_pid":0,
   "owner_pid":1,"tab":"","label":"Wacht op jou","why":"mag ik dit bestand aanpassen",
   "since":"13:28","updated":"","sort_ts":"","visible":true},
  {"session_id":"bbb","snoozed":false,"event":"PostToolUse","state":"active",
   "cwd":"/Users/x/Code/other","name":"Iets anders","folder":"other","host_pid":0,
   "owner_pid":2,"tab":"","label":"Actief","why":"maak ff stappenplan",
   "since":"13:28","updated":"","sort_ts":"","visible":true}]}
""".data(using: .utf8)!

let snap = try? JSONDecoder().decode(Snapshot.self, from: real)
check("a real payload decodes", snap != nil)
check("both sessions arrive", snap?.sessions.count == 2)
check("the name survives", snap?.sessions.first?.name == "Iets bouwen")
check("the reason survives", snap?.sessions.first?.why == "mag ik dit bestand aanpassen")
check("attention is counted", snap?.attention == 1)

let empty = #"{"generated":"","attention":0,"active":0,"done":0,"known":0,"sessions":[]}"#
    .data(using: .utf8)!
check("an empty list is not an error",
      (try? JSONDecoder().decode(Snapshot.self, from: empty))?.sessions.isEmpty == true)

check("nonsense is refused",
      (try? JSONDecoder().decode(Snapshot.self, from: Data("not json".utf8))) == nil)

// A payload from an older service, or one caught mid-write. One thin row beats
// no rows: the window should degrade, not go blank.
let thin = #"{"sessions":[{"session_id":"ccc"}]}"#.data(using: .utf8)!
let thinSnap = try? JSONDecoder().decode(Snapshot.self, from: thin)
check("a session missing every optional field still decodes", thinSnap?.sessions.count == 1)
check("and falls back to a harmless state", thinSnap?.sessions.first?.state == "done")

// ---------------------------------------------------------------- language

group("Text")

// A key added to one table and forgotten in the other falls back to English,
// which on a Dutch system looks like a typo rather than a missing translation.
// Cheaper to catch here than to notice in a screenshot.
check("both languages carry the same keys", L.keysMatch)
check("a known key is translated", L.t("menu.quit") != "menu.quit")
check("an unknown key gives itself back rather than crashing",
      L.t("no.such.key") == "no.such.key")
check("a placeholder is filled in", L.t("hud.hiddenCount", "3").contains("3"))

// ---------------------------------------------------------------- addressing

group("What it asks the service")

var plain = DeckAPI()
plain.port = 8787
plain.token = ""
check("the session list needs no token",
      plain.url("/sessions.json")?.absoluteString == "http://127.0.0.1:8787/sessions.json")
check("focus carries the session id",
      plain.url("/focus", ["id": "abc"])?.absoluteString == "http://127.0.0.1:8787/focus?id=abc")

var guarded = DeckAPI()
guarded.port = 8787
guarded.token = "s3cret"
// The token guards the two calls that do something. Sending it on the read as
// well would put it in the service log for no gain.
check("a token rides along on focus",
      guarded.url("/focus", ["id": "abc"])?.query?.contains("t=s3cret") == true)
check("and not on the session list",
      guarded.url("/sessions.json")?.query == nil)

// ---------------------------------------------------------------- ordering

group("What comes first")

let mixed = Snapshot(sessions: [
    Session(sessionId: "1", state: "done",      name: "klaar"),
    Session(sessionId: "2", state: "active",    name: "bezig"),
    Session(sessionId: "3", state: "attention", name: "wacht"),
])
check("what needs you is at the top", mixed.sorted.map(\.name) == ["wacht", "bezig", "klaar"])

// ---------------------------------------------------------------- filtering

group("Which rows you see")

var s = Settings()
check("everything shows by default", s.visible(mixed).count == 3)

s.onlyAttention = true
check("the filter leaves only orange", s.visible(mixed).map(\.name) == ["wacht"])

s.onlyAttention = false
s.hide("2")
check("a hidden session goes", s.visible(mixed).map(\.name) == ["wacht", "klaar"])
s.hide("2")
check("hiding it twice does not duplicate it", s.hidden.count == 1)
s.unhideAll()
check("show all brings it back", s.visible(mixed).count == 3)

// ---------------------------------------------------------------- settings file

group("Remembering where you left it")

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("claudedeck-hud-test-\(getpid())")
Settings.folder = tmp
Settings.file = tmp.appendingPathComponent("hud-macos.json")

check("a missing file gives the defaults", Settings.load() == Settings())

var saved = Settings()
saved.x = 1200; saved.y = 80
saved.compact = true
saved.hide("zzz")
saved.save()
let back = Settings.load()
check("the position comes back", back.x == 1200 && back.y == 80)
check("the switches come back", back.compact == true)
check("the hidden list comes back", back.hidden == ["zzz"])

try? "{ this is not json".write(to: Settings.file, atomically: true, encoding: .utf8)
check("a corrupt file gives the defaults rather than nothing",
      Settings.load() == Settings())

try? FileManager.default.removeItem(at: tmp)

// ---------------------------------------------------------------- the beep

group("When it beeps")

var watcher = AttentionWatcher()
let waiting = Session(sessionId: "a", state: "attention")
let working = Session(sessionId: "a", state: "active")

check("a session that turns up already waiting beeps",
      watcher.newlyWaiting([waiting]).count == 1)
check("and does not beep again while it keeps waiting",
      watcher.newlyWaiting([waiting]).isEmpty)

_ = watcher.newlyWaiting([working])
check("going back to waiting beeps again",
      watcher.newlyWaiting([waiting]).count == 1)

var snoozer = AttentionWatcher()
check("a snoozed session never beeps",
      snoozer.newlyWaiting([Session(sessionId: "b", state: "attention", snoozed: true)]).isEmpty)

var forgetful = AttentionWatcher()
_ = forgetful.newlyWaiting([waiting])
_ = forgetful.newlyWaiting([])          // the session ended
check("a session that ended and came back beeps",
      forgetful.newlyWaiting([waiting]).count == 1)

var many = AttentionWatcher()
check("two at once are two",
      many.newlyWaiting([waiting, Session(sessionId: "c", state: "attention")]).count == 2)

// ----------------------------------------------------------------

print("\n\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
