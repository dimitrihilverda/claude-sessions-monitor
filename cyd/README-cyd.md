# Claude sessions on the Cheap Yellow Display

The CYD (ESP32-2432S028R) fetches the session list from your PC every three
seconds and shows one row per session: orange = needs you, green = working,
grey = done. When a session turns orange it beeps, flashes the top bar, and
lights the on-board RGB LED to match.

**Tapping a row** selects that session and brings its terminal window to the
front on your PC — exactly what clicking in the HUD does.

**The three buttons** do whatever `actions.json` on your PC says. The display
only sends "button 2 on session X"; your PC decides what that means. By default
button 1 approves (Enter), button 2 rejects (Escape), and button 3 snoozes the
session for ten minutes. The labels along the bottom of the screen come from the
same file, so changing them does not mean reflashing. The board's own BOOT button
acts as a fourth button.

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

## 3. When something is wrong

| Symptom | Cause |
|---|---|
| White or black screen | Wrong `User_Setup.h`, or `TFT_BL` is not 21 |
| Colours inverted (you send magenta, it shows green) | `#define TFT_INVERSION_ON` is missing from your `User_Setup.h`. None of the ILI9341 init sequences send an inversion command themselves, so this panel stays in its inverted power-on state. Watch out: two different dark shades then both come out light beige, which makes colour changes look like nothing happened at all |
| Colours swapped (blue where red should be) | *That* one is the driver: swap `ILI9341_2_DRIVER` for `ILI9341_DRIVER`. Never mix power or gamma values from a different driver into an existing init sequence — `0xC0`/`0xC1`/`0xC5`/`0xC7` belong together, and taking half of them upsets the panel |
| Mirrored or portrait | Change `tft.setRotation(1)` to 3 (or 0/2) |
| "No connection" | The web service is not running (start "Claude Deck API" or `api.vbs`), the firewall is blocking it, or the PC address is stale — fix the last one by holding the top bar for two seconds and opening the portal |
| Slow or dropped polls | The API rebuilds the session list through WMI process queries, which is slow. It caches for 1.5 s by default (`-CacheMs`); with caching off, requests take 1.4 s and sometimes over 4 s, which exceeds the display's timeout |
| It no longer joins your Wi-Fi (new password or network) | It brings up the `Claude-Deck` network by itself; join it with your phone and set it up again. No USB needed |
| No beep | The CYD has no speaker on board, only the pads. Solder one to the speaker pads (IO26) or set `BEEP_ENABLED` to false |
| Taps land next to where you press | Set `TOUCH_DEBUG` to 1, tap the four corners, read the raw values in the serial monitor and fill in `TS_MINX/MAXX/MINY/MAXY`. If everything is mirrored, flip `TOUCH_FLIP_X` / `TOUCH_FLIP_Y` |
| A button does nothing | Button 3 is on GPIO35, which has no internal pull-up. It needs an external 10k resistor to 3V3; without it the input floats |
| "only works when that session is waiting" | The action has `requireAttention` in `actions.json` and that session is not asking for anything. That is deliberate: it stops you pushing Enter into a session that is simply working |

## The endpoints

| URL | For |
|---|---|
| `/cyd.txt` | the session list as plain text |
| `/focus?id=<session>` | brings that window to the front (tapping) |
| `/action?id=<session>&b=<1-4>` | runs button action N |
| `/sessions.json` | the same data as JSON |
| `/` | small status page; tapping a row there also fetches the window |

`/cyd.txt` returns one line per session as
`state|name|since|why|session-id`, preceded by a header line:

```
#<needs-you>|<working>|<done>|<HH:mm>|<button labels ;>|<header text>|<state labels ;>
```

The last two fields carry the display's text, which is why the screen follows the
language of your PC without a table of its own and without reflashing. The header
text arrives already composed, because only the PC knows whether it should read
"1 needs you" or "2 need you".

Older firmware that only reads five fields simply ignores the extra two, so
mixing versions is harmless. Keeping it plain text means the sketch needs no
JSON library and parsing stays a handful of `indexOf` calls.

## An easter egg

Hold the BOOT button for two seconds. Touch the screen or press any button to
return. There is a chiptune on IO26 as well, which stays silent until you solder
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
