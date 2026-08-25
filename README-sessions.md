# The full manual

Everything the [README](README.md) summarises, explained properly. Most of this
is the *why* behind decisions that look arbitrary until you hit the problem they
solve.

- [1 · The beacon: where session data comes from](#1--the-beacon-where-session-data-comes-from)
- [2 · The floating HUD](#2--the-floating-hud)
- [3 · The Cheap Yellow Display](#3--the-cheap-yellow-display)
- [4 · Windows notifications](#4--windows-notifications)
- [5 · What you do and do not see](#5--what-you-do-and-do-not-see)
- [6 · Files](#6--files)

---

## 1 · The beacon: where session data comes from

Every local Claude Code session reports itself through hooks. On start, on every
instruction, when Claude asks for attention and when it finishes, `beacon.ps1`
writes a small status file into `session-status\` and merges everything into
`sessions.json` (for the HUD and the display) and `sessions.js` (for a web page,
if you have one).

### How a session gets its name

Claude Code writes session names as separate lines in the transcript, and the
hook passes the path of that transcript along. There are three kinds, and the
beacon takes the last of each:

| Line type | What it is |
|---|---|
| `custom-title` | the name you gave it yourself with the rename function — always wins |
| `ai-title` | the title Claude Code maintains and keeps updating while it works |
| `summary` | the summary after a `/compact`, or when resuming a session |

Which field holds that text varies between Claude Code versions, so the beacon
takes the first non-empty one out of `title`, `customTitle`, `aiTitle`, `name`,
`text`, `value`, `content` or `summary`. If that changes in a future version it
is one line to update: `$velden` in `sessionlib.ps1`.

If none of that yields anything, the order is: the terminal's tab title (only for
a real terminal — an IDE keeps that tab name inside its own windows), then the
first instruction from the conversation truncated to 34 characters, and otherwise
the folder name. Cowork sessions hang off a window that is always called
"Claude"; those get `Cowork · <folder>`.

The title is looked up once and stored in the beacon file. On every `Stop` the
beacon looks again, because a new `ai-title` or a rename may just have arrived.

If two visible sessions have the same name, part of their session_id is appended
so you can tell them apart. The folder appears on the second line, together with
the time and what Claude is doing.

Two helper scripts for when a name is not what you expected:

```
powershell -ExecutionPolicy Bypass -File check-titels.ps1
powershell -ExecutionPolicy Bypass -File zoek-titel.ps1 -SessionId <id>
```

The first shows which source is used per session. The second dumps the title
lines from a transcript and shows what the project makes of them.

### States

| Last hook event | State | Colour |
|---|---|---|
| `Notification` | **Needs you** — Claude wants permission or input | orange |
| `SessionStart` / `UserPromptSubmit` / `PostToolUse` | Working | green |
| `Stop` | Done — the answer is there, your turn | grey-blue |
| `SessionEnd`, or the Claude process is gone | disappears immediately | — |

**Only orange is an alarm.** In Claude Code `Stop` means "finished answering",
not "something is waiting for you". Getting that wrong made every completed
session beep, which trains you to ignore the beep.

### Why "needs you" goes away again

Between `Notification` (Claude asks for permission) and the next `Stop`, Claude
Code fires no hook at all. Approve a permission request and the session would
stay orange while Claude had long since gone back to work.

That is why `PostToolUse` is in the hook list: it fires on every tool call and
moves the session back to "working" the moment work resumes. To stop that
slowing down every tool call, `beacon.ps1` returns immediately if the session was
already "working" within the last 20 seconds — only the transition and a
heartbeat every 20 seconds do real work. That heartbeat also keeps the `updated`
timestamp fresh, which the TTL depends on.

If you installed the hooks before this existed, run `install-hooks.ps1` again:
`PostToolUse` is added and the rest stays as it was.

### Why stale sessions really disappear

`SessionEnd` does not always fire. Close a terminal with the X button, have
something crash, or run `/clear` (a new session_id in the same folder), and a
`SessionStart` was left behind showing as "working" for an hour.

The beacon therefore records the **PID of the Claude process** (plus its start
time, to guard against reused PIDs). When reading, it checks whether that process
still exists; if not, the beacon file is deleted immediately. Duplicates per
Claude process are merged, keeping only the newest. The 45-minute TTL
(`$DashMaxAgeMinutes` in `sessionlib.ps1`) is now only a safety net for old
beacons that have no PID.

`$DashHideCwds` in `sessionlib.ps1` is empty by default, so you see everything.
To filter out a folder, put its full path there.

### Installing the hooks (once)

```
powershell -NoProfile -ExecutionPolicy Bypass -File install-hooks.ps1
```

The script backs up your `settings.json`, adds the hook events (idempotently) and
shows what it did. Doing it by hand works too: the block is in
`claude-hooks-snippet.json`. Hooks apply to sessions you start *after* that.

To check: start a session, give it an instruction, and see whether a `.json`
appears in `session-status\`.

## 2 · The floating HUD

A small window that stays on top, listing only your sessions.

Start it without a PowerShell window flashing up — double-click:

```
hud.vbs
```

To test with errors visible:

```
powershell -ExecutionPolicy Bypass -File hud.ps1
```

| Action | What it does |
|---|---|
| Drag with left button | move the window (position saved in `hud-config.json`) |
| Click a row | bring that session's window to the front; if it cannot, it says so in a balloon tip |
| Shift + click | open the project folder in Explorer |
| Ctrl + click | show which windows the HUD found and with what score — for when it picks the wrong one |
| Right-click | menu: always on top, compact rows, only sessions that need me, PC address, autostart, restart, quit |
| Double-click tray icon | hide or restore the HUD |
| Esc / F5 | hide / refresh now |

The tray icon is green when everything is running and orange as soon as a session
is waiting for you. A new orange session produces a beep and a balloon tip.

### Which window belongs to a session?

Walking the parent chain of the Claude process is not enough on its own. With
*attach project*, two PhpStorm projects share one process, and Windows then
returns an arbitrary one of the two windows. And if the intermediate shell has
already exited, the parent PID points at a reused process — so at some unrelated
window.

The HUD therefore scores every visible window:

| Points | For |
|---|---|
| +100 | the window belongs to a process in the parent chain (with a start-time check against reused PIDs) |
| +45 | the session's full path appears in the window title |
| +30 | the project name appears in the window title |
| +10 | the process is an IDE or terminal (`$DashHostProcs` in `hud.ps1`) |

The highest score above 30 wins; if nothing qualifies, it opens the project
folder instead. That way, within a single PhpStorm process, the window with the
right project name in its title wins. If it still picks wrong, use Ctrl+click:
you see every title with its score, which is usually enough to adjust
`$DashHostProcs` or the weighting.

The HUD reads the beacons itself every 3 seconds, so it is more current than a
web page, and it updates the payload for the display (only when something
actually changed). If you would rather it did not, set `$WritePayload = $false`
at the top of `hud.ps1`.

Redrawing only happens when something really changes; if only the clock ticks,
just the header is updated. Together with `DoubleBuffered` and `WS_EX_COMPOSITED`
that is the end of the flicker the first version had.

## 3 · The Cheap Yellow Display

The display fetches state from your PC every 3 seconds. On the PC:

```
powershell -ExecutionPolicy Bypass -File session-api.ps1     (or double-click api.vbs)
```

Endpoints on port 8787:

| URL | For |
|---|---|
| `/cyd.txt` | the ESP32 — plain text, no JSON library needed |
| `/sessions.json` | the same data as JSON |
| `/` | a tiny status page, fine on a phone |

The first time, Windows Firewall asks for permission: choose **allow on private
networks**.

The service caches the session list for 1.5 seconds (`-CacheMs`). That is not
premature optimisation: building it goes through WMI process queries which take
1.4 seconds and occasionally over 4, and rebuilding that on every request meant
the display's own timeout expired first. Cached, requests take about 3 ms.

Flashing the display and dealing with panel quirks is covered in
[cyd/README-cyd.md](cyd/README-cyd.md); the printable case with three MX buttons
in [case/README-case.md](case/README-case.md).

### Tapping and buttons

Tap a row and the display sends `/focus?id=<session>`, and your PC brings that
session's window forward — the same window finder the HUD uses, because it lives
in `focuslib.ps1` and both share it.

The three physical buttons send `/action?id=<session>&b=<number>`. What that
means is set in **`actions.json`** on your PC, not in the sketch:

| Type | What it does |
|---|---|
| `focus` | bring the session's window to the front |
| `keys` | bring the window forward and send keys (`{ENTER}`, `{ESC}`, `^c`, ...) |
| `snooze` | silence that session for a number of minutes: no orange, no beep |
| `run` | start a program or command (`{cwd}` becomes the session's folder) |
| `open` | open a folder, file or URL |

By default button 1 approves, button 2 rejects, button 3 snoozes for 10 minutes,
and the display's BOOT button jumps to the window as button 4. The labels along
the bottom of the screen come from the same file, so after a change you do not
reflash — only the API re-reads.

Two brakes on the approve button: `requireAttention` means keys are only sent
when that session is genuinely asking for something, and everything is recorded
in `actions.log`. On an untrusted network, set `token` in `actions.json` and the
same value in `API_TOKEN` in the sketch.

## 4 · Windows notifications

| Event | Notification |
|---|---|
| `Notification` | always: "Claude needs you: `<folder>`" with the reason |
| `Stop` | only if the run took longer than 60 seconds |

The switches are at the top of `beacon.ps1`: `$ToastEnabled = $false` turns
everything off, `$ToastStopMinSeconds` sets how long a finished run has to be
before it is worth a notification. This is purely about the toast — in the HUD
and on the display, `Stop` stays a quiet "done".

## 5 · What you do and do not see

**You do see** every local Claude Code session on this machine, what it is doing,
and whether it needs attention.

**You do not see** Cowork cloud sessions — those run in sealed environments with
no API to enumerate them account-wide.

## 6 · Files

| File | What it is |
|---|---|
| `sessionlib.ps1` | shared session logic (states, PID check, snooze, payload) |
| `focuslib.ps1` | which window belongs to which session, and how to raise it |
| `langlib.ps1` | every user-visible string, in every supported language |
| `beacon.ps1` | called by the Claude Code hooks |
| `install-hooks.ps1` | puts the hooks in your `settings.json` |
| `hud.ps1` / `hud.vbs` | the floating HUD and its silent launcher |
| `hud-config.json` | HUD position and preferences (created automatically) |
| `session-api.ps1` / `api.vbs` | web service for the display and your phone |
| `actions.json` | what the buttons on the display do |
| `actions.log` | what was executed, with timestamps |
| `snooze.json` | which sessions are temporarily silenced |
| `diagnose.ps1` | walks the whole chain when something is not working |
| `cyd\` | Arduino sketch, TFT settings and flashing instructions |
| `case\` | printable case: STLs, generator and build notes |
| `sessions.json` / `sessions.js` | the current state, written by the beacon |
| `session-status\` | one small file per session |
