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
Claude Code's own hooks, and the web service listens only on your LAN. The
display can also take the same data straight over its USB cable, so a network
that blocks the port does not leave you with a blank screen.

```
                    Claude Code
                         |
                  hooks fire on every event
                         |
                    beacon.ps1
                         |
              session-status/*.json      one small file per session
                         |
                   sessionlib.ps1        state, cleanup, snooze, payload
                    /         \
              hud.ps1      session-api.ps1
                 |          /     |     \
           floating HUD    /   web page   \
                          /               \
                   /cyd.txt over      the same payload
                   Wi-Fi (HTTP)       pushed over USB
                          \               /
                       Cheap Yellow Display
```

The display takes whichever of those two is available, so a network that
blocks the port does not leave you with a blank screen.

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
- [Running it on a Mac](#running-it-on-a-mac)
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

Download `ClaudeDeck.zip` from the
[latest release](https://github.com/dimitrihilverda/claude-sessions-monitor/releases/latest),
or build it yourself:

```
python build-pakket.py
```

Unpack it and double-click `Install.cmd`. The installer copies the files, wires
up the Claude Code hooks (backing up your `settings.json` first), creates Start
menu shortcuts, optionally adds them to startup, and launches the HUD. See
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

The HUD is draggable and remembers where you put it. Click a row to raise that
terminal; shift-click opens the folder instead, and ctrl-click shows which windows
were considered and why one was picked — useful when it lands on the wrong project.

Its right-click menu:

| Entry | For |
|---|---|
| Always on top, compact rows | Appearance |
| Only sessions that need me | Hide everything that is not asking for you |
| Address of this PC | The address to type into the display; clicking copies it |
| Open status page | The same list in a browser |
| Cracktro on the display | Fire the easter egg from here |
| Release the USB port | Hand the COM port back for a minute, so you can flash |
| Start when I log in | Autostart for the HUD and the web service |

## The Cheap Yellow Display

The CYD is an ESP32-2432S028R: a 2.8" 320×240 ILI9341 touchscreen with an ESP32
on the back, sold for around £10. It polls your PC every three seconds and shows
one row per session. Tapping a row brings that terminal window to the front on
your PC — the same thing clicking in the HUD does.

> **Raising a window taps the Alt key.** Windows will not let a program put
> itself in front while you are working in something else, and that refusal is a
> latch rather than a delay you can wait out: every call to raise the window
> reports success and nothing moves. Only the user pressing Alt or Esc releases
> it. So the HUD presses Alt — down and back up in the same breath, too briefly
> for a menu bar to open — and then asks. Without it, tapping a row worked only
> when the window was already in front, which is the one case where you did not
> need it.

### The other board: Guition JC3248W535C

The same firmware also runs on a Guition JC3248W535C — an ESP32-S3 with a
480×320 QSPI panel and capacitive touch. It shows five rows instead of four and
sets its type a size larger; everything else behaves identically, and the
[web flasher](https://dimitrihilverda.github.io/claude-sessions-monitor/) works
out which of the two you plugged in.

Three differences worth knowing. It has no RGB LED and no speaker on a plain pin,
so the status light and the attention beep are simply absent there. Its panel
cannot rotate in hardware and dislikes partial writes, so the whole frame is
drawn in PSRAM and pushed at once — which means a build without PSRAM enabled
will not run, and says so on the serial port rather than showing a blank screen.
And it speaks USB itself instead of through a CH340, so it needs no driver and
turns up as an Espressif device rather than a serial adapter.

> **Its touch controller answers even when nobody is touching it.** Asked out of
> the blue, the AXS15231B replies with whatever it last had — measured here, a
> point that never changes. So the firmware reads it only after its interrupt
> line has fallen, and checks that the answer could be a finger at all. Without
> both, the screen reads a permanent press along the top edge, opens its own
> setup portal a second after every boot, and from inside that portal it never
> looks at the cable again.

The easter egg is the CYD's alone: it talks to TFT_eSPI directly instead of going
through the drawing layer, which is exactly the kind of shortcut a second board
turns into work.

### Using it

| On the display | What it does |
|---|---|
| Tap a row | Select that session and raise its terminal window on your PC |
| Tap the top bar | Step the brightness (100 / 70 / 50 / 35 / 25 / 15 %) |
| Hold the top bar, 2 s | Open the setup page, to change Wi-Fi or the PC address |
| The three buttons | Whatever `actions.json` says - by default approve, reject, snooze |
| The arrows, past four sessions | Scroll the list. The third slot becomes them, and the third physical button pages down alongside |
| Hold BOOT, 2 s | An easter egg. Touch the screen or press anything to leave |

The top right corner answers "how is this thing being fed": **USB** while the
cable is pushing, and four bars for the radio whenever a network has been set at
all. Four dim bars mean it is configured and not connected right now, which is a
different thing from having no network, and both are different from a weak link.
That difference is worth showing: on this desk -66 dBm fetched sessions every
three seconds and -85 could not open a connection, and without the bars those two
look exactly alike.

Names and messages are flattened to plain ASCII by the PC before they are sent.
The font on both panels has nothing else, and the two transports fail differently
on the rest — the cable turns anything above 127 into a question mark, while over
Wi-Fi the UTF-8 bytes arrive intact and get drawn as two pieces of nonsense each.
Accents lose their marks, curly quotes and dashes are mapped, and anything truly
foreign becomes a question mark rather than disappearing.

More sessions than fit on screen are kept and scrolled, not dropped. A session
that starts asking for you scrolls itself into view, so a quiet screen really
does mean nothing wants you, and a hairline on the right edge shows there is
more below.

When it cannot reach the PC it says so and keeps trying, showing the attempt
count, how long contact has been gone, and the signal strength - enough to tell
"still trying" from "given up", and a range problem from a real fault.

### Flash it from your browser

**[dimitrihilverda.github.io/claude-sessions-monitor](https://dimitrihilverda.github.io/claude-sessions-monitor/)**
flashes the display over USB with no toolchain at all. That page is rebuilt from
this repository on every push, so it always carries the current firmware. Needs
desktop Chrome or Edge, because flashing uses Web Serial.

### Or with the Arduino IDE

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

On Windows you can usually skip that. Plugged into a PC running the service, a
display that has no network says so, and the PC answers with the networks it has
passwords for — it has them already — along with its own address. The display
picks: it scans, and takes the first one it can actually hear. That last part is
the point rather than a detail, because this radio is 2.4 GHz only while your PC
is perfectly happy on 5 GHz. Ask the PC which network to use and it will
confidently name one the display can never reach.

Only when the display has no network of its own, so nothing you set deliberately
is replaced, and never while the portal is open. Your password travels down the
USB cable and into NVS — the same place the portal would put it, but worth
knowing, since this happens without being asked. On macOS the key sits in the
Keychain behind a prompt per network, so that path keeps the portal.

A printable case with three mechanical buttons is in [case/](case/), including
the parametric generator that produced the STLs.

> **If the screen shows the wrong colours** — a magenta test fill coming out
> green, or two different dark greys both looking beige — the panel is inverted.
> `User_Setup_CYD.h` sets `TFT_INVERSION_ON` for this reason; none of the
> ILI9341 init sequences in TFT_eSPI send an inversion command themselves. This
> is worth knowing because it makes colour changes look like nothing happened.

## When the network is not an option

Office networks tend to block a port like 8787, and a guest network often blocks
traffic between devices entirely. The display then has nothing to poll — while
hanging off the laptop by a cable that could carry the same bytes.

So it does. The web service pushes the identical payload over USB serial every
three seconds, and the display prefers it whenever it is arriving. Nothing to
configure: plug it in and it uses the cable, unplug it and it goes back to Wi-Fi
by itself. Taps and button presses travel back the same way.

The port is found by which chip is on it, never by number: the same board has
turned up as COM12 and later as COM16 on one machine. That means two vendors,
because the two boards present differently — the CYD through its CH340, the
Guition through the ESP32-S3's own USB. With both plugged in the CYD wins, so a
machine that has been driving one carries on driving it.

One consequence worth knowing: the service holds the COM port, so a flash or a
serial monitor fails while it is attached. The HUD's right-click menu has
**"Release the USB port"** for exactly that — it lets go for a minute and
reattaches on its own, so there is nothing to switch back.

A board with no Wi-Fi settings that boots while nothing is pushing down the
cable puts up its setup portal, which is right — that is what the portal is
for. It also keeps reading the cable while it is up, and closes itself the
moment one starts feeding it. Not when you opened the portal yourself by
holding the top bar: you are typing a password, and a screen that vanishes
mid-word is its own kind of broken.

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
| `platformlib.ps1` | the few things Windows and macOS do not share |
| `langlib.ps1` | every user-visible string, in both languages |
| `hud.ps1`, `hud.vbs` | the floating HUD |
| `session-api.ps1`, `api.vbs`, `actions.json` | web service, and what the buttons do |
| `cyd/` | Arduino sketch, TFT settings, flashing and wiring instructions |
| `case/` | printable enclosure: STLs, parametric generator, build notes |
| `installer/` | installable package for other machines |
| `build-pakket.py` | builds `ClaudeDeck.zip`, the release package |
| `web/` | the browser flasher, published to GitHub Pages by CI |
| `diagnose.ps1` | checks hooks, files and processes when something is off |
| `selftest.ps1` | checks whether this machine can run the PC side at all |
| `README-sessions.md` | the full manual |

## Running it on a Mac

Most of this is portable and some of it is not, so here is the honest split.

**Works:** the hooks, reading and pruning sessions, session titles from the
transcript, the API, the status page in a browser, the display over Wi-Fi and
over USB, and tapping a row to bring something to the front.

**Does not:** the floating HUD. It is WinForms, which has no counterpart on
macOS, and a second UI written in something else is a second UI to keep in step
with the first. On a Mac you use the display, or open `http://localhost:8787/`.

**Coarser:** tapping a row. On Windows the right *window* is picked by matching
the session title against every open window's title — two projects in the same
editor end up in the right one. On macOS there is no window list to score, so
you get the right *application* and which tab is in front inside it is up to the
application.

### Setting it up

```sh
brew install powershell                 # PowerShell 7; the code is PowerShell
pwsh -NoProfile -File selftest.ps1      # what works on this machine, and what does not
pwsh -NoProfile -File install-hooks.ps1 # register the hooks in ~/.claude/settings.json
pwsh -NoProfile -File session-api.ps1   # the service the display talks to
```

Run `selftest.ps1` **first**. The Mac side was written without a Mac to try it
on, so instead of a page of "this should work" every assumption it rests on is a
check: the runtime, the paths, the hooks and whether their interpreter can even
start, the process table, reading beacons, the port, the cable, and whether
macOS will let us raise another application at all.

That last one is a permission, not code. The first time something is raised,
macOS asks whether your terminal may control System Events; until you agree,
tapping a row does nothing. Grant it under **System Settings > Privacy &
Security > Automation** (some versions want **Accessibility** as well).
`selftest.ps1` reports exactly this, so you do not have to guess which of the
two it was.

### What is not tested

Everything above compiles and runs on Windows, and the platform-specific halves
are exercised here — but not one line of the macOS path has run on a Mac. If
something is wrong, `selftest.ps1` is the place it will show, and the parsing of
`ps` output is the most likely candidate.

## Requirements

- **Windows** with PowerShell 5.1 or newer, or **macOS** with PowerShell 7
  (`brew install powershell`) — see [Running it on a Mac](#running-it-on-a-mac)
- **Claude Code** with hooks enabled
- For the display: **Arduino IDE** or `arduino-cli`, with **TFT_eSPI** (Bodmer)
  and **XPT2046_Touchscreen** (Paul Stoffregen); for the ESP32-S3 board also
  **GFX Library for Arduino** (moononournation)
- For editing the case: **Python** with `trimesh`, `manifold3d` and `shapely`

## Troubleshooting

Run `diagnose.ps1` first — it checks whether the hooks are registered, whether
status files are being written, and whether the HUD is running. On a Mac run
`selftest.ps1` instead: it checks the things that differ there, including the
permission macOS needs before anything can be brought to the front.

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
