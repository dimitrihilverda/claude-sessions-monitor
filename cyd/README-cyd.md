# Claude sessions on the Cheap Yellow Display

The CYD (ESP32-2432S028R) fetches the session list from your PC every three
seconds and shows one row per session: orange = needs you, green = working,
grey = done. When a session turns orange it beeps, flashes the top bar, and
lights the on-board RGB LED to match.

## What it does

| Action | Result |
|---|---|
| Tap a row | Select that session and raise its terminal window on your PC — exactly what clicking in the HUD does |
| Tap the top bar | Step the brightness: 100 / 70 / 50 / 35 / 25 / 15 % |
| Hold the top bar, 2 s | Open the setup page, to change Wi-Fi or the PC address |
| Tap a button | Run that button's action from `actions.json` |
| Press a physical button | The same three actions, plus BOOT as a fourth |
| Tap ▲ or ▼ | Scroll, once there are more sessions than rows |
| Hold BOOT, 2 s | An easter egg; touch the screen or press anything to leave |

**The three buttons** do whatever `actions.json` on your PC says. The display
only sends "button 2 on session X"; your PC decides what that means. By default
button 1 approves (Enter), button 2 rejects (Escape), and button 3 snoozes the
session for ten minutes. The labels along the bottom of the screen come from that
same file, so changing them does not mean reflashing.

### More sessions than fit

Four rows fit on screen; up to sixteen sessions are kept. Past the fourth, the
third button slot turns into ▲ and ▼ so the other two labels stay fully readable,
and the third *physical* button pages down alongside them, wrapping to the top —
otherwise it would still snooze while an arrow sits next to it, and a button that
does something other than what it says is worse than a button that does less.

A session that starts asking for you scrolls itself into view. Without that an
orange alarm could sit below the fold, and then a quiet screen would no longer
mean nothing wants you — which costs more than the alarm is worth. A hairline on
the right edge shows where you are in the list.

### When it cannot reach the PC

It says so and keeps trying, roughly once a second, and shows the attempt count,
how long contact has been gone, and the signal strength. That last number is the
useful one: at -75 dBm or lower it is range rather than a fault, and no setting
will fix it.

A printable case with those three buttons lives in [`../case/`](../case/).

## 1. On the PC: start the web service

The display talks to `session-api.ps1` in the folder above.

    powershell -ExecutionPolicy Bypass -File session-api.ps1

Or quietly in the background: double-click `api.vbs`.

The first time, Windows Firewall asks for permission — choose **allow on private
networks**. To add the rule up front instead, from an administrator prompt:

    netsh advfirewall firewall add rule name="Claude sessions API" dir=in action=allow protocol=TCP localport=8787

The script prints the usable addresses when it starts. Test in a browser:

    http://<your-pc-ip>:8787/cyd.txt      <- what the display reads
    http://<your-pc-ip>:8787/             <- small status page (works on a phone too)

Reserve a fixed DHCP lease for your PC in your router. Without one its address
changes after a restart, and the display will be pointing at the wrong place.

## 2. In the Arduino IDE

1. **Board**: ESP32 Dev Module (esp32 by Espressif, 2.x or 3.x — both work).
   Upload speed 921600, Flash 4MB, Partition Scheme: Default.
2. **Libraries** via the Library Manager: **TFT_eSPI** (Bodmer) and
   **XPT2046_Touchscreen** (Paul Stoffregen).
3. Copy `User_Setup_CYD.h` over
   `Documents\Arduino\libraries\TFT_eSPI\User_Setup.h`.
   Note that updating TFT_eSPI overwrites that file again.
4. Upload. If the upload will not start, hold BOOT while it begins.

You do **not** need to put your Wi-Fi details or your PC's address in the sketch.
You set those on the display itself — see the next section.

> If you change a library header, `arduino-cli` needs `--clean`. It caches the
> compiled library and will otherwise happily flash the old settings.

## 2b. Setting up Wi-Fi without a PC

On first boot — or whenever it cannot reach your Wi-Fi — the display brings up
its own network and tells you what to do:

    network:   Claude-Deck
    password:  claudedeck
    then open: http://192.168.4.1

Join it with your phone. On most phones the page opens by itself; if not, browse
to that address. You pick your network from a list, type the password, and fill
in your PC's address. After saving it restarts and connects.

Everything is stored in NVS, the part of flash a new sketch does not erase. Your
settings therefore survive reflashing, and no password ends up in the sketch or
in git.

