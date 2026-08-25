# Claude Sessions Monitor

See at a glance what your local Claude Code sessions are doing — and which one is
waiting for you.

Claude Code is happiest when you run several sessions at once. The problem is
knowing which one needs you: a session that asks for permission sits there
silently behind three other windows while you carry on somewhere else. This
project surfaces that state in three places that share one source of truth.

| Where | What it is |
|---|---|
| **Floating HUD** | A small always-on-top window on your desktop listing every session |
| **Cheap Yellow Display** | A £10 ESP32 touchscreen on your desk, with three physical buttons |
| **Web page** | The same list on your phone or tablet, on your own network |

Everything runs locally. Nothing leaves your machine: session state comes from
Claude Code's own hooks, and the web service listens only on your LAN.

```
                    Claude Code
                         |
                  hooks fire on every event
                         |
                    beacon.ps1
                         |
              session-status/*.json          one small file per session
                         |
                   sessionlib.ps1            state, cleanup, snooze, payload
                    /         \
              hud.ps1      session-api.ps1
                 |            /        \
           floating HUD   /cyd.txt   web page
                             |
                      Cheap Yellow Display
```

---

## Table of contents

- [How it works](#how-it-works)
- [Session states](#session-states)
- [Quick start](#quick-start)
- [The Cheap Yellow Display](#the-cheap-yellow-display)
- [Physical buttons and actions](#physical-buttons-and-actions)
- [Security: read this before exposing the API](#security-read-this-before-exposing-the-api)
- [Language](#language)
- [Repository layout](#repository-layout)
- [Requirements](#requirements)
- [Troubleshooting](#troubleshooting)
- [What is deliberately not here](#what-is-deliberately-not-here)
- [License](#license)

---

## How it works

Claude Code can run a command on every lifecycle event. This project registers
`beacon.ps1` for six of them. On each call the beacon writes one small JSON file
per session into `session-status/`, then merges everything into `sessions.json`.

The three views all read that same file, through two shared libraries:

- **`sessionlib.ps1`** — session states, reaping dead sessions, snooze, and
  building the payload every view consumes
- **`focuslib.ps1`** — working out which terminal window belongs to which
  session, and bringing it to the front

Two details turned out to matter more than expected, and both are worth knowing
if you fork this:

**The beacon records the PID of the Claude process.** Without it, a session whose
terminal was closed with the window's X button stays listed as "working" for an
hour, because no `SessionEnd` hook ever fires. With the PID, the session
disappears the moment the process does.

**`PostToolUse` is registered on purpose.** Between `Notification` (Claude asks
for permission) and `Stop` (Claude is finished), Claude Code fires nothing at
all. Without `PostToolUse`, a session you just approved stays orange until it
completely finishes, which is exactly the signal you do not want to lose trust
in. `PostToolUse` moves it back to green the moment work resumes.

## Session states

| Hook event | State | Colour | Meaning |
|---|---|---|---|
| `Notification` | **Needs you** | orange | Claude is asking for permission or input |
| `SessionStart`, `UserPromptSubmit`, `PostToolUse` | Working | green | Busy, nothing needed from you |
| `Stop` | Done | grey-blue | The answer is waiting to be read |
| `SessionEnd`, or the process is gone | removed | — | Disappears from every view |

Only orange is an alarm. The HUD flashes its top bar, the CYD beeps and turns its
on-board LED orange, and a tray notification appears. Everything else is
information, not interruption.

## Quick start

You need Windows with PowerShell 5.1 (present by default) and Claude Code.

### Option A — the installer

Build the package:

```
python build-pakket.py
```

That produces `ClaudeDeck.zip` containing only what is needed to run. Unpack it
and double-click `Install.cmd`. The installer copies the files, wires up the
Claude Code hooks (backing up your `settings.json` first), creates Start menu
shortcuts, optionally adds them to startup, and launches the HUD. See
[installer/README-installer.md](installer/README-installer.md).

### Option B — straight from this folder

```powershell
# 1. register the hooks (once)
powershell -ExecutionPolicy Bypass -File install-hooks.ps1

# 2. start the HUD
wscript.exe hud.vbs

# 3. optional: the web service for the display and your phone
wscript.exe api.vbs
```

Sessions that are already running pick up the hooks only after that session
restarts.

The HUD is draggable, remembers where you put it, and its right-click menu has
compact rows, an attention-only filter, autostart, and the address other devices
should use to reach your PC.

## The Cheap Yellow Display

The CYD is an ESP32-2432S028R: a 2.8" 320×240 ILI9341 touchscreen with an ESP32
on the back, sold for around £10. It polls your PC every three seconds and shows
one row per session. Tapping a row brings that terminal window to the front on
your PC — the same thing clicking in the HUD does.

Full build instructions are in **[cyd/README-cyd.md](cyd/README-cyd.md)**. The
short version:

1. Install the **TFT_eSPI** and **XPT2046_Touchscreen** libraries
2. Copy `cyd/User_Setup_CYD.h` over `TFT_eSPI/User_Setup.h`
3. Flash `cyd/claude_hud_cyd/claude_hud_cyd.ino` (board: ESP32 Dev Module)
4. Start the web service on your PC

You do **not** put your Wi-Fi password in the sketch. On first boot the display
brings up its own network called `Claude-Deck`; join it with your phone, and a
page opens where you pick your network, enter the password, and give it the
address of your PC. Settings are stored in NVS, so they survive reflashing, and
holding the top bar for two seconds brings the page back if anything changes.

A printable case with three mechanical buttons is in [case/](case/), including
the parametric generator that produced the STLs.

> **If the screen shows the wrong colours** — a magenta test fill coming out
> green, or two different dark greys both looking beige — the panel is inverted.
> `User_Setup_CYD.h` sets `TFT_INVERSION_ON` for this reason; none of the
> ILI9341 init sequences in TFT_eSPI send an inversion command themselves. This
> is worth knowing because it makes colour changes look like nothing happened.

## Physical buttons and actions

The three buttons on the case do whatever `actions.json` says. The display only
ever sends "button 2 on session X"; your PC decides what that means. The labels
shown along the bottom of the screen come from the same file, so changing them
does not mean reflashing.

The defaults are approve (Enter), reject (Escape), and snooze for ten minutes.

## Security: read this before exposing the API

**`/action` can send keystrokes into your terminal, and anyone on your network
can call it.** That is the entire point of the physical buttons, and it is also
the risk. Three things are in place by default:

- An action marked `requireAttention` only runs when that session is actually
  waiting for input, so a mis-tap cannot push Enter into a session that is busy
  working
- Every action is written to `actions.log`
- The service binds to your LAN only — it is not reachable from the internet
  unless you deliberately forward a port, which you should not do

On a network you do not fully trust, set `token` in `actions.json` and put the
same value in the sketch. And think about what the approve button does: it
confirms whatever is on screen at that moment, including a command you would
rather have read first. If that makes you uneasy, set button 1 to
`"type": "focus"` — then it just brings the window forward and you decide.

## Language

All visible text follows your Windows display language. Dutch and English ship
today; anything else falls back to English.

Every string lives in [`langlib.ps1`](langlib.ps1) — adding a language means
copying the `en` block and translating the values. Keys missing from a block
fall through to English, so a partial translation is fine.

The display gets its text from the PC, in the header line of `/cyd.txt`. It has
no table of its own, which means switching your Windows language changes the
display too, without reflashing. The handful of strings shown when there is *no*
connection have to live on the device — those are English by default, with a
`CYD_LANG_NL` switch in the sketch.

To test the other language without changing Windows:

```powershell
$env:CLAUDE_DECK_LANG = 'en'
wscript.exe hud.vbs
```

## Repository layout

| Path | What |
|---|---|
| `beacon.ps1`, `install-hooks.ps1` | the hooks that track session state |
| `sessionlib.ps1`, `focuslib.ps1` | shared logic |
| `langlib.ps1` | every user-visible string, in both languages |
| `hud.ps1`, `hud.vbs` | the floating HUD |
| `session-api.ps1`, `api.vbs`, `actions.json` | web service, and what the buttons do |
| `cyd/` | Arduino sketch, TFT settings, flashing and wiring instructions |
| `case/` | printable enclosure: STLs, parametric generator, build notes |
| `installer/` | installable package for other machines |
| `build-pakket.py` | builds `ClaudeDeck.zip` |
| `diagnose.ps1` | checks hooks, files and processes when something is off |
| `README-sessions.md` | the full manual |

## Requirements

- **Windows** with PowerShell 5.1 or newer
- **Claude Code** with hooks enabled
- For the display: **Arduino IDE** or `arduino-cli`, with **TFT_eSPI** (Bodmer)
  and **XPT2046_Touchscreen** (Paul Stoffregen)
- For editing the case: **Python** with `trimesh`, `manifold3d` and `shapely`

## Troubleshooting

Run `diagnose.ps1` first — it checks whether the hooks are registered, whether
status files are being written, and whether the HUD is running.

| Symptom | Likely cause |
|---|---|
| HUD stays empty | Hooks are not registered, or the sessions predate installing them — restart a session |
| Display says "no connection" | The web service is not running, or the PC address is stale. Hold the top bar for 2 seconds to fix the address |
| Display shows nothing but white | Wrong `User_Setup.h` — see [cyd/README-cyd.md](cyd/README-cyd.md) |
| Colours look inverted | Missing `TFT_INVERSION_ON`; the same file explains it |
| Sessions linger after closing a terminal | Older beacon without PID tracking — reinstall the hooks |
| Clicking a row opens the wrong window | Ctrl-click a row to see which windows were considered and why one was chosen |

## What is deliberately not here

`dashboard.html`, `sessions.json`, `session-status/` and `actions.log` are
generated and contain the prompts and titles of your sessions. They are in
`.gitignore` and will not be committed.

`dashboard.html` in particular is a personal page — it combines sessions with a
calendar and mail inbox — so it is not shipped. If the file is absent the HUD
hides its "Open dashboard" menu entry, and nothing else notices.

## License

MIT — see [LICENSE](LICENSE).
