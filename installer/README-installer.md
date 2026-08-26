# Claude Sessions Monitor

A small window showing which Claude Code sessions are running, what they are
doing, and which one is waiting for you. Always on top; click a session to jump
to that terminal window.

Optionally you can hang a cheap touchscreen off it (a "Cheap Yellow Display" on
an ESP32) with three mechanical buttons, so you can respond without reaching for
the mouse.

## Installing

Double-click **`Install.cmd`**. It asks three things: where it may go, whether
you want the touchscreen, and whether everything should start when you log in.
Administrator rights are not needed.

By default everything lands in `%LOCALAPPDATA%\ClaudeDeck`.

What the installer does:

- copies the files
- registers the Claude Code hooks in `%USERPROFILE%\.claude\settings.json`
  (with a backup, and existing references to an older install are updated rather
  than duplicated)
- creates Start menu shortcuts, and with "start when I log in" also puts them in
  your Startup folder — the web service for the touchscreen comes along, because
  without it the display just says "no connection"
- starts the HUD, plus the web service if you chose the touchscreen

Sessions that are already running only pick up the hooks after that session
restarts.

## Using it

| Action | What it does |
|---|---|
| Drag | Move the window; the position is remembered |
| Click a row | Bring that session's terminal window to the front |
| Shift + click | Open the project folder in Explorer |
| Ctrl + click | Show which windows were found and with what score |
| Right-click | Menu: always on top, compact rows, only sessions that need me, restart, quit |
| Double-click tray icon | Hide or restore the HUD |
| Esc / F5 | Hide / refresh now |

Colours: **orange** means Claude wants something from you (permission or input),
**green** that it is working, **grey-blue** that it is done. Only orange produces
a beep and a notification.

A session disappears the moment the Claude process does, even if you closed the
terminal with the window's X button.

All visible text follows your Windows display language. Dutch and English are
included; anything else falls back to English.

## The touchscreen

If you choose it, a web service comes along. It starts right after installation,
and with "start when I log in" also after every restart. To start it by hand, use
"Claude Deck API" in your Start menu. Windows Firewall asks for permission the
first time — choose private networks. On a phone or tablet you can then browse to
`http://<your-pc-ip>:8787/` for the same list.

Do not remember your PC's address? The HUD's right-click menu shows it, and
clicking copies it.

If the display is plugged into this PC by USB, the service also pushes the same
data over the cable — handy on a network that blocks the port. That means it holds
the COM port, so use the HUD menu's "Release the USB port" before flashing.

For the display itself: build instructions, the Arduino sketch and a printable
case are in `cyd\` and `case\`. What the three physical buttons do is set in
`actions.json` — the service re-reads that file on every press, so changing it
does not mean reflashing.

## The HUD shows nothing

This is nearly always the same thing: **hooks are read when a session starts**,
not afterwards. Anything already running when you installed will not report in.

- **Terminal**: close those Claude Code sessions and start a new one.
- **Desktop app**: quit Claude completely, including from the system tray next to
  the clock, and start it again. Opening a new chat in an app that was already
  running is not enough — it still uses the settings from when the app started.

Then give it an instruction and the HUD fills up.

If it stays empty, double-click **`Diagnose.cmd`**. It walks the whole chain —
files, hooks in `settings.json`, a real test call to the beacon, the status files
and the HUD itself — and says where it breaks. Two things it often finds: the
"only sessions that need me" filter left on, or hooks still pointing at an older
install folder.

## When a name looks wrong

A session's name comes from the Claude Code transcript: first a name you gave it
yourself, otherwise the title Claude Code maintains, otherwise the first
instruction, otherwise the folder name.

```
powershell -ExecutionPolicy Bypass -File check-titles.ps1
```

shows which source is used for each session.

## Uninstalling

```
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

That removes the hooks from `settings.json` (with a backup), deletes the
shortcuts, and asks whether the folder may go too.

## What it does not do

Nothing leaves your machine. Session state comes from Claude Code's hooks and
stays local; the web service for the touchscreen listens only on your local
network and is off by default.

Do be careful with the "approve" button on the touchscreen: it confirms whatever
is on your screen at that moment. Anyone on your network can call that web
service, so add a `token` to `actions.json` if you do not trust the network.