**Changing it later**: hold your finger on the top bar (where the counters and
the clock are) for two seconds. This is the way back in when the display *is* on
Wi-Fi but the PC address is wrong — in that case the portal never appears on its
own. A *short* tap on that bar does something else: it steps the brightness.

Rolling out several displays and would rather not configure each one? Fill in
`WIFI_SSID_START`, `WIFI_PASS_START` and `API_HOST_START` at the top of the
sketch. Those are starting values only: once anything is stored in NVS, NVS
wins. Be aware that whatever you put there ends up in your git history.

## 2c. Over USB, when the network will not do

On a network that blocks port 8787 — most offices — or a guest network that keeps
devices apart, there is nothing for the display to poll. If it is plugged into
the PC, the cable carries the same data instead.

Nothing to set up. `session-api.ps1` looks for the board by chip rather than by
port number (this one turned up as COM12 one day and COM16 the next), attaches,
and pushes the identical `/cyd.txt` payload every three seconds. Two vendor ids,
because there are two boards: `1A86` is the CH340 in front of the CYD, `303A` is
Espressif's own, which the S3 speaks directly over its native USB. The display
prefers whatever arrived over serial while it is less than ten seconds old, so:

- plugged into the PC → it uses the cable, and skips Wi-Fi entirely
- on a USB charger with no PC → nothing arrives, and it falls back to Wi-Fi
- no usable Wi-Fi *and* a cable → it goes straight to work instead of sitting in
  the setup portal, which is what used to happen
- already in the portal when a cable comes alive → the portal reads the cable
  too, and closes itself. Not when you opened it yourself by holding the top
  bar; you are typing a password there

Taps and button presses go back over the same cable, through the same code path
the HTTP endpoints use — so the "only when that session is asking" brake cannot
drift between the two. The header shows **USB** next to the clock when that is the
transport, so "it works" and "it works over the cable" do not look identical, and
the signal bars sit beside it whether or not the cable is in — plugged in, the
question you actually have is whether the Wi-Fi is ready for the moment you pull
it out.

On Windows the cable can also do the Wi-Fi setup for you. A board with no network
says so, the PC answers with the networks it already has passwords for plus its
own address, and the board picks the first one it can actually hear. That last
part belongs on the board and not on the PC: this radio is 2.4 GHz only, while
your PC is perfectly happy on 5 GHz and will confidently name a network the board
can never reach.

There is no token over serial, unlike `/action` over the network: a cable plugged
into that machine is its own proof of access.

**The catch:** a serial port belongs to one program at a time, so while the
service is attached a flash or a serial monitor will fail. Use the HUD's
right-click menu → **"Release the USB port"**. It lets go for a minute and picks
it up again by itself. From a script:

    curl "http://127.0.0.1:8787/serial/release?sec=60"

To keep the service off the port entirely, start it with `-SerialBridge:$false`.

## 3. When something is wrong

