//  Strings.swift -- user-visible text, in the language of macOS.
//
//  The Swift counterpart of langlib.ps1, key for key where a key already
//  exists there, so that changing a word on one side tells you plainly which
//  word to change on the other. Same rule as the rest of the project: Dutch if
//  the system asks for Dutch, English for everything else -- an unknown
//  language is better served by English than by Dutch.
//
//  Keys beginning with `mac.` have no counterpart on Windows. They belong to
//  states this window can be in and the WinForms HUD cannot: no service
//  answering, and the two keys it puts on a row that needs you.
//
//  Adding a language: copy the `en` table, translate the values, and add it to
//  `tables`. A key missing from a table falls through to English.

import Foundation

enum L {
    static func t(_ key: String, _ args: CVarArg...) -> String {
        let table = tables[language] ?? en
        let raw = table[key] ?? en[key] ?? key
        return args.isEmpty ? raw : String(format: raw, arguments: args)
    }

    /// Read once. Changing your system language restarts your apps anyway.
    static let language: String = {
        let want = Locale.preferredLanguages.first ?? "en"
        return want.hasPrefix("nl") ? "nl" : "en"
    }()

    private static let tables = ["en": en, "nl": nl]

    /// Every table carries every key. Checked by the tests: a key added to one
    /// and forgotten in the other falls back to English, which on a Dutch
    /// system reads as a typo rather than as a missing translation.
    static var keysMatch: Bool {
        tables.values.allSatisfy { Set($0.keys) == Set(en.keys) }
    }

    private static let en: [String: String] = [
        "app.header":          "CLAUDE SESSIONS",
        "hud.hiddenCount":     "%@ hidden",

        "menu.topmost":        "Always on top",
        "menu.compact":        "Compact rows",
        "menu.onlyAttention":  "Only sessions that need me (hides the rest)",
        "menu.hideList":       "Hide sessions",
        "menu.hideListWith":   "Hide sessions (%@ hidden)",
        "menu.hideNone":       "(no sessions running)",
        "menu.showAll":        "Show all again (%@)",
        "menu.statusPage":     "Open status page",
        "menu.addressWith":    "Address of this Mac:  %@",
        "menu.addressNone":    "Address of this Mac:  no network",
        "menu.autostart":      "Start when I log in",
        "menu.restart":        "Restart HUD",
        "menu.quit":           "Quit HUD",

        "mac.noService":       "no connection to the service",
        "mac.noServiceHint":   "start session-api.ps1 again",
        "mac.connecting":      "connecting to the service...",
        "mac.connectingHint":  "is session-api.ps1 running?",
        "mac.noSessions":      "no sessions",
        "mac.noSessionsHint":  "hooks only apply from the next session on",
        "mac.nothingWaiting":  "nothing needs you",
        "mac.filterOn":        "the filter is on -- right-click",
        "mac.approve":         "Enter",
        "mac.reject":          "Esc",
        "mac.approveTip":      "approve -- confirms whatever is on your screen right now",
        "mac.rejectTip":       "reject -- sends Esc",
        "mac.focusTip":        "click to bring this window to the front",
        "mac.noPwsh":          "PowerShell 7 not found, so there is nothing to start at login",
    ]

    private static let nl: [String: String] = [
        "app.header":          "CLAUDE-SESSIES",
        "hud.hiddenCount":     "%@ verborgen",

        "menu.topmost":        "Altijd bovenop",
        "menu.compact":        "Compacte rijen",
        "menu.onlyAttention":  "Alleen aandacht nodig (verbergt de rest)",
        "menu.hideList":       "Sessies verbergen",
        "menu.hideListWith":   "Sessies verbergen (%@ verborgen)",
        "menu.hideNone":       "(geen sessies actief)",
        "menu.showAll":        "Alles weer tonen (%@)",
        "menu.statusPage":     "Statuspagina openen",
        "menu.addressWith":    "Adres van deze Mac:  %@",
        "menu.addressNone":    "Adres van deze Mac:  geen netwerk",
        "menu.autostart":      "Starten bij inloggen",
        "menu.restart":        "HUD herstarten",
        "menu.quit":           "HUD afsluiten",

        "mac.noService":       "geen verbinding met de service",
        "mac.noServiceHint":   "start session-api.ps1 opnieuw",
        "mac.connecting":      "verbinden met de service...",
        "mac.connectingHint":  "draait session-api.ps1 wel?",
        "mac.noSessions":      "geen sessies",
        "mac.noSessionsHint":  "hooks gelden pas vanaf een volgende sessie",
        "mac.nothingWaiting":  "niets wacht op jou",
        "mac.filterOn":        "het filter staat aan -- rechtermuisknop",
        "mac.approve":         "Enter",
        "mac.reject":          "Esc",
        "mac.approveTip":      "goedkeuren -- bevestigt wat er nu op je scherm staat",
        "mac.rejectTip":       "weigeren -- stuurt Esc",
        "mac.focusTip":        "klik om dit venster naar voren te halen",
        "mac.noPwsh":          "PowerShell 7 niet gevonden, dus er valt niets te starten",
    ]
}
