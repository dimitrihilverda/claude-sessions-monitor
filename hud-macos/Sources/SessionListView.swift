//  SessionListView.swift -- the rows.
//
//  Colours are lifted from hud.ps1 and the service's own status page rather
//  than picked again here. Three interfaces onto one set of sessions should
//  not disagree about what orange means.

import SwiftUI

enum Palette {
    static let bg     = Color(red:  31/255, green:  38/255, blue:  47/255)
    static let row    = Color(red:  38/255, green:  46/255, blue:  56/255)
    static let line   = Color(red:  56/255, green:  66/255, blue:  79/255)
    static let text   = Color(red: 240/255, green: 244/255, blue: 249/255)
    static let muted  = Color(red: 138/255, green: 151/255, blue: 166/255)
    static let green  = Color(red: 141/255, green: 198/255, blue:  63/255)
    static let orange = Color(red: 232/255, green: 163/255, blue:  61/255)
    static let steel  = Color(red: 155/255, green: 176/255, blue: 199/255)

    static func forState(_ s: String) -> Color {
        switch s {
        case "attention": return orange
        case "active":    return green
        default:          return steel
        }
    }
}

struct SessionListView: View {
    @ObservedObject var store: SessionStore

    private var compact: Bool { store.settings.compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !store.connected && store.everConnected {
                banner(L.t("mac.noService"), L.t("mac.noServiceHint"))
            } else if !store.everConnected {
                banner(L.t("mac.connecting"), L.t("mac.connectingHint"))
            } else if store.rows.isEmpty {
                empty
            } else {
                VStack(spacing: compact ? 3 : 6) {
                    ForEach(store.rows) { s in
                        SessionRow(session: s, compact: compact,
                                   onFocus: { store.focus(s) },
                                   onAction: { store.act(s, button: $0) })
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            if let notice = store.notice { footer(notice) }
        }
        .frame(width: 340, alignment: .leading)
        // The grip sits in front of the colour but behind every row, so
        // dragging works anywhere the rows have not claimed.
        .background(ZStack { Palette.bg; WindowDragArea() })
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
    }

    // The header doubles as the grip: it is the one strip guaranteed to be
    // free of anything clickable, so dragging there can never also mean
    // "raise that terminal".
    private var header: some View {
        HStack(spacing: 6) {
            Text(L.t("app.header"))
                .font(.system(size: 10, weight: .semibold))
                .kerning(1.2)
                .foregroundColor(Palette.muted)
            Spacer()
            // Not while disconnected: a count over a banner saying we cannot
            // reach the service is a number from the past presented as news.
            if store.connected && store.snapshot.attention > 0 {
                Text("\(store.snapshot.attention)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Palette.bg)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Palette.orange)
                    .clipShape(Capsule())
            }
            if store.hiddenCount > 0 {
                Text(L.t("hud.hiddenCount", String(store.hiddenCount)))
                    .font(.system(size: 9))
                    .foregroundColor(Palette.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10).padding(.bottom, 8)
        .contentShape(Rectangle())
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L.t(store.settings.onlyAttention ? "mac.nothingWaiting" : "mac.noSessions"))
                .font(.system(size: 12)).foregroundColor(Palette.text)
            Text(L.t(store.settings.onlyAttention ? "mac.filterOn" : "mac.noSessionsHint"))
                .font(.system(size: 10)).foregroundColor(Palette.muted)
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    private func banner(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12)).foregroundColor(Palette.orange)
            Text(sub).font(.system(size: 10)).foregroundColor(Palette.muted)
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.bottom, 10)
    }
}

private struct SessionRow: View {
    let session: Session
    let compact: Bool
    let onFocus: () -> Void
    let onAction: (Int) -> Void

    @State private var hovering = false

    private var accent: Color { Palette.forState(session.state) }
    private var title: String {
        let n = session.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? session.folder : n
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(accent).frame(width: 3)
            VStack(alignment: .leading, spacing: compact ? 0 : 2) {
                Text(title)
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                    .foregroundColor(Palette.text)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(session.folder).lineLimit(1)
                    if !session.since.isEmpty { Text("·"); Text(session.since) }
                    if !session.label.isEmpty { Text("·"); Text(session.label) }
                }
                .font(.system(size: 10))
                .foregroundColor(Palette.muted)
                if !compact && !session.why.isEmpty {
                    Text(session.why)
                        .font(.system(size: 10))
                        .foregroundColor(session.wantsAttention ? accent : Palette.muted)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, compact ? 5 : 8)
            .padding(.leading, 9)
            Spacer(minLength: 4)

            // Only on an orange row. The service refuses these on a session
            // that is not asking for anything (requireAttention in
            // actions.json), so showing them elsewhere would promise something
            // that does not happen.
            if session.wantsAttention {
                HStack(spacing: 4) {
                    tap(L.t("mac.approve"), L.t("mac.approveTip"),
                        Palette.green) { onAction(1) }
                    tap(L.t("mac.reject"), L.t("mac.rejectTip"),
                        Palette.steel) { onAction(2) }
                }
                .padding(.trailing, 8)
            }
        }
        .background(hovering ? Palette.line : Palette.row)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onFocus)
        .help(L.t("mac.focusTip"))
    }

    // Words rather than symbols. These send a keystroke into a session you are
    // not looking at; the button should say which one, not leave you reading a
    // glyph at ten points.
    private func tap(_ label: String, _ tip: String, _ colour: Color,
                     _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(colour)
                .padding(.horizontal, 6)
                .frame(height: 19)
                .background(Palette.bg.opacity(0.65))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(colour.opacity(0.35), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}