| Symptom | Cause |
|---|---|
| White or black screen | Wrong `User_Setup.h`, or `TFT_BL` is not 21 |
| Colours inverted (you send magenta, it shows green) | `#define TFT_INVERSION_ON` is missing from your `User_Setup.h`. None of the ILI9341 init sequences send an inversion command themselves, so this panel stays in its inverted power-on state. Watch out: two different dark shades then both come out light beige, which makes colour changes look like nothing happened at all |
| Colours swapped (blue where red should be) | *That* one is the driver: swap `ILI9341_2_DRIVER` for `ILI9341_DRIVER`. Never mix power or gamma values from a different driver into an existing init sequence — `0xC0`/`0xC1`/`0xC5`/`0xC7` belong together, and taking half of them upsets the panel |
| Mirrored or portrait | Change `tft.setRotation(1)` to 3 (or 0/2) |
| "No connection" | The web service is not running (start "Claude Deck API" or `api.vbs`), the firewall is blocking it, or the PC address is stale — fix the last one by holding the top bar for two seconds and opening the portal |
| Slow or dropped polls | The API reads `sessions.json`, which the HUD writes every 3 s, so a request costs a few ms. If the HUD is not running it falls back to rebuilding from WMI process queries, which takes 1.2-1.5 s and can exceed the display's timeout — so start the HUD, or accept the slower path |
| "No connection" while the API is clearly reachable from the PC | Testing from the PC itself proves nothing: traffic to your own address bypasses Windows Firewall. Start the service with `-LogRequests` and watch `actions.log`; if no request ever arrives from the display's address, the packets are not reaching the PC. Check whether the display is on a **guest or isolated Wi-Fi network** — those allow internet but block traffic between devices, and the ESP32 can only use 2.4 GHz, so it may end up on a different SSID than your PC |
| It no longer joins your Wi-Fi (new password or network) | It brings up the `Claude-Deck` network by itself; join it with your phone and set it up again. No USB needed. On Windows there is a shorter way: clear its settings and plug it into the PC, and the service hands it the networks it knows |
| Connected to Wi-Fi and still "no connection" | Read the bars before anything else. Measured on one desk, -66 dBm polled happily every three seconds and -85 could not open a connection at all, and on screen those two looked identical. Two bars or fewer means move it or add an access point; the serial log prints the exact `rssi` on every poll. Note also that the board backs off to a slow retry after failures, so give it a minute before deciding a fix did not work |
| No beep | The CYD has no speaker on board, only the pads. Solder one to the speaker pads (IO26) or set `BEEP_ENABLED` to false |
| Taps land next to where you press | Set `TOUCH_DEBUG` to 1, tap the four corners, read the raw values in the serial monitor and fill in `TS_MINX/MAXX/MINY/MAXY`. If everything is mirrored, flip `TOUCH_FLIP_X` / `TOUCH_FLIP_Y` |
| A button does nothing | Button 3 is on GPIO35, which has no internal pull-up. It needs an external 10k resistor to 3V3; without it the input floats |
| Flashing fails with "could not open port" | The service is holding it for the USB bridge. HUD menu → "Release the USB port", or start the service with `-SerialBridge:$false` |
| "only works when that session is waiting" | The action has `requireAttention` in `actions.json` and that session is not asking for anything. That is deliberate: it stops you pushing Enter into a session that is simply working |

## The endpoints

| URL | For |
|---|---|
| `/cyd.txt` | the session list as plain text |
| `/focus?id=<session>` | brings that window to the front (tapping) |
| `/action?id=<session>&b=<1-4>` | runs button action N |
| `/sessions.json` | the same data as JSON |
| `/serial/release?sec=60` | let go of the USB port, so you can flash |
| `/` | small status page; tapping a row there also fetches the window |

`/cyd.txt` returns one line per session as
`state|name|since|why|session-id`, preceded by a header line:

```
#<needs-you>|<working>|<done>|<HH:mm>|<button labels ;>|<header text>|<state labels ;>|<command>
```

The last field is a one-shot command for the display, currently only `cracktro`.
It stays on offer for a few seconds rather than being cleared by the first reader,
because otherwise a browser on the status page swallows it before the display
ever polls.

Fields 6 and 7 carry the display's text, which is why the screen follows the
language of your PC without a table of its own and without reflashing. The header
text arrives already composed, because only the PC knows whether it should read
"1 needs you" or "2 need you".

Older firmware that only reads five fields simply ignores the extra two, so
mixing versions is harmless. Keeping it plain text means the sketch needs no
JSON library and parsing stays a handful of `indexOf` calls.

## An easter egg

Start it from the HUD's right-click menu ("Cracktro on the display"), or with
`GET http://<your-pc-ip>:8787/demo`. The command rides along in the header line
of `/cyd.txt`, so the display has to be connected for either route.

Holding the on-board button for two seconds works as well -- but only if that
button really is BOOT (GPIO0). On several CYD revisions the single button next
to the screen is wired to **RST**, and then pressing it just reboots the board.
You will land in the setup portal whenever Wi-Fi does not come up within the
20-second window at startup, which looks like the button "opening the settings".

Touch the screen or press any button to return. There is a chiptune on IO26 as well, which stays silent until you solder
a speaker to the pads. The scroller text is a clearly marked constant at the top
of the sketch — write your own.

## A warning about the approve button

`/action` can send keystrokes into your terminal, and anyone on your network can
call it. Two brakes are on by default: an action with `requireAttention` only
works when that session is genuinely asking for something, and every action is
recorded in `actions.log`. On a network you do not trust, set `token` in
`actions.json` and put the same value in `API_TOKEN` in the sketch.

And consider what that button does: it confirms whatever is on your screen at
that moment, including a command you would rather have read first. If you would
rather it did not, set button 1 to `"type": "focus"` — then it just jumps to the
window and you decide for yourself.
