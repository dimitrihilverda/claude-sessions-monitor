//  DeckAPI.swift -- the only place that knows where the service lives.
//
//  Three calls, all GET. The service does the hard part: it owns the session
//  state and it owns raising a window. This file owns neither, which is why
//  the HUD needs no Automation permission of its own.

import Foundation

/// One session, exactly as `/sessions.json` reports it.
///
/// Every field beyond the identity is optional. A payload from an older
/// service, or one caught mid-write, should leave us with a row that says
/// less rather than no rows at all.
struct Session: Codable, Identifiable, Equatable {
    let sessionId: String
    var state: String
    var name: String
    var folder: String
    var cwd: String
    var why: String
    var since: String
    var label: String
    var snoozed: Bool

    var id: String { sessionId }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case state, name, folder, cwd, why, since, label, snoozed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        state   = (try? c.decode(String.self, forKey: .state))  ?? "done"
        name    = (try? c.decode(String.self, forKey: .name))   ?? ""
        folder  = (try? c.decode(String.self, forKey: .folder)) ?? ""
        cwd     = (try? c.decode(String.self, forKey: .cwd))    ?? ""
        why     = (try? c.decode(String.self, forKey: .why))    ?? ""
        since   = (try? c.decode(String.self, forKey: .since))  ?? ""
        label   = (try? c.decode(String.self, forKey: .label))  ?? ""
        snoozed = (try? c.decode(Bool.self,   forKey: .snoozed)) ?? false
    }

    /// For the tests, which need to build one without a JSON round trip.
    init(sessionId: String, state: String, name: String = "", folder: String = "",
         cwd: String = "", why: String = "", since: String = "", label: String = "",
         snoozed: Bool = false) {
        self.sessionId = sessionId
        self.state = state
        self.name = name
        self.folder = folder
        self.cwd = cwd
        self.why = why
        self.since = since
        self.label = label
        self.snoozed = snoozed
    }

    /// Wanted by the sort and by half the UI, so it lives here rather than in
    /// four string comparisons scattered about.
    var wantsAttention: Bool { state == "attention" }

    /// attention first, then active, then done -- the order sessionlib.ps1 uses.
    var rank: Int {
        switch state {
        case "attention": return 0
        case "active":    return 1
        default:          return 2
        }
    }
}

struct Snapshot: Codable {
    var sessions: [Session]
    var attention: Int
    var active: Int
    var done: Int

    enum CodingKeys: String, CodingKey { case sessions, attention, active, done }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions  = (try? c.decode([Session].self, forKey: .sessions)) ?? []
        attention = (try? c.decode(Int.self, forKey: .attention)) ?? 0
        active    = (try? c.decode(Int.self, forKey: .active))    ?? 0
        done      = (try? c.decode(Int.self, forKey: .done))      ?? 0
    }

    init(sessions: [Session]) {
        self.sessions = sessions
        attention = sessions.filter { $0.state == "attention" }.count
        active    = sessions.filter { $0.state == "active" }.count
        done      = sessions.filter { $0.state == "done" }.count
    }

    /// The list as the HUD shows it: what needs you, at the top.
    var sorted: [Session] { sessions.sorted { $0.rank < $1.rank } }
}

enum DeckError: Error, LocalizedError {
    case unreachable
    case badPayload

    var errorDescription: String? {
        switch self {
        case .unreachable: return "geen verbinding met de service"
        case .badPayload:  return "de service antwoordde iets onverwachts"
        }
    }
}

/// Talks to session-api.ps1.
///
/// The timeout is deliberately short. A poll that hangs for the default 60 s
/// leaves the window showing stale rows with no hint that they are stale, and
/// the service is on localhost -- if it has not answered in a second and a
/// half it is not going to.
struct DeckAPI {
    var host: String = "127.0.0.1"
    /// CLAUDEDECK_PORT points the window at a stand-in service. That is how the
    /// states you cannot sit and wait for -- orange, and a service that is not
    /// answering -- get looked at before you ship them.
    var port: Int = ProcessInfo.processInfo.environment["CLAUDEDECK_PORT"]
        .flatMap(Int.init) ?? 8787
    var token: String = ""

    private var session: URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.5
        cfg.timeoutIntervalForResource = 3.0
        return URLSession(configuration: cfg)
    }

    // Internal rather than private so the tests can check the token rule
    // without standing up a server to be asked.
    func url(_ path: String, _ query: [String: String] = [:]) -> URL? {
        var c = URLComponents()
        c.scheme = "http"
        c.host = host
        c.port = port
        c.path = path
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        // The token guards /focus and /action only; /sessions.json is read-only
        // and the display polls it without one.
        if !token.isEmpty && path != "/sessions.json" {
            items.append(URLQueryItem(name: "t", value: token))
        }
        if !items.isEmpty { c.queryItems = items }
        return c.url
    }

    func fetch(_ done: @escaping (Result<Snapshot, DeckError>) -> Void) {
        guard let u = url("/sessions.json") else { return done(.failure(.unreachable)) }
        session.dataTask(with: u) { data, _, err in
            guard err == nil, let data else { return done(.failure(.unreachable)) }
            guard let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else {
                return done(.failure(.badPayload))
            }
            done(.success(snap))
        }.resume()
    }

    /// Bring that session's terminal to the front. The service answers with a
    /// sentence saying what it did or why it could not; we pass it on rather
    /// than inventing our own.
    func focus(_ sid: String, _ done: @escaping (String) -> Void = { _ in }) {
        call(url("/focus", ["id": sid]), done)
    }

    /// Button 1 is approve (Enter), 2 is reject (Esc) -- what actions.json says.
    func action(_ sid: String, button: Int, _ done: @escaping (String) -> Void = { _ in }) {
        call(url("/action", ["id": sid, "b": String(button)]), done)
    }

    private func call(_ u: URL?, _ done: @escaping (String) -> Void) {
        guard let u else { return done("geen verbinding met de service") }
        session.dataTask(with: u) { data, _, err in
            if err != nil { return done("geen verbinding met de service") }
            done(String(data: data ?? Data(), encoding: .utf8) ?? "")
        }.resume()
    }
}
