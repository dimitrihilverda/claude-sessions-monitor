# Claude Sessions Monitor

See at a glance what your local Claude Code sessions are doing — and which one is
waiting for you.

Claude Code is happiest when you run several sessions at once. The problem is
knowing which one needs you: a session that asks for permission sits there
silently behind three other windows while you carry on somewhere else. This
project surfaces that state in three places that share one source of truth.

| Where | What it is |
|---|---|
| **Floating HUD** | A small always-on-top window on your desktop listing every session — WinForms on Windows, AppKit on macOS |
| **Cheap Yellow Display** | A £10 ESP32 touchscreen on your desk, with three physical buttons |
| **Guition JC3248W535C** | The same thing on twice the pixels, with capacitive touch — [the nicer screen](#the-bigger-screen-guition-jc3248w535c) |
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
              the display: a CYD, or a Guition S3
```

The display takes whichever of those two is available, so a network that
blocks the port does not leave you with a blank screen.

---

## Table of contents

- [How it works](#how-it-works)
- [Session states](#session-states)
- [Quick start](#quick-start)
- [The Cheap Yellow Display](#the-cheap-yellow-display)
- [The bigger screen: Guition JC3248W535C](#the-bigger-screen-guition-jc3248w535c)
- [When the network is not an option](#when-the-network-is-not-an-option)
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

**Right-click a row to put that session away.** It disappears from the HUD, from
the web page and from the display, and it stays away — no timer, unlike snooze.
The header then says how many are hidden.

The way back is in the menu, under **Hide sessions**: every running session with
a tick in front of the hidden ones. Tick one to hide it, untick it to bring it
back, or use *Show all again* at the bottom.

Its right-click menu:

| Entry | For |
|---|---|
| Always on top, compact rows | Appearance |
| Only sessions that need me | Hide everything that is not asking for you |
| Hide sessions | Every running session, ticked = hidden - tick and untick to hide and show |
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

This is not the only board it drives, and no longer the one to buy: the same
firmware runs on a Guition JC3248W535C, on twice the pixels and with capacitive
touch. See [The bigger screen](#the-bigger-screen-guition-jc3248w535c) below —
everything in this section applies to both unless it says otherwise.

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

That is the CYD. For the Guition S3 it is the same sketch with other build
settings and another library —
[Hanging it on](#hanging-it-on) has the exact line.

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

## The bigger screen: Guition JC3248W535C

You can hang a Guition JC3248W535C on this instead, and if you are buying a
board today, buy this one. It is an ESP32-S3 with an AXS15231B panel over QSPI:
480×320 where the CYD is 320×240, which is exactly twice the pixels, with
capacitive touch instead of a resistive layer you have to press with a
fingernail. Same firmware, same flasher, same service — plug it in and it is
simply a nicer thing to look at across the desk.

| | Cheap Yellow Display | Guition JC3248W535C |
|---|---|---|
| Chip | ESP32 | ESP32-S3, PSRAM required |
| Panel | 320×240 ILI9341 over SPI | 480×320 AXS15231B over QSPI |
| Touch | resistive, XPT2046 on SPI | capacitive, on the panel controller itself |
| Sessions on screen | four rows of 41 px | five rows of 46 px |
| Type | TFT_eSPI fonts, proportional | built-in font at 12×16 and 18×24, monospaced |
| USB | CH340 bridge, may want a driver | native USB, no driver at all |
| Status LED | RGB LED on the board | none |
| Attention beep | speaker on a plain pin | none — audio here is I2S into an NS4168 |
| Physical buttons | three on the JST connectors, plus BOOT | BOOT only |
| Easter egg | yes | no |
| Drawing | straight to the glass | full frame in PSRAM, pushed in one go |

Where the extra pixels go: a fifth session on screen, a taller header, type one
size up, and truncation limits that are exact rather than careful. The CYD's two
fonts are proportional, so a session name is cut at 34 characters to be safe —
often earlier than it had to be. On the S3 a row is 468 px wide less a 16 px
indent at 12 px per character, so 29 characters is the real number and the line
fills out to it every time; the reason line is 37, measured the same way.

What you give up is small but real. No RGB status light and no beep, because
there is no LED and no speaker on a plain pin — audio on this board goes through
an I2S amplifier, which is a different mechanism entirely and not worth carrying
for one beep. One button instead of three, unless you wire your own. And no
cracktro: the easter egg talks to TFT_eSPI directly instead of going through the
drawing layer, which is exactly the kind of shortcut a second board turns into
work.

One honest point in the CYD's favour: its type is proportional and the S3's is
the library's built-in 6×8 font scaled up, which is plainer up close. A
proportional face generated from a TTF would fix that and is the obvious next
improvement, at about 90 KB of flash per face.

> **Its touch controller answers even when nobody is touching it.** Asked out of
> the blue, the AXS15231B replies with whatever it last had — measured here, a
> point that never changes. So the firmware reads it only after its interrupt
> line has fallen, and checks that the answer could be a finger at all. Without
> both, the screen reads a permanent press along the top edge, opens its own
> setup portal a second after every boot, and from inside that portal it never
> looks at the cable again.

### Hanging it on

1. **Plug it in.** It speaks USB itself rather than through a CH340, so there is
   no driver to install and it turns up as an Espressif device.
2. **Flash it** from
   [the web flasher](https://dimitrihilverda.github.io/claude-sessions-monitor/).
   Nothing to choose: the manifest carries both builds and the page reads the
   chip family off the board you plugged in. It carries the offsets too, which
   matters more than it sounds — the bootloader sits at 0x1000 on the ESP32 and
   at 0x0 on the S3, and getting that wrong gives a board that flashes without
   complaint and never boots.
3. **Start the service** as usual. It finds the board by chip and then asks it
   who it is, so the other ESP32-S3s on your bench keep their ports — see
   [When the network is not an option](#when-the-network-is-not-an-option).
4. **Give it a network**, through the portal on first boot, or let the cable
   hand yours over on Windows. Both work exactly as they do on the CYD.

From the Arduino IDE it wants the S3's build settings, and PSRAM is not optional
there: the 480×320 frame buffer is 300 KB and does not fit in internal RAM next
to Wi-Fi. Without it the firmware refuses to start and says so on the serial
port, rather than showing you a blank screen. CI builds it with exactly this,
which is the shortest correct answer to "what do I set":

```bash
arduino-cli compile \
  --fqbn "esp32:esp32:esp32s3:PSRAM=opi,FlashSize=16M,PartitionScheme=huge_app,FlashMode=qio,CPUFreq=240,USBMode=hwcdc,CDCOnBoot=cdc" \
  --build-property "compiler.cpp.extra_flags=-DBOARD_KIND=BOARD_S3" \
  cyd/claude_hud_cyd
```

`BOARD_KIND=BOARD_S3` is the part that matters in the sketch: it picks the
drawing backend in `gfx.h` and the layout metrics in `board.h`. Leave it out and
you get a CYD build, which compiles happily and draws nothing on this panel.
This board does not use TFT_eSPI at all — it goes through **GFX Library for
Arduino** — so `User_Setup_CYD.h` and the colour-inversion note above are the
CYD's business, not yours here.

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

Being the right chip is not enough to get claimed, though. Every ESP32-S3 in the
world has the same vendor id as the Guition, and a bench with other projects on
it is the normal case — so the service asks each candidate who it is, and keeps
only the port that answers with the display's firmware version. A board that
stays quiet is left alone within the second, and stops being asked at all after
three tries. Your other boards stay flashable while the display keeps running.

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
| `hud.ps1`, `hud.vbs` | the floating HUD on Windows |
| `hud-macos/` | the floating window on macOS: Swift sources, and the script that builds them |
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

**Works, differently:** the floating HUD. The WinForms one has no counterpart
on macOS, so there is a second one in `hud-macos/` — native AppKit and SwiftUI,
built by `swiftc` out of the Command Line Tools, no Xcode. It is a second
interface to keep in step, which is why it owns as little as possible: it reads
`/sessions.json` off the service and nothing else, so it cannot disagree with
the status page or the display about what is happening. You can also just open
`http://localhost:8787/`.

**Coarser:** tapping a row. On Windows the right *window* is picked by matching
the session title against every open window's title — two projects in the same
editor end up in the right one. On macOS there is no window list to score, so
you get the right *application* and which tab is in front inside it is up to the
application.

### The floating window

`hud-macos/` builds a 488 KB `.app` with `swiftc` out of the Command Line Tools:

```sh
hud-macos/build.sh           # build build/Claude Sessions HUD.app
hud-macos/build.sh test      # thirty-four checks on the part without a window
hud-macos/build.sh install   # build, put it in ~/Applications, start it
```

Same colours as everywhere else, same rule about beeping only on the change to
orange. Clicking a row raises that terminal, `Enter` and `Esc` appear on an
orange row and do what the buttons on the display do, and the right-click menu
carries everything from the Windows one that means anything off Windows:
always-on-top, compact rows, only-what-needs-me, hiding sessions, the address to
copy, start-at-login, restart and quit. The display half of that menu — the
cracktro, releasing the USB port — is not there, because it belongs to `cyd/`.

Two things follow from it reading `/sessions.json` and nothing else. It needs no
Automation permission of its own, since raising a window stays the service's
job with the permission the service already has. And it shows nothing without
the service running — it says so rather than showing an empty list, which is
also why "Start when I log in" writes two LaunchAgents, one for each.

Dutch on a Dutch Mac, English everywhere else: `Strings.swift` mirrors
`langlib.ps1` key for key. [`hud-macos/README.md`](hud-macos/README.md) has the
rest — the file-by-file split, the settings file, and the fake service you can
point it at to see every state without waiting for one.

### Setting it up

From the release package, install PowerShell and then double-click
`Install.command`:

```sh
brew install powershell   # PowerShell 7; the code is PowerShell
```

It copies the files to `~/Library/Application Support/ClaudeDeck`, registers the
hooks, runs the self test, offers to build the floating window and offers to
start the web service. The copy matters:
the hooks store the full path to `beacon.ps1`, so a folder you later clear out
takes every session with it.

From a git checkout, the same four steps by hand:

```sh
pwsh -NoProfile -File selftest.ps1      # what works on this machine, and what does not
pwsh -NoProfile -File install-hooks.ps1 # register the hooks in ~/.claude/settings.json
pwsh -NoProfile -File session-api.ps1   # the service the display and the window talk to
hud-macos/build.sh install              # the floating window, into ~/Applications
```

The window is built last on purpose: it reads `/sessions.json` off the service
and shows nothing at all without it.

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

### What is tested, and what is not

Everything above compiles and runs on Windows, and the platform-specific halves
are exercised here. The macOS path has since been run on a Mac — macOS 26.5,
Apple silicon, PowerShell 7.6.5 — and what that found is in the section below.

The `ps` parsing was the most likely candidate, and it was in fact broken: it
read the process id out of `$Matches` after two later matches had already
overwritten it, so every process landed under id 0 and nothing worked. That is
fixed, and `selftest.ps1` now runs the parser against a captured `ps` listing on
every platform, so the same class of mistake cannot go unnoticed again.

What still cannot be checked from here is everything that needs the machine
itself: the permission dialog, `route`, `ifconfig`, `osascript`, and whether
raising an application actually raises it. `selftest.ps1` is where those report.

### What running it on a Mac turned up

`selftest.ps1` passed on the first try, with one warning about there being no
serial port — there was no display attached. The process table, the `ps`
parsing, the address lookup, the port and `osascript` were all fine.

Two things were not:

- **`brew install --cask powershell` no longer works.** PowerShell moved out of
  homebrew-cask and is a formula now, so the cask lookup fails outright. The
  formula needs no administrator password either, which the cask did. Fixed
  everywhere it was written down.
- **The hook interpreter was pinned to a version.** `install-hooks.ps1` took the
  path of the running process, which under Homebrew is
  `/opt/homebrew/Cellar/powershell/7.6.5/libexec/pwsh`. That path stops existing
  the first time PowerShell is upgraded, and every session then silently stops
  reporting in — exactly the failure the copy-to-a-stable-folder rule exists to
  prevent, arriving by the other door. It now prefers the stable symlink after
  checking that it is the same PowerShell.

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

**On a Mac, if `pwsh` itself will not start** — an unhandled
`System.IO.FileLoadException` about an invalid assembly name, before any of
this project runs — the culprit is PowerShell's own startup cache, and
reinstalling does not touch it because it lives in your home directory:

```sh
rm -rf ~/.cache/powershell
```

Worth knowing because every tool this project gives you for diagnosing trouble
is itself written in PowerShell, so this failure takes the diagnostics with it.
Sessions that were already running keep reporting in, which makes it look like
something you did rather than something that broke.

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
