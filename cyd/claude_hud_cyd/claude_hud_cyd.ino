/* ===========================================================================
   claude_hud_cyd.ino -- Claude sessions on the Cheap Yellow Display
   Board: ESP32-2432S028R (2.8" ILI9341, 320x240, XPT2046 touch)

   What it does:
     - shows your live Claude sessions (orange = needs you, green = working,
       grey = done) with the counters and the clock along the top
     - TAPPING a row  -> selects that session and brings its window on your PC
       to the front (the same as clicking in the HUD)
     - THREE BUTTONS along the bottom -> run whatever actions.json on your PC
       says (approve, reject, snooze, ...). The labels on screen come from that
       same file, so changing them does not mean reflashing
     - the RGB LED on the board follows along, even when you are not looking

   Needs: TFT_eSPI (Bodmer) with User_Setup_CYD.h, and XPT2046_Touchscreen
   (Paul Stoffregen). No JSON library: the PC serves plain text on /cyd.txt.
   =========================================================================== */

/* The order below is not free. TFT_eSPI defines FS_NO_GLOBALS
   (Processors/TFT_eSPI_ESP32.h), and the core puts "using namespace fs;" in
   FS.h behind exactly that guard. Put TFT_eSPI first and the name FS becomes
   invisible, breaking WebServer.h -- which uses "FS &fs" unqualified. So:
   networking first, screen second. */
#include <WiFi.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <mbedtls/base64.h>
#include <FS.h>
#include <WebServer.h>
#include <DNSServer.h>

/* The panel and the touch controller live behind gfx.h, so this file has no
   opinion about which board it is running on. Set BOARD_KIND at compile time to
   pick a backend; it defaults to the CYD. */
#include "gfx.h"
#include "board.h"

/* ---- SETTINGS --------------------------------------------------------------
   You do NOT need to fill in Wi-Fi or the PC address here. You set those on
   the display itself: if it cannot connect, the CYD brings up its own network
   (see PORTAAL_SSID below) and you configure it from your phone. What you
   enter is stored in NVS and survives reflashing.

   If you would rather fill them in up front -- to roll out a stack of displays,
   say -- you may do so below. They are starting values only: once anything is
   in NVS, NVS wins. Be aware that a password you put here ends up in your git
   history. */
const char* WIFI_SSID_START = "";
const char* WIFI_PASS_START = "";
const char* API_HOST_START  = "";
const int   API_PORT_START  = 8787;

const char* API_TOKEN = "";            // only fill this in if you set a token in actions.json

/* The firmware version, so the PC can tell you when the display is behind.

   CI passes the same string it puts in the flasher's manifest.json, which is what
   makes the two comparable at all. A local build has no such string, so it falls
   back to the compile date -- enough to see that it is not a CI build.

   Deliberately free of spaces: it travels as a query parameter and as a serial
   line, and a space in either is one more thing to get wrong. */
#ifndef FW_VERSION
/* A local build has no CI string. Just "local", not "local-" __DATE__: that date
   contains spaces, and this value travels as a query parameter and as a serial
   line where the parser stops at the first one -- it arrived as "local-Aug".
   The compile date is on the BUILD line anyway, which is where you look to tell
   two local builds apart. */
#define FW_VERSION "local"
#endif

// The network you configure it over. Password-protected on purpose: on an open
// network anyone nearby could overwrite your display's settings.
const char* PORTAAL_SSID = "Claude-Deck";
const char* PORTAAL_PASS = "claudedeck";

const uint32_t POLL_MS       = 3000;   // how often we ask the PC for the state
/* Once we are offline, ask more often. A failed poll already blocks for up to
   the HTTP timeout, so at 3 s intervals a few dropped packets leave you staring
   at "no connection" for tens of seconds. */
const uint32_t POLL_MS_OFF   = 1200;
const uint8_t  BACKLIGHT_PCT = 70;     // brightness 0-100
const bool     BEEP_ENABLED  = BOARD_HAS_SPK;   // beep on a new attention request

// ---- hardware --------------------------------------------------------------
/* Which pins, which of these the board actually has, and how tall a row is:
   all of that is in board.h, next to the same answers for the other panel. */
struct Btn { uint8_t pin; bool pullup; const char* id; };
Btn BUTTONS[] = BOARD_BUTTONS;
const int N_BTN = sizeof(BUTTONS) / sizeof(BUTTONS[0]);
bool     btnWas[8];
uint32_t btnAt[8];

/* ---- colours ---------------------------------------------------------------
   Converted from RGB888 to RGB565: ((r>>3)<<11) | ((g>>2)<<5) | (b>>3).

   Note that 565 rounds coarsely: red and blue in steps of 8, green in steps of
   4. Two hex values that clearly differ on your monitor can come out identical
   on this panel. The ladder background -> row -> hover was chosen with that in
   mind: background and row differ in green, row and hover in red and blue, so
   both steps stay visible.
   What the panel actually makes of each one is noted after every line. */
#define COL_BG      0x2987   // #2A3238  background (and the header bar)
#define COL_HDR     0x2987   // same as the background
#define COL_ROW     0x29C8   // #2E3840  row surface, a touch lighter than the background
#define COL_SEL     0x3209   // #364048  hover / selected row
#define COL_LINE    0x3A29   // #3A444B  separators and button border
#define COL_TXT     0xEF9E   // #EEF3F5  a session's title
#define COL_MUTED   0x8CF1   // #8E9C8B  the info line below it
#define COL_GREEN   0x9648   // #91C847  working
#define COL_ORANGE  0xE528   // #E6A745  needs you
#define COL_STEEL   0x7C70   // #7E8C84  done -- neutral grey; used to be the
                             // steel blue #9BB0C7, which read as "a blue bar"

/* The HUD draws state labels as a "chip": a fill in the state colour at alpha
   38 over the row, a border at alpha 150 and the text in the full colour. With
   this helper those in-between colours need no hardcoding, and the chip is
   right on both a normal and a selected row. */
uint16_t blend565(uint16_t fg, uint16_t bg, uint8_t alpha) {
  uint8_t fr = (fg >> 11) & 0x1F, fgr = (fg >> 5) & 0x3F, fb = fg & 0x1F;
  uint8_t br = (bg >> 11) & 0x1F, bgr = (bg >> 5) & 0x3F, bb = bg & 0x1F;
  uint8_t r = (fr * alpha + br * (255 - alpha)) / 255;
  uint8_t g = (fgr * alpha + bgr * (255 - alpha)) / 255;
  uint8_t b = (fb * alpha + bb * (255 - alpha)) / 255;
  return (r << 11) | (g << 5) | b;
}

/* ---- layout ----------------------------------------------------------------
   Widths come from the panel; the heights and the type sizes come from board.h,
   because how tall a row has to be is set by how tall the type is and the two
   boards do not use the same type. */
#define SCR_W     (gfxWidth())
#define SCR_H     (gfxHeight())
/* How many sessions we keep in memory. The PC sends every visible one, and the
   old code threw away everything past the fourth -- so with five sessions the
   fifth did not exist as far as the display was concerned. Keeping more costs a
   little RAM and buys scrolling. */
#define MAX_SESS  16

// ---- session state ---------------------------------------------------------
struct Sess { String state, name, since, why, id; };
Sess     rows[MAX_SESS];
int      nRows = 0;
int      nAtt = 0, nAct = 0, nDone = 0;
int      selIdx = 0;
/* Index of the row drawn in the top slot. Everything else derives from this, so
   there is one number to keep honest rather than a scroll state per view. */
int      scrollTop = 0;

bool scrollable() { return nRows > MAX_ROWS; }
int  scrollMax()  { return scrollable() ? (nRows - MAX_ROWS) : 0; }

void clampScroll() {
  if (scrollTop > scrollMax()) scrollTop = scrollMax();
  if (scrollTop < 0) scrollTop = 0;
}

/* Keep a row in view. Used for the selection and, more importantly, for a
   session that starts asking for attention: an orange alarm below the fold makes
   the whole display untrustworthy, because "nothing on screen" would no longer
   mean "nothing wants you". */
void scrollToRow(int idx) {
  if (idx < 0 || idx >= nRows) return;
  if (idx < scrollTop)                 scrollTop = idx;
  else if (idx >= scrollTop + MAX_ROWS) scrollTop = idx - MAX_ROWS + 1;
  clampScroll();
}
String   clockTxt = "--:--";
String   btnLabel[3] = { "Button 1", "Button 2", "Button 3" };

/* Text the PC supplies in the header line of /cyd.txt, so the display follows
   the language of Windows without a table of its own and without reflashing.
   The values below are only the fallback for before any answer has ever
   arrived. */
String   uiHeader   = "CLAUDE";
String   uiState[3] = { "NEEDS YOU", "WORKING", "DONE" };   // attention, active, done
String   uiEmpty    = "No active sessions.";

/* A one-shot command from the PC, picked up in the header line of /cyd.txt.
   We only set a flag here and act on it in loop(): running the cracktro from
   inside poll() would mean parsing carries on afterwards on stale data. */
bool     cmdCracktro = false;
bool     cmdSeen     = false;   // already acted on the command now on offer

/* These four are deliberately local: they are on screen precisely when there
   is NO connection, so the PC cannot supply them. Set CYD_LANG_NL to 1 if you
   want the display in Dutch while it is offline. */
#define CYD_LANG_NL 0
#if CYD_LANG_NL
const char* TXT_OFFLINE   = "GEEN VERBINDING";
const char* TXT_NOANSWER  = "Geen antwoord van ";
const char* TXT_CHECKAPI  = "Draait de API op je pc? Klopt dit adres?";
const char* TXT_HOLDSETUP = "Bovenbalk 2 sec vasthouden = instellen";
#else
const char* TXT_OFFLINE   = "NO CONNECTION";
const char* TXT_NOANSWER  = "No answer from ";
const char* TXT_CHECKAPI  = "Is the API running on your PC? Is this address right?";
const char* TXT_HOLDSETUP = "Hold the top bar 2s to set up";
#endif

/* Short confirmations shown in the header bar after a tap. Local for the same
   reason as the four above: they appear the moment something goes wrong, when
   the PC may well be unreachable. */
#if CYD_LANG_NL
const char* TXT_NOREPLY   = "pc reageert niet";
const char* TXT_NOSESS    = "geen sessies";
const char* TXT_SETUP     = "instellen...";
const char* TXT_LIGHT     = "licht ";
const char* TXT_RETRY     = "poging ";
const char* TXT_AGO       = "s zonder contact";
#else
const char* TXT_NOREPLY   = "no reply from PC";
const char* TXT_NOSESS    = "no sessions";
const char* TXT_SETUP     = "setting up...";
const char* TXT_LIGHT     = "light ";
const char* TXT_RETRY     = "attempt ";
const char* TXT_AGO       = "s since last contact";
#endif
String   fingerprint = "";
String   attKey = "";
String   toast = "";
uint32_t toastUntil = 0;
int      btnFlash = -1;        // which on-screen button is lit (-1 = none)
/* Brightness ladder. Tap the top bar to step through it; the panel looks
   washed out quickly at a high setting. Once you find one you like, fix it as
   BACKLIGHT_PCT above and it starts there. */
const uint8_t BL_TRAP[] = { 100, 70, 50, 35, 25, 15 };
const int     N_BL = sizeof(BL_TRAP) / sizeof(BL_TRAP[0]);
int      blIdx = 1;            // points at 70, matching BACKLIGHT_PCT

uint32_t btnFlashUntil = 0;
bool     online = false;
uint32_t lastPoll = 0, lastOkMs = 0, lastTouch = 0;
int      pollFails = 0;        // consecutive failed polls, shown while offline

// ---- settings from NVS (declared here already: httpGet uses them) ----------
Preferences nvs;
String   cfgSsid, cfgPass, cfgHost;
uint16_t cfgPort = 8787;

bool      portaalActief = false;
/* Did the portal come up by itself, or did somebody ask for it by holding the
   top bar? Only the first kind may be taken away again when the cable starts
   feeding us -- the other is somebody halfway through typing a password. */
bool      portaalVanzelf = false;
WebServer portaalWeb(80);
DNSServer portaalDns;


// ===========================================================================
/* The LEDC API changed in ESP32 core 3.x (pin instead of channel). These
   wrappers keep the sketch working on both 2.x and 3.x. */
void setBacklight(uint8_t pct) {
  uint8_t duty = map(pct, 0, 100, 0, 255);
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(PIN_BL, 5000, 8);
  ledcWrite(PIN_BL, duty);
#else
  ledcSetup(LEDC_BL, 5000, 8);
  ledcAttachPin(PIN_BL, LEDC_BL);
  ledcWrite(LEDC_BL, duty);
#endif
}

void beep() {
  if (!BEEP_ENABLED) return;
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(PIN_SPK, 880, 10);
  ledcWriteTone(PIN_SPK, 880); delay(120);
  ledcWriteTone(PIN_SPK, 660); delay(120);
  ledcWriteTone(PIN_SPK, 0);
  ledcDetach(PIN_SPK);
#else
  ledcSetup(LEDC_TONE, 880, 10);
  ledcAttachPin(PIN_SPK, LEDC_TONE);
  ledcWriteTone(LEDC_TONE, 880); delay(120);
  ledcWriteTone(LEDC_TONE, 660); delay(120);
  ledcWriteTone(LEDC_TONE, 0);
  ledcDetachPin(PIN_SPK);
#endif
}

void setLed(bool r, bool g, bool b) {
#if USE_RGB_LED
  digitalWrite(PIN_LED_R, r ? LOW : HIGH);   // active low
  digitalWrite(PIN_LED_G, g ? LOW : HIGH);
  digitalWrite(PIN_LED_B, b ? LOW : HIGH);
#endif
}

uint16_t stateColor(const String& s) {
  if (s == "attention") return COL_ORANGE;
  if (s == "active")    return COL_GREEN;
  return COL_STEEL;
}

String stateLabel(const String& s) {
  // From the header line of /cyd.txt, so in the language of the PC.
  if (s == "attention") return uiState[0];
  if (s == "active")    return uiState[1];
  return uiState[2];
}

void say(const String& msg) {          // short message in the header line
  toast = msg;
  toastUntil = millis() + 2500;
}

// ---- painting --------------------------------------------------------------
/* How well is the radio holding up?

   "It works over the cable" and "it works" already look different in this bar,
   because the cable says USB. On Wi-Fi there was nothing at all, and that turned
   out to matter: -66 dBm here fetched sessions every three seconds and -85 could
   not open a connection, while the screen looked identical in both cases. Four
   bars is enough to tell those apart from across the room. */
static int wifiStaafjes() {
  if (WiFi.status() != WL_CONNECTED) return 0;
  int r = WiFi.RSSI();
  if (r >= -55) return 4;
  if (r >= -65) return 3;
  if (r >= -75) return 2;
  return 1;
}

/* Right-aligned on x2 and centred in the bar. Sized from HDR_H rather than
   written out twice, so the two panels stay in proportion if the bar changes. */
static void tekenStaafjes(int x2, int n, bool alarm) {
  int bh  = HDR_H / 2;
  int bw  = HDR_H / 10;  if (bw  < 2) bw  = 2;
  int gat = bw / 2;      if (gat < 1) gat = 1;
  int x0    = x2 - (4 * bw + 3 * gat);
  int onder = (HDR_H + bh) / 2;

  for (int i = 0; i < 4; i++) {
    bool aan = (i < n);
    /* On an orange header the missing bars are left out rather than painted in
       some third colour. That bar is asking for you; it is not the moment for a
       signal report. */
    if (!aan && alarm) continue;
    int h = bh * (i + 1) / 4;
    gfxFillRect(x0 + i * (bw + gat), onder - h, bw, h,
                aan ? (alarm ? COL_BG : COL_GREEN) : COL_MUTED);
  }
}

void drawHeader() {
  bool alarm = (nAtt > 0);
  uint16_t bg = alarm ? COL_ORANGE : COL_HDR;
  uint16_t ink = alarm ? COL_BG : COL_TXT;
  gfxFillRect(0, 0, SCR_W, HDR_H, bg);

  /* Offline the display has to say it itself; online the PC supplies the whole
     sentence already composed, because only there is it known whether it should
     read "1 needs you" or "2 need you" -- and in which language. */
  gfxText(GF_SMALL, GA_TL, 10, HDR_TXT_Y, online ? uiHeader : String(TXT_OFFLINE), ink, bg);

  String right = (millis() < toastUntil) ? toast : clockTxt;
  gfxText(GF_SMALL, GA_TR, SCR_W - 10, HDR_TXT_Y, right, ink, bg);

  /* Say which pipe the data came in over. Without it "it works" and "it works
     over the cable" look identical, and that is exactly what you want to know
     when the network is the thing you are unsure about. */
  /* Both, not one or the other. The first version showed the bars only when the
     cable was out, on the reasoning that this is one question -- which pipe? --
     and so wants one answer. It is two. Plugged in, the question you actually
     have is whether the Wi-Fi is set up and strong enough for the moment you
     unplug, and the version that hid the bars behind the cable answered exactly
     the wrong one.

     So: USB when the cable is feeding, and the bars whenever a network has been
     configured at all. Four dim bars mean it is configured and not connected
     right now, which is a different thing from having no network, and both are
     different from a weak link. Nothing at all only when no network was ever
     set. */
  int slot = SCR_W - 20 - gfxTextWidth(GF_SMALL, right);
  if (serialFresh()) {
    gfxText(GF_SMALL, GA_TR, slot, HDR_TXT_Y, "USB", alarm ? COL_BG : COL_GREEN, bg);
    slot -= gfxTextWidth(GF_SMALL, "USB") + 8;
  }
  if (cfgSsid.length()) tekenStaafjes(slot, wifiStaafjes(), alarm);
  gfxDrawHLine(0, HDR_H, SCR_W, COL_LINE);
}

/* i is the slot on screen, not the session. With scrolling those stopped being
   the same thing, and mixing them up is how you end up acting on the wrong
   session -- so the translation happens once, here. */
void drawRow(int i) {
  int y = ROW_Y + i * ROW_H;
  int r = scrollTop + i;
  const int RW = SCR_W - 12;              // row surface, 6 px margin either side
  gfxBufBegin(0, y, SCR_W, ROW_H - 3);
  gfxBufFill(COL_BG);

  if (r < nRows) {
    bool sel = (r == selIdx);
    uint16_t c = stateColor(rows[r].state);
    uint16_t rowBg = sel ? COL_SEL : COL_ROW;
    /* The stripe on the left says WHAT the session is doing, the lighter surface
       says which row is selected -- two separate signals, no extra outline. */
    gfxBufRoundRect(6, 0, RW, ROW_H - 3, 6, rowBg);
    gfxBufRect(6, 0, 3, ROW_H - 3, c);

    // Short names large, longer titles a size smaller: since the beacon started
    // sending the real session title, those names are much longer than a folder name.
    String nm = rows[r].name;
    if (nm.length() <= NAME_BIG_MAX) {
      gfxBufText(GF_BIG, GA_TL, 16, NAME_Y, nm, COL_TXT, rowBg);
    } else {
      if (nm.length() > NAME_MAX) nm = nm.substring(0, NAME_MAX - 1) + ".";
      gfxBufText(GF_SMALL, GA_TL, 16, NAME_SM_Y, nm, COL_TXT, rowBg);
    }

    /* State chip, just like Draw-Chip in hud.ps1: fill in the state colour at
       alpha 38 over the row, border at 150, text in the full colour. That is
       where the green (and the orange, on attention) really shows. */
    uint16_t chipBg = blend565(c, rowBg, 38);
    String lbl = stateLabel(rows[r].state);
    int cw = gfxBufTextWidth(GF_SMALL, lbl) + 14, ch = CHIP_H;
    int cx = SCR_W - 14 - cw, cy = 3;
    gfxBufRoundRect(cx, cy, cw, ch, 4, chipBg);
    gfxBufDrawRoundRect(cx, cy, cw, ch, 4, blend565(c, rowBg, 150));
    gfxBufText(GF_SMALL, GA_MC, cx + cw / 2, cy + ch / 2, lbl, c, chipBg);

    String w = rows[r].since + "  " + rows[r].why;
    if (w.length() > WHY_MAX) w = w.substring(0, WHY_MAX - 1) + ".";
    gfxBufText(GF_SMALL, GA_TL, 16, INFO_Y, w, COL_MUTED, rowBg);
  } else if (r == 0) {
    if (online) {
      gfxBufText(GF_SMALL, GA_TL, 16, 10, uiEmpty, COL_MUTED, COL_BG);
    } else {
      /* Name the address it is trying. A typo in the PC address is otherwise
         impossible to find: Wi-Fi works, so the portal never appears by itself,
         and the screen only said "waiting for the PC" without saying for what. */
      gfxBufText(GF_SMALL, GA_TL, 16, 3,
                 String(TXT_NOANSWER) + cfgHost + ":" + cfgPort, COL_ORANGE, COL_BG);
      gfxBufText(GF_SMALL, GA_TL, 16, 21, TXT_CHECKAPI, COL_MUTED, COL_BG);
    }
  } else if (r == 1 && !online && !nRows) {
    gfxBufText(GF_SMALL, GA_TL, 16, 10, TXT_HOLDSETUP, COL_MUTED, COL_BG);
  }

  /* A hairline on the right edge showing where you are. Three pixels wide, but it
     answers the one question the screen could not: is there anything below? */
  if (scrollable()) {
    int hoog = (MAX_ROWS * ROW_H) - 6;
    int dik  = (hoog * MAX_ROWS) / nRows;
    if (dik < 8) dik = 8;
    int top  = (scrollMax() > 0) ? ((hoog - dik) * scrollTop) / scrollMax() : 0;
    int mijn = y - ROW_Y;                       // where this slot sits in the list
    gfxBufRect(SCR_W - 4, 0, 3, ROW_H - 3, COL_ROW);
    for (int k = 0; k < ROW_H - 3; k++) {
      int abs = mijn + k;
      if (abs >= top && abs < top + dik) gfxBufHLine(SCR_W - 4, k, 3, COL_MUTED);
    }
  }

  gfxBufPush();
  gfxBufEnd();
}

/* One source for the position of button i, so the drawn surface and the hit
   area cannot drift apart. They did: drawing used 6 + i*104 (width 100) while
   a tap was rounded with x / 107. As long as there was no visible feedback
   nobody noticed; with a button that lights up you see immediately that you
   pressed next to it. */
void btnRect(int i, int& x, int& w) {
  w = BTN_W;
  x = 6 + i * (w + BTN_GAP);
}

/* The third slot doubles as the scroll control once there are more sessions than
   rows. Returns 0..2 for a button, or HIT_UP / HIT_DOWN for the arrows. */
#define HIT_NONE -1
#define HIT_UP   -2
#define HIT_DOWN -3

int btnHit(int x) {
  for (int i = 0; i < 3; i++) {
    int bx, bw;
    btnRect(i, bx, bw);
    if (x < bx || x >= bx + bw) continue;
    if (i == 2 && scrollable()) {
      // left half up, right half down -- reading order, and it matches the
      // triangles drawn in those halves
      return (x < bx + bw / 2) ? HIT_UP : HIT_DOWN;
    }
    return i;
  }
  return HIT_NONE;
}

/* The two arrows, drawn in the third slot instead of a label. Triangles rather
   than a font glyph: no font here has a usable arrow, and two filled triangles
   read better at this size than any character would. */
void drawArrows(bool flashUp, bool flashDown) {
  int x, w;
  btnRect(2, x, w);
  int h = BAR_H - 6, half = w / 2;

  for (int k = 0; k < 2; k++) {
    bool aan = k ? flashDown : flashUp;
    int  bx  = x + k * half;
    uint16_t vlak = aan ? COL_GREEN : COL_ROW;
    uint16_t ink  = aan ? COL_BG : (scrollable() ? COL_TXT : COL_MUTED);
    gfxFillRoundRect(bx + 1, BAR_Y, half - 2, h, 6, vlak);
    gfxDrawRoundRect(bx + 1, BAR_Y, half - 2, h, 6, aan ? COL_GREEN : COL_LINE);

    // grey out the end of the road, so you can see there is nothing further
    if (k == 0 && scrollTop <= 0)           ink = COL_LINE;
    if (k == 1 && scrollTop >= scrollMax()) ink = COL_LINE;

    int cx = bx + half / 2, cy = BAR_Y + h / 2, s = 6;
    if (k == 0) gfxFillTriangle(cx, cy - s, cx - s, cy + s, cx + s, cy + s, ink);
    else        gfxFillTriangle(cx, cy + s, cx - s, cy - s, cx + s, cy - s, ink);
  }
}

void drawButton(int i, bool pressed) {
  int x, w;
  btnRect(i, x, w);
  uint16_t vlak = pressed ? COL_GREEN : COL_ROW;
  uint16_t ink  = pressed ? COL_BG    : COL_TXT;
  gfxFillRoundRect(x, BAR_Y, w, BAR_H - 6, 6, vlak);
  // The row surface sits close to the background, so without a border you would
  // not see that these are buttons.
  gfxDrawRoundRect(x, BAR_Y, w, BAR_H - 6, 6, pressed ? COL_GREEN : COL_LINE);
  String l = btnLabel[i];
  if (l.length() > 13) l = l.substring(0, 12) + ".";
  gfxText(GF_SMALL, GA_MC, x + w / 2, BAR_Y + (BAR_H - 6) / 2, l, ink, vlak);
}

void scrollBy(int delta, bool wrap) {
  if (!scrollable()) return;
  int v = scrollTop + delta;
  if (wrap) {
    if (v > scrollMax()) v = 0;
    else if (v < 0)      v = scrollMax();
  }
  scrollTop = v;
  clampScroll();
  fingerprint = "";        // force a repaint: every row moved
  drawAll();
}

// Light up button i. loop() does the redraw, so no delay() is needed in touch
// or button handling and polling simply carries on.
void flashButton(int i) {
  if (i == HIT_UP || i == HIT_DOWN) {
    btnFlash = i;
    btnFlashUntil = millis() + 180;
    drawArrows(i == HIT_UP, i == HIT_DOWN);
    return;
  }
  if (i < 0 || i > 2) return;
  btnFlash = i;
  btnFlashUntil = millis() + 180;
  drawButton(i, true);
}

void drawButtonBar() {
  gfxFillRect(0, BAR_Y - 4, SCR_W, SCR_H - (BAR_Y - 4), COL_BG);
  gfxDrawHLine(0, BAR_Y - 4, SCR_W, COL_LINE);
  int n = scrollable() ? 2 : 3;
  for (int i = 0; i < n; i++) drawButton(i, i == btnFlash);
  if (scrollable()) drawArrows(btnFlash == HIT_UP, btnFlash == HIT_DOWN);
}

/* Het levende deel van het offline-scherm. Alleen dit strookje wordt hertekend,
   vijf keer per seconde: een balkje dat vollooopt naar de volgende poging, het
   pogingnummer en hoe lang er al geen contact is. Zo zie je dat hij bezig is in
   plaats van een stilstaande foutmelding. */
void drawRetry() {
  /* In the third row's place: row 1 carries the "hold the top bar" hint, and that
     would otherwise be wiped five times a second. */
  const int Y = ROW_Y + 2 * ROW_H + 2;
  const int RW = SCR_W - 12;
  uint32_t interval = POLL_MS_OFF;
  uint32_t sinds    = millis() - lastPoll;
  if (sinds > interval) sinds = interval;

  // a bar filling towards the next attempt
  int vol = (int)((uint32_t)RW * sinds / interval);
  gfxBufBegin(0, Y, SCR_W, 22);
  gfxBufFill(COL_BG);
  gfxBufRect(6, 0, RW, 3, COL_ROW);
  gfxBufRect(6, 0, vol, 3, COL_ORANGE);

  /* The RSSI is here because this is usually range rather than a fault in the
     software. At -75 dBm or lower the display is too far from your access point
     and no setting will fix it. */
  uint32_t weg = (millis() - lastOkMs) / 1000;
  String s = String(TXT_RETRY) + pollFails + "  -  " + weg + TXT_AGO;
  if (WiFi.status() == WL_CONNECTED) s += "  -  " + String(WiFi.RSSI()) + " dBm";
  else                               s += "  -  no wifi";
  gfxBufText(GF_SMALL, GA_TL, 16, 7, s, COL_MUTED, COL_BG);
  gfxBufPush();
  gfxBufEnd();
}

void drawAll() {
  drawHeader();
  for (int i = 0; i < MAX_ROWS; i++) drawRow(i);
  drawButtonBar();
}

void flashAttention() {
  for (int k = 0; k < 3; k++) {
    gfxFillRect(0, 0, SCR_W, HDR_H, COL_ORANGE); gfxFlushNow(); delay(120);
    gfxFillRect(0, 0, SCR_W, HDR_H, COL_BG);     gfxFlushNow(); delay(120);
  }
  drawHeader();
}

/* ---- the USB transport -----------------------------------------------------
   The PC can push the very same payload over the USB cable that it serves on
   /cyd.txt. That matters on a network where port 8787 is blocked -- an office
   firewall -- while the display is hanging off the laptop by a cable anyway.

   The PC pushes; we do not ask. Whatever arrived last is kept, and while it is
   fresh it wins over Wi-Fi. So there is no handshake and nothing ever blocks
   waiting for a peer that is not there: put this on a USB charger with no PC and
   nothing arrives, FRESH expires, and it goes back to Wi-Fi by itself.

   Everything the PC sends is framed, because this same serial port carries our
   own debug output. Ours to the PC start with @ for the same reason. */
const uint32_t SERIAL_FRESH_MS = 10000;

String   serPayload   = "";     // last complete block from the PC
uint32_t serAt        = 0;      // when it arrived (0 = never)
String   serReply     = "";     // last @REPLY
bool     serHaveReply = false;
String   serLine      = "";     // line being assembled
String   serBlock     = "";
bool     serInBlock   = false;

bool serialFresh() { return serAt && (millis() - serAt < SERIAL_FRESH_MS); }

/* ---- Wi-Fi settings over the cable ----------------------------------------

   A board that has never been told a network says so, and the PC answers with
   every network it knows a password for. The choice is made here rather than
   there, and deliberately: this radio is 2.4 GHz only, while the PC is perfectly
   happy on 5 GHz -- ask the PC which network to use and it will confidently name
   one this board can never see. Scanning and picking the first one that is
   actually on the air puts the decision where the evidence is.

   Base64 per field because an SSID or a passphrase may contain a space, a pipe,
   or anything else that would otherwise have to be escaped out of the way. */
#define MAX_WIFI_KANDIDAAT 12

struct WifiKandidaat { String ssid; String pass; };
WifiKandidaat wifiKand[MAX_WIFI_KANDIDAAT];
int           nWifiKand  = 0;
String        wifiHost   = "";
uint16_t      wifiPoort  = 0;

static String b64uit(const String& in) {
  unsigned char buf[130];            // 32-byte SSID and 63-byte passphrase both fit
  size_t uit = 0;
  if (mbedtls_base64_decode(buf, sizeof(buf) - 1, &uit,
                            (const unsigned char*)in.c_str(), in.length()) != 0) return "";
  buf[uit] = 0;
  return String((const char*)buf);
}

// "@WIFI <b64 ssid> <b64 pass>" -- one per network, in the order the PC prefers.
static void wifiKandidaatErbij(const String& rest) {
  if (nWifiKand >= MAX_WIFI_KANDIDAAT) return;
  int sp = rest.indexOf(' ');
  String ssid = b64uit(sp < 0 ? rest : rest.substring(0, sp));
  String pass = sp < 0 ? String("") : b64uit(rest.substring(sp + 1));
  if (!ssid.length()) return;
  wifiKand[nWifiKand].ssid = ssid;
  wifiKand[nWifiKand].pass = pass;
  nWifiKand++;
}

void kiesWifiUitLijst() {
  int aantal = nWifiKand;
  nWifiKand = 0;                     // whatever happens, the list is spent
  if (aantal == 0) return;

  /* Not while the portal is up. It runs an access point, and scanning pulls the
     radio out from under it -- and somebody is looking at that screen. */
  if (portaalActief)   { Serial.println("wifi: portaal staat open, lijst genegeerd"); return; }
  if (cfgSsid.length()) { Serial.println("wifi: al ingesteld, lijst genegeerd");      return; }

  Serial.printf("wifi: %d netwerken aangeboden, scannen\n", aantal);
  int n = WiFi.scanNetworks();
  int gekozen = -1;
  for (int k = 0; k < aantal && gekozen < 0; k++)
    for (int i = 0; i < n; i++)
      if (WiFi.SSID(i) == wifiKand[k].ssid) { gekozen = k; break; }
  WiFi.scanDelete();

  if (gekozen < 0) {
    Serial.printf("wifi: geen van de %d is hier te horen -- 5 GHz?\n", aantal);
    return;
  }
  Serial.printf("wifi: \"%s\" gekozen\n", wifiKand[gekozen].ssid.c_str());
  cfgSsid = wifiKand[gekozen].ssid;
  cfgPass = wifiKand[gekozen].pass;
  if (wifiHost.length()) {
    cfgHost  = wifiHost;
    cfgPort  = wifiPoort ? wifiPoort : 8787;
  }
  bewaarInstellingen(cfgSsid, cfgPass, cfgHost, cfgPort);
  WiFi.mode(WIFI_STA);
  WiFi.begin(cfgSsid.c_str(), cfgPass.c_str());
}

// Say so when there is no network to fall back on, so the PC can offer its own.
static void meldGeenWifi() { if (!cfgSsid.length()) Serial.println("@NOWIFI"); }

// Read whatever has arrived. Never blocks, so it is safe to call from anywhere.
void serialPump() {
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\r') continue;
    if (c != '\n') {
      if (serLine.length() < 400) serLine += c;   // a runaway line cannot grow forever
      continue;
    }
    String l = serLine;
    serLine = "";
    l.trim();

    if (l == "<<<CYD") { serInBlock = true; serBlock = ""; }
    else if (l == ">>>") {
      if (serInBlock && serBlock.length()) {
        // Announce the first block, and any return after a gap. Without this the
        // cable is a black box: you cannot tell "not receiving" from "receiving
        // and ignoring", which are very different problems.
        if (!serialFresh()) {
          Serial.printf("serial: payload received (%u bytes)\n", (unsigned)serBlock.length());
          // Announce ourselves on the way in, so the PC knows which firmware
          // is on the other end of the cable.
          Serial.println(String("@FW ") + FW_VERSION);
          /* And whether we have a network. This is the moment that covers a
             board which booted while the service was already attached -- it
             never gets asked then, so it has to volunteer. */
          meldGeenWifi();
        }
        serPayload = serBlock;
        serAt = millis();
      }
      serInBlock = false;
    }
    else if (serInBlock) {
      if (serBlock.length() < 2048) { serBlock += l; serBlock += "\n"; }
    }
    else if (l.startsWith("@REPLY ")) { serReply = l.substring(7); serHaveReply = true; }
    /* Answer a direct question about the firmware. The announcement above only
       fires on the first block after a gap, which covers a display that has just
       been plugged in and does nothing for the case that matters as much: the PC
       service restarting. The payload on this side is still fresh then, so
       nothing is announced and the About box cannot say what is running. */
    else if (l == "?FW") { Serial.println(String("@FW ") + FW_VERSION); meldGeenWifi(); }

    /* Networks the PC knows a password for, then where to reach it, then a line
       saying that is all -- at which point we scan and pick. Note the space in
       "@WIFI ": it is what keeps this from swallowing "@WIFIEND". */
    else if (l.startsWith("@WIFI "))  { wifiKandidaatErbij(l.substring(6)); }
    else if (l == "@WIFIEND")         { kiesWifiUitLijst(); }
    else if (l.startsWith("@HOST ")) {
      String rest = l.substring(6);
      int sp = rest.indexOf(' ');
      wifiHost  = sp < 0 ? rest : rest.substring(0, sp);
      wifiPoort = sp < 0 ? 0    : (uint16_t)rest.substring(sp + 1).toInt();
    }
  }
}

/* Ask the PC something and wait briefly for its answer. Only used on a tap or a
   button press, so a short block is acceptable -- and 1500 ms is generous: the
   PC answers in milliseconds unless it is busy raising a window. */
String serialAsk(const String& cmd) {
  serHaveReply = false;
  serReply = "";
  Serial.println(cmd);
  uint32_t t0 = millis();
  while (millis() - t0 < 1500) {
    serialPump();
    if (serHaveReply) return serReply;
    delay(5);
  }
  return "";
}

// ---- talking to the PC -----------------------------------------------------
String httpGet(const String& path) {
  /* Show what has been drawn before blocking on the network. Without this a
     tapped row would not light up until its request had come back, which on a
     PC that is not answering is the entire HTTP timeout. */
  gfxFlushNow();
  if (WiFi.status() != WL_CONNECTED) {
    static uint32_t lastWifiLog = 0;
    if (millis() - lastWifiLog > 2000) { lastWifiLog = millis(); Serial.println("poll: wifi not connected"); }
    return "";
  }
  HTTPClient http;
  String url = String("http://") + cfgHost + ":" + cfgPort + path;
  /* 4 s while things are going well: the API can take 1.5 s on a cold cache and
     that poll is worth keeping. Offline a long timeout is actively harmful,
     because every failed attempt then costs 4 seconds and a flaky link leaves
     you staring at nothing for a minute. But not too short either: 1500 ms was a
     trap -- if the API takes 1.3 s the poll just misses, we stay offline and keep
     the short timeout, which sustains itself. 3000 ms sits clear of the slowest
     response measured and still halves the cost of a failure. */
  uint16_t tmo = online ? 4000 : 3000;
  http.setConnectTimeout(tmo);
  http.setTimeout(tmo);
  if (!http.begin(url)) { Serial.println("poll: begin() failed"); return ""; }
  uint32_t t0 = millis();
  int code = http.GET();
  String body = (code == 200) ? http.getString() : String("");
  http.end();
  /* Log why a poll failed. Rate-limited, because while offline this runs every
     POLL_MS_OFF and would otherwise bury everything else in the log. */
  if (code != 200) {
    static uint32_t lastLog = 0;
    if (millis() - lastLog > 2000) {
      lastLog = millis();
      Serial.printf("poll: HTTP %d after %lu ms, heap %u, rssi %d\n",
                    code, (unsigned long)(millis() - t0),
                    (unsigned)ESP.getFreeHeap(), WiFi.RSSI());
    }
  }
  return body;
}

String tokenArg() {
  return (strlen(API_TOKEN) > 0) ? String("&t=") + API_TOKEN : String("");
}

/* One place that decides which pipe to use. Serial when the PC is pushing,
   otherwise HTTP -- no token over serial, because a cable plugged into that
   machine is its own proof of access. */
String reqFocus(const String& id) {
  if (serialFresh()) return serialAsk("@FOCUS " + id);
  return httpGet("/focus?id=" + id + tokenArg());
}

String reqAction(const String& id, const char* btn) {
  if (serialFresh()) return serialAsk(String("@ACTION ") + id + " " + btn);
  return httpGet("/action?id=" + id + "&b=" + btn + tokenArg());
}

void sendFocus(int idx) {
  if (idx < 0 || idx >= nRows) return;
  String r = reqFocus(rows[idx].id);
  say(r.length() ? r.substring(0, 40) : String(TXT_NOREPLY));
  drawHeader();
}

void sendAction(const char* btn) {
  if (nRows == 0) { say(TXT_NOSESS); drawHeader(); return; }
  int idx = (selIdx >= 0 && selIdx < nRows) ? selIdx : 0;
  String r = reqAction(rows[idx].id, btn);
  say(r.length() ? r.substring(0, 40) : String(TXT_NOREPLY));
  drawHeader();
}

// ---- fetching data ---------------------------------------------------------
// Split a list separated by ';' -- button labels and state labels arrive that
// way in the header line of /cyd.txt.
void splitList(const String& in, String* uit, int n) {
  int p = 0;
  for (int i = 0; i < n; i++) {
    int sc = in.indexOf(';', p);
    uit[i] = (sc < 0) ? in.substring(p) : in.substring(p, sc);
    if (sc < 0) { for (int j = i + 1; j < n; j++) uit[j] = ""; return; }
    p = sc + 1;
  }
}

void splitFields(const String& line, int from, String* f, int n) {
  int p = from;
  for (int i = 0; i < n; i++) {
    int bar = line.indexOf('|', p);
    if (bar < 0) { f[i] = line.substring(p); for (int k = i + 1; k < n; k++) f[k] = ""; return; }
    f[i] = line.substring(p, bar);
    p = bar + 1;
  }
}

bool poll() {
  serialPump();
  // Serial wins while it is fresh: it is the cheaper and more reliable of the
  // two, and on a blocked network it is the only one that works at all.
  /* The version rides along on the poll. Over Wi-Fi that is the only chance the
     PC gets to learn it, and it costs one query parameter. */
  String body = serialFresh() ? serPayload : httpGet(String("/cyd.txt?fw=") + FW_VERSION);
  if (!body.length()) return false;

  int    n = 0, att = 0, act = 0, done = 0;
  String clk = clockTxt, newAtt = "";
  String labels[3] = { btnLabel[0], btnLabel[1], btnLabel[2] };
  Sess   tmp[MAX_SESS];

  int start = 0;
  while (start < (int)body.length()) {
    int nl = body.indexOf('\n', start);
    if (nl < 0) nl = body.length();
    String line = body.substring(start, nl);
    line.trim();
    start = nl + 1;
    if (!line.length()) continue;

    if (line.charAt(0) == '#') {
      /* #<att>|<act>|<done>|<HH:mm>|<button labels ;>|<header text>|<state labels ;>|<cmd>
         The last fields were added later; an older API does not send them and we
         simply keep the fallback. */
      String f[8];
      splitFields(line, 1, f, 8);
      att = f[0].toInt(); act = f[1].toInt(); done = f[2].toInt();
      if (f[3].length()) clk = f[3];
      if (f[4].length()) splitList(f[4], labels, 3);      // button labels
      if (f[5].length()) uiHeader = f[5];                 // "3 WORKING" / "2 NEED YOU"
      if (f[6].length()) {
        String s[4];
        splitList(f[6], s, 4);
        for (int i = 0; i < 3; i++) if (s[i].length()) uiState[i] = s[i];
        if (s[3].length()) uiEmpty = s[3];
      }
      /* The PC keeps a command on offer for a few seconds, so act on it once and
         then wait until the field is empty again before arming for the next. */
      if (!f[7].length())                     cmdSeen = false;
      else if (f[7] == "cracktro" && !cmdSeen) { cmdCracktro = true; cmdSeen = true; }
      continue;
    }

    if (n >= MAX_SESS) continue;
    String f[5];
    splitFields(line, 0, f, 5);
    tmp[n].state = f[0];
    tmp[n].name  = f[1];
    tmp[n].since = f[2];
    tmp[n].why   = f[3];
    tmp[n].id    = f[4];
    if (f[0] == "attention") newAtt += f[4] + ";";
    n++;
  }

  String fp = String(att) + "/" + act + "/" + done + "#";
  for (int i = 0; i < n; i++) fp += tmp[i].state + tmp[i].name + tmp[i].since + tmp[i].why + ";";
  fp += "@" + labels[0] + labels[1] + labels[2] + "#" + String(selIdx) + "/" + String(scrollTop);

  bool freshAttention = (newAtt.length() > 0 && newAtt != attKey);

  // Keep the selection on the same session as much as possible
  String selId = (selIdx >= 0 && selIdx < nRows) ? rows[selIdx].id : "";
  nAtt = att; nAct = act; nDone = done; clockTxt = clk; nRows = n;
  for (int i = 0; i < n; i++) rows[i] = tmp[i];
  for (int i = 0; i < 3; i++) btnLabel[i] = labels[i];
  attKey = newAtt;
  lastOkMs = millis();

  selIdx = 0;
  if (selId.length()) {
    for (int i = 0; i < n; i++) if (rows[i].id == selId) { selIdx = i; break; }
  }
  // a new attention request? you want that selected, it is what you will press
  if (freshAttention) {
    for (int i = 0; i < n; i++) if (rows[i].state == "attention") { selIdx = i; break; }
  }

  /* Bring what matters into view. Sessions can now sit below the fold, and an
     orange alarm down there would be worse than no alarm at all: you would learn
     that a quiet screen does not mean nothing wants you. So a fresh attention
     request scrolls itself in, and otherwise we simply keep the selection
     visible. */
  clampScroll();
  if (freshAttention) scrollToRow(selIdx);
  else if (selIdx >= 0 && selIdx < nRows) scrollToRow(selIdx);

  setLed(att > 0, att > 0 || act > 0, false);   // orange = red+green, green = working

  if (fp != fingerprint) { fingerprint = fp; drawAll(); }
  else { drawHeader(); }

  if (freshAttention) { beep(); flashAttention(); }
  return true;
}

// ---- touch -----------------------------------------------------------------
bool readTouch(int& sx, int& sy) {
  // The mapping itself lives in the backend: which axes to swap and which way
  // round the glass sits is a property of the panel, not of this sketch.
  return gfxTouchPoint(sx, sy);
}

/* One press must count once, and the debounce alone cannot promise that.

   The debounce clock starts before the request goes out, and a request over the
   cable blocks for as long as the PC takes to answer -- up to a second and a half
   while it raises a window. By the time we are back, 350 ms has long passed, so
   the report the panel makes when the finger comes off is read as a fresh press
   and the whole thing runs a second time. Measured over USB: every tap and every
   button arrived twice, which on the approve button means two Enters.

   So wait for the finger to actually leave before the clock starts. The ceiling
   is there because a panel that insists it is still being touched must not be
   able to hold the loop. */
static void wachtTotLos() {
  uint32_t t0 = millis();
  while (gfxTouched() && millis() - t0 < 1000) delay(10);
  lastTouch = millis();
}

void handleTouch() {
  int x, y;
  if (!readTouch(x, y)) return;
  if (millis() - lastTouch < 350) return;      // debounce
  lastTouch = millis();

  /* Top bar: a short tap steps the brightness, holding for two seconds opens the
     setup portal. That long press is the way out when it IS on Wi-Fi but the PC
     address is wrong -- the portal never comes up by itself then, and without
     USB you would be stuck.
     It has to be touch and not a button: button 3 needs an external resistor
     that may not be there, and holding BOOT during power-up puts the ESP32 into
     flash mode. */
  if (y < HDR_H) {
    uint32_t neer = millis();
    while (gfxTouched() && millis() - neer < 2200) delay(50);
    if (millis() - neer >= 2000) {
      say(TXT_SETUP);
      drawHeader();
      portaalVanzelf = false;          // asked for, so the cable does not get to end it
      startPortaal();
      return;
    }
    blIdx = (blIdx + 1) % N_BL;
    setBacklight(BL_TRAP[blIdx]);
    Serial.printf("helderheid %d%%\n", BL_TRAP[blIdx]);
    say(String(TXT_LIGHT) + BL_TRAP[blIdx] + "%");
    drawHeader();
    return;
  }

  if (y >= ROW_Y && y < ROW_Y + MAX_ROWS * ROW_H) {
    int i = scrollTop + (y - ROW_Y) / ROW_H;   // slot -> session
    if (i < nRows) {
      selIdx = i;
      drawAll();
      sendFocus(i);
      wachtTotLos();
    }
    return;
  }
  if (y >= BAR_Y) {                             // tapped on a button
    int i = btnHit(x);
    if (i == HIT_NONE) return;                  // in the gap between two buttons
    if (i == HIT_UP || i == HIT_DOWN) {
      flashButton(i);
      scrollBy(i == HIT_UP ? -1 : 1, false);
      wachtTotLos();
      return;
    }
    flashButton(i);
    char b[2] = { (char)('1' + i), 0 };
    sendAction(b);
    wachtTotLos();
  }
}

// ---- buttons ---------------------------------------------------------------
void handleButtons() {
  for (int i = 0; i < N_BTN; i++) {
    bool down = (digitalRead(BUTTONS[i].pin) == LOW);
    /* The BOOT button is the exception: it decides on RELEASE, because a short
       press is button 4 and a two-second hold opens the cracktro. The other
       buttons fire on the falling edge, because you do not want a delay on an
       approve button. */
    if (BUTTONS[i].pin == 0) {
      if (down && !btnWas[i]) btnAt[i] = millis();
      if (!down && btnWas[i]) {
        uint32_t vast = millis() - btnAt[i];
        Serial.printf("BOOT held %lu ms\n", (unsigned long)vast);
        if (vast >= 2000)     cracktro();
        else if (vast > 40)   sendAction(BUTTONS[i].id);   // 40 ms = debounce
      }
      btnWas[i] = down;
      continue;
    }

    if (down && !btnWas[i] && millis() - btnAt[i] > 250) {
      btnAt[i] = millis();
      /* While the arrows are showing, the third button scrolls instead. Otherwise
         it would still snooze while the label next to it shows an arrow, and a
         button that does something other than what it says is worse than a button
         that does less. Down with a wrap to the top: one button, so one
         direction, and paging round is the natural reading of that. */
      if (i == 2 && scrollable()) {
        flashButton(HIT_DOWN);
        scrollBy(1, true);
      } else {
        flashButton(i);        // buttons 1-3 have an on-screen surface; the BOOT button does not
        sendAction(BUTTONS[i].id);
      }
    }
    btnWas[i] = down;
  }
}

// ---- settings in NVS -------------------------------------------------------
/* Wi-Fi and the PC address live in NVS (the flash area a new sketch does not
   erase), not in the code. That keeps passwords out of git and lets you move
   the thing to another network without USB -- which helps, because that cable
   is the unreliable part here. */
/* Strip anything that has no business in a hostname or IP address. A phone
   keyboard hands you a trailing space or a non-breaking space without showing it,
   and HTTPClient then treats the result as a name to look up rather than an IP
   literal -- so it spends its whole timeout on a DNS query that can never
   succeed, and not one packet ever reaches the PC. Signal strength has nothing
   to do with it, which is what made this so confusing to chase. */
String schoonHost(const String& in) {
  String uit;
  for (size_t i = 0; i < in.length(); i++) {
    char c = in[i];
    bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
              (c >= 'A' && c <= 'Z') || c == '.' || c == '-' || c == '_';
    if (ok) uit += c;
  }
  return uit;
}

void leesInstellingen() {
  nvs.begin("claudedeck", true);          // true = read only
  cfgSsid = nvs.getString("ssid", WIFI_SSID_START);
  cfgPass = nvs.getString("pass", WIFI_PASS_START);
  cfgHost = nvs.getString("host", API_HOST_START);
  cfgPort = nvs.getUShort("port", API_PORT_START);
  nvs.end();
  if (cfgPort == 0) cfgPort = 8787;
  cfgHost = schoonHost(cfgHost);   // repareert ook een adres dat al fout in NVS staat
  Serial.printf("instellingen: ssid=\"%s\" host=%s:%u\n",
                cfgSsid.c_str(), cfgHost.c_str(), cfgPort);
}

void bewaarInstellingen(const String& ssid, const String& pass,
                        const String& host, uint16_t port) {
  nvs.begin("claudedeck", false);
  nvs.putString("ssid", ssid);
  nvs.putString("pass", pass);
  nvs.putString("host", host);
  nvs.putUShort("port", port);
  nvs.end();
  Serial.println("instellingen bewaard in NVS");
}

// ---- portal ----------------------------------------------------------------
// what the display shows while the portal is open
void portaalToon() {
  gfxFillScreen(COL_BG);
  gfxText(GF_BIG,   GA_TL, 14,  12, "Instellen", COL_ORANGE, COL_BG);
  gfxText(GF_SMALL, GA_TL, 14,  52, "Verbind je telefoon met dit wifi-netwerk:", COL_MUTED, COL_BG);
  gfxText(GF_BIG,   GA_TL, 14,  72, PORTAAL_SSID, COL_TXT, COL_BG);
  gfxText(GF_SMALL, GA_TL, 14, 104, String("wachtwoord: ") + PORTAAL_PASS, COL_MUTED, COL_BG);
  gfxText(GF_SMALL, GA_TL, 14, 136, "Springt er geen pagina open, ga dan naar:", COL_TXT, COL_BG);
  gfxText(GF_BIG,   GA_TL, 14, 156, WiFi.softAPIP().toString(), COL_GREEN, COL_BG);
  gfxText(GF_SMALL, GA_TL, 14, 200, "Na opslaan herstart hij zelf.", COL_MUTED, COL_BG);
  /* Push it. Every other screen in this sketch is flushed by the bottom of
     loop(), and the portal is the one path that never gets there -- so on a
     panel that draws into a buffer this whole page stayed in PSRAM and the
     display sat black. It looked like a board that would not start. */
  gfxFlushNow();
}

static String htmlVeilig(const String& in) {
  String uit;
  for (size_t i = 0; i < in.length(); i++) {
    char c = in[i];
    if      (c == '&')  uit += "&amp;";
    else if (c == '<')  uit += "&lt;";
    else if (c == '>')  uit += "&gt;";
    else if (c == '"')  uit += "&quot;";
    else                uit += c;
  }
  return uit;
}

String portaalPagina() {
  // Scanning is allowed in AP_STA mode; no need to wait, this takes a few
  // hundred ms and only happens when somebody opens the page.
  int n = WiFi.scanNetworks();

  String opties;
  for (int i = 0; i < n && i < 20; i++) {
    String s = WiFi.SSID(i);
    if (!s.length()) continue;
    opties += "<option value=\"" + htmlVeilig(s) + "\"";
    if (s == cfgSsid) opties += " selected";
    opties += ">" + htmlVeilig(s) + "  (" + String(WiFi.RSSI(i)) + " dBm)</option>";
  }
  if (!opties.length()) opties = "<option value=\"\">-- geen netwerk gevonden --</option>";

  String p = F(R"(<!doctype html><html lang="nl"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Claude Deck instellen</title><style>
body{background:#2A3238;color:#EEF3F5;font:16px/1.5 system-ui,sans-serif;margin:0;padding:24px}
h1{font-size:20px;margin:0 0 4px}p.s{color:#8E9C8B;margin:0 0 20px;font-size:14px}
label{display:block;margin:14px 0 4px;color:#8E9C8B;font-size:14px}
select,input{width:100%;box-sizing:border-box;padding:11px;border-radius:8px;
 border:1px solid #3A444B;background:#2E3840;color:#EEF3F5;font-size:16px}
button{width:100%;margin-top:22px;padding:14px;border:0;border-radius:8px;
 background:#91C847;color:#1F262F;font-size:17px;font-weight:600}
</style></head><body>
<h1>Claude Deck</h1><p class="s">Wifi en het adres van je pc</p>
<form method="POST" action="/opslaan">
<label>Netwerk</label><select name="ssid">)");

  p += opties;
  p += F(R"(</select>
<label>Wachtwoord</label><input name="pass" type="password" placeholder="laat leeg voor een open netwerk">
<label>Adres van je pc</label><input name="host" value=")");
  p += htmlVeilig(cfgHost);
  p += F(R"(" placeholder="192.168.1.10">
<label>Poort</label><input name="port" type="number" value=")");
  p += String(cfgPort);
  p += F(R"(">
<button type="submit">Opslaan en herstarten</button>
</form></body></html>)");
  return p;
}

void portaalOpslaan() {
  String ssid = portaalWeb.arg("ssid");
  String pass = portaalWeb.arg("pass");
  String host = portaalWeb.arg("host");
  uint16_t port = (uint16_t)portaalWeb.arg("port").toInt();
  if (port == 0) port = 8787;

  if (!ssid.length()) {
    portaalWeb.send(400, "text/html; charset=utf-8",
                    "<meta charset=utf-8><body style='background:#2A3238;color:#EEF3F5;"
                    "font:16px system-ui;padding:24px'>Kies eerst een netwerk. "
                    "<a style='color:#91C847' href='/'>Terug</a></body>");
    return;
  }

  bewaarInstellingen(ssid, pass, schoonHost(host), port);
  portaalWeb.send(200, "text/html; charset=utf-8",
                  "<meta charset=utf-8><body style='background:#2A3238;color:#EEF3F5;"
                  "font:16px system-ui;padding:24px'>Opgeslagen. Het schermpje "
                  "herstart nu en verbindt met <b>" + htmlVeilig(ssid) +
                  "</b>.</body>");
  delay(800);                       // give the page a moment to be sent
  ESP.restart();
}

/* Close the portal without rebooting.

   Rebooting was the first attempt and it is a trap: a restart makes the PC's
   open handle on the port useless, the service needs a few seconds to notice and
   reattach, and by then setup()'s four-second look for the cable is over -- so
   the board lands right back in the portal. Measured: out of the portal, reboot,
   straight back into the portal. Do it again and that is a loop.

   Taking the AP down in place keeps the cable connected throughout, which is the
   whole point of leaving. */
void stopPortaal() {
  if (!portaalActief) return;
  portaalWeb.stop();
  portaalDns.stop();
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_STA);
  portaalActief = false;
  setLed(false, false, false);
  fingerprint = "";                  // nothing on the glass is ours any more
  gfxFillScreen(COL_BG);
  drawAll();
  Serial.println("portaal gesloten");
}

void startPortaal() {
  if (portaalActief) return;
  portaalActief = true;
  Serial.println("portaal gestart");

  WiFi.disconnect(true);
  WiFi.mode(WIFI_AP_STA);           // AP_STA: needed in order to scan
  WiFi.softAP(PORTAAL_SSID, PORTAAL_PASS);
  delay(200);

  portaalDns.start(53, "*", WiFi.softAPIP());   // everything points at us -> the page opens by itself
  portaalWeb.on("/", HTTP_GET, []() {
    portaalWeb.send(200, "text/html; charset=utf-8", portaalPagina());
  });
  portaalWeb.on("/opslaan", HTTP_POST, portaalOpslaan);
  portaalWeb.onNotFound([]() {                  // captive-portal detection on phones
    portaalWeb.sendHeader("Location", String("http://") + WiFi.softAPIP().toString() + "/");
    portaalWeb.send(302, "text/plain", "");
  });
  portaalWeb.begin();

  setLed(true, false, false);
  portaalToon();
}

void portaalLus() {
  portaalDns.processNextRequest();
  portaalWeb.handleClient();
}

// ---- wifi ------------------------------------------------------------------
/* Turning power save off has to happen AFTER connecting. The ESP32 core sets
   the sleep mode again as soon as the link comes up, so a setSleep(false)
   before WiFi.begin() often does not stick. The symptom is a ping time that
   jumps between a few ms and the router's beacon interval (~100 ms), with
   connections dropping out entirely now and then.
   The RSSI is logged alongside because power save is only one explanation: at
   -75 dBm or lower it is simply range, and no setting helps. */
void wifiVerbonden() {
  WiFi.setSleep(false);
  /* Zendvermogen expliciet op het maximum. De core doet dat meestal al, maar
     niet altijd -- en op een marginale link (-75 dBm of lager) is elke dB het
     verschil tussen een TCP-handshake die lukt en een die de timeout uitloopt. */
  WiFi.setTxPower(WIFI_POWER_19_5dBm);
  Serial.printf("IP: %s  RSSI %d dBm\n",
                WiFi.localIP().toString().c_str(), WiFi.RSSI());
}

/* WiFi.reconnect() is unreliable once the AP has thrown the client out -- the
   status then hangs without a new association ever happening. So: an ordinary
   reconnect first, and if that yields nothing after 10 seconds, a full
   disconnect + begin. That does always force a new association, and is
   repeated every 10 seconds for as long as the link stays down. */
void bewaakWifi() {
  static uint32_t wegSinds = 0;

  /* Nothing to watch over. A board that has never been given a network used to
     sit in the portal forever, so this could not happen; now that the portal
     hands back to the cable, it can. Without this the loop reconnects to an
     empty SSID for ever, and each pass costs the 200 ms below -- which is enough
     to starve the serial reader and lose the very payload it is waiting for. */
  if (!cfgSsid.length()) return;

  if (WiFi.status() == WL_CONNECTED) {
    if (wegSinds) { wegSinds = 0; wifiVerbonden(); }   // just came back
    return;
  }

  if (!wegSinds) {
    wegSinds = millis();
    WiFi.reconnect();
  } else if (millis() - wegSinds > 10000) {
    wegSinds = millis();
    Serial.println("wifi weg, verbinding volledig opnieuw opzetten");
    WiFi.disconnect(true);
    delay(100);
    WiFi.mode(WIFI_STA);
    WiFi.begin(cfgSsid.c_str(), cfgPass.c_str());
  }
  delay(200);
}

/* ---- cracktro --------------------------------------------------------------
   CYD only, and deliberately so. The copper banding on the logo is done with
   setViewport as a clip, which Arduino_GFX has no equivalent for, and an easter
   egg is not what should shape the drawing interface. So this one reaches past
   gfx.h and talks to TFT_eSPI directly.
   ---------------------------------------------------------------------------- */
#if BOARD_KIND == BOARD_CYD
/* A nod to the intros of 1992. Back out: touch the screen or press any button.

   Starting it: the HUD's right-click menu, or GET /demo on the PC. The command
   rides along in the header line of /cyd.txt, so that route needs the display to
   have a connection.

   Holding GPIO0 for two seconds also works -- but only on boards where the
   on-board button really is BOOT. On several CYD revisions that single button
   next to the screen is wired to RST instead, and then pressing it simply
   reboots: you end up in the setup portal whenever Wi-Fi fails to come up
   within the 20 s window in setup(). If that is what your board does, use the
   menu or /demo.

   >>> YOUR OWN TEXT HERE <<<  Leave the trailing spaces, then it wraps around
   neatly instead of colliding with itself. */
const char* SCROLL_TEXT =
  "CLAUDE DECK ... MADE BY DIMMY OF OMEGAWARE ... GREETINGS TO MY LOVELY "
  "COLLEAGUE CHANTIE ... TO NATHAN THE AI MASTER ... RUBEN THE CHIEF ... "
  "ALL AIMELO MEMBERS! ... HAVE FUN WITH THIS TOOL, AND MAY THE CLAUDE BE "
  "WITH YOU!!        ";

/* Melody for the speaker on IO26. Note: the CYD has no speaker on board, only
   the pads -- without soldering one on, this stays silent.
   0 = rest. Pitches in Hz, duration in units of NOOT_MS. */
const uint16_t MELODIE[] = { 659,0,659,0,523,659,784,0,659,523,440,0,440,523,659,0 };
const int      N_NOOT    = sizeof(MELODIE) / sizeof(MELODIE[0]);
const uint16_t NOOT_MS   = 140;

struct Star { int16_t x, y; uint8_t laag; };

void cracktro() {
  // polling and reconnecting pause while this runs; it is a deliberate action
  Serial.println("cracktro: start");

  /* Which buttons are already down as we come in? The BOOT button certainly is
     if you got here by holding it, and an unwired GPIO35 may be too. Those do
     not count as an exit until they have been seen released once. */
  bool startDown[8];
  for (int i = 0; i < N_BTN; i++) startDown[i] = (digitalRead(BUTTONS[i].pin) == LOW);

  gTft.fillScreen(TFT_BLACK);
  gTft.setViewport(0, 0, 320, 240);

  const int N_STAR = 54;
  Star st[N_STAR];
  for (int i = 0; i < N_STAR; i++) {
    st[i].x = random(320);
    st[i].y = random(240);
    st[i].laag = i % 3;                 // 3 depths -> parallax
  }
  const uint8_t snelheid[3] = { 1, 2, 4 };
  const uint16_t sterKleur[3] = { 0x4208, 0x8410, 0xFFFF };   // far -> near

  // Copper palette: from dark through warm to white and back, which gives the
  // metallic sheen of a real copper bar.
  const int N_COP = 16;
  uint16_t cop[N_COP];
  for (int i = 0; i < N_COP; i++) {
    int t = (i < N_COP / 2) ? i : (N_COP - 1 - i);          // 0..7..0
    uint8_t r = 60 + t * 27;
    uint8_t g = 20 + t * 24;
    uint8_t b = 10 + t * 8;
    cop[i] = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
  }

  const int LOGO_Y = 44, LOGO_H = 32, COP_Y = 96, COP_H = 44;
  const int SCROLL_Y = 182, SCROLL_H = 56, GOLF = 14;

  TFT_eSprite scr = TFT_eSprite(&gTft);
  scr.setColorDepth(16);
  /* 46 tall, not 26: font 4 is 26 pixels by itself, and the swing of the wave
     comes on top of that. At 26 the letters were cut off at the bottom. */
  scr.createSprite(320, SCROLL_H);
  int scrollX = 320;
  uint32_t frame = 0, t0 = millis();
  int noot = -1;

  while (true) {
    // ---- time to leave? --------------------------------------------------
    /* Only leave on a button that goes down while we are here. Reading "is it
       low right now" was wrong: GPIO35 has no internal pull-up, so with no
       10k resistor fitted it floats and reads low at random -- which dropped
       straight back out of the cracktro on the first pass through this loop. */
    if (gfxTouched()) { Serial.println("cracktro: touch"); break; }
    bool weg = false;
    for (int i = 0; i < N_BTN; i++) {
      bool nu = (digitalRead(BUTTONS[i].pin) == LOW);
      if (nu && !startDown[i]) { Serial.printf("cracktro: button %s\n", BUTTONS[i].id); weg = true; }
      if (!nu) startDown[i] = false;      // released: from now on it counts
    }
    if (weg) break;

    // ---- stars -----------------------------------------------------------
    for (int i = 0; i < N_STAR; i++) {
      gTft.drawPixel(st[i].x, st[i].y, TFT_BLACK);        // erase the old one
      st[i].x -= snelheid[st[i].laag];
      if (st[i].x < 0) { st[i].x = 319; st[i].y = random(240); }
      // do not draw stars over the logo and the scroller
      bool bedekt = (st[i].y >= LOGO_Y && st[i].y < COP_Y + COP_H) ||
                    (st[i].y >= SCROLL_Y && st[i].y < SCROLL_Y + SCROLL_H);
      if (!bedekt) gTft.drawPixel(st[i].x, st[i].y, sterKleur[st[i].laag]);
    }

    // ---- copper bars -----------------------------------------------------
    for (int y = 0; y < COP_H; y++) {
      int idx = (int)((y + frame / 2)) % N_COP;
      gTft.drawFastHLine(0, COP_Y + y, 320, cop[idx]);
    }

    // ---- logo with copper banding ----------------------------------------
    /* The trick: draw the logo one horizontal band at a time, using setViewport
       as a clip, each band in a different copper colour. Eight drawString
       calls, instead of reading and rewriting 7200 pixels. */
    int bob = (int)(sin(frame * 0.06f) * 5.0f);
    gTft.fillRect(0, LOGO_Y - 6, 320, LOGO_H + 12, TFT_BLACK);
    const int BAND = 4;
    for (int b = 0; b < LOGO_H; b += BAND) {
      gTft.setViewport(0, LOGO_Y + bob + b, 320, BAND);
      gTft.setTextDatum(TC_DATUM);
      gTft.setTextFont(4);
      gTft.setTextColor(cop[((b / BAND) + frame / 3) % N_COP]);
      gTft.drawString("CLAUDE DECK", 160, -b);      // negative y = shift upwards
      gTft.setTextDatum(TL_DATUM);
    }
    gTft.resetViewport();

    // ---- waving scroller --------------------------------------------------
    scr.fillSprite(TFT_BLACK);
    scr.setTextFont(4);
    scr.setTextDatum(TL_DATUM);
    int x = scrollX;
    for (const char* p = SCROLL_TEXT; *p && x < 320; p++) {
      char c[2] = { *p, 0 };
      int w = scr.textWidth(c);
      if (x + w > 0) {
        /* The classic sine scroller: the wave stands STILL on screen and the
           letters ride through it. So the offset depends only on where a letter
           is on screen -- deliberately no time term. Add one and the wave
           travels along with the text, which is what made an earlier version
           look like a frozen wavy line instead of moving letters.

           cos() rather than sin(), measured from the right-hand edge: that puts
           a letter at the BOTTOM as it enters (cos 0 = 1, and a larger offset is
           lower on screen), after which it climbs to the top. K gives one and a
           half periods across the 320 pixels, so every letter visibly rises and
           falls on its way across. */
        const float K = 0.0295f;                  // 1.5 * 2*PI / 320
        int golf = (int)(cos((320 - x) * K) * (float)GOLF);
        scr.setTextColor(cop[(int)((x / 8) + frame / 2) % N_COP]);
        scr.drawString(c, x, (SCROLL_H / 2) - 13 + golf);
      }
      x += w;
    }
    scr.pushSprite(0, SCROLL_Y);
    scrollX -= 3;
    if (x < 0) scrollX = 320;                       // wrap around as soon as everything has passed

    // ---- chiptune ---------------------------------------------------------
    if (BEEP_ENABLED) {
      int n = ((millis() - t0) / NOOT_MS) % N_NOOT;
      if (n != noot) {
        noot = n;
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
        ledcAttach(PIN_SPK, 440, 10);
        ledcWriteTone(PIN_SPK, MELODIE[n]);
#else
        ledcSetup(LEDC_TONE, 440, 10);
        ledcAttachPin(PIN_SPK, LEDC_TONE);
        ledcWriteTone(LEDC_TONE, MELODIE[n]);
#endif
      }
    }

    frame++;
    delay(16);                                      // ~60 fps for as long as it keeps up
  }

  // ---- clean up ----------------------------------------------------------
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWriteTone(PIN_SPK, 0); ledcDetach(PIN_SPK);
#else
  ledcWriteTone(LEDC_TONE, 0); ledcDetachPin(PIN_SPK);
#endif
  Serial.println("cracktro: end");
  scr.deleteSprite();
  gTft.resetViewport();
  while (gfxTouched()) delay(20);       // finger off the glass before we carry on
  lastTouch = millis();
  gTft.fillScreen(COL_BG);
  fingerprint = "";                     // the next poll repaints everything
  drawAll();
}

#else
/* Other panels get a cracktro that does nothing, so the call sites need no
   guards of their own. */
void cracktro() { }
#endif  // BOARD_KIND == BOARD_CYD

// ---- setup / loop ----------------------------------------------------------
void setup() {
  /* Room for a whole payload. The default is 256 bytes and the PC pushes the
     entire session list in one go: past four or five sessions the tail of every
     block -- the ">>>" that ends it -- was dropped before this loop got round to
     reading, so the block never completed and the display sat there saying it
     had no connection while the cable was busy feeding it. Must come before
     begin(). */
  Serial.setRxBufferSize(2048);
  Serial.begin(115200);
  delay(200);
  /* Version first, because that is the one you compare against what is
     published; the compile date is only there to tell two local builds apart. */
  Serial.printf("BUILD %s  (%s %s)  panel %dx%d\n",
                FW_VERSION, __DATE__, __TIME__, gfxWidth(), gfxHeight());
  setBacklight(BACKLIGHT_PCT);

#if USE_RGB_LED
  pinMode(PIN_LED_R, OUTPUT); pinMode(PIN_LED_G, OUTPUT); pinMode(PIN_LED_B, OUTPUT);
  setLed(false, false, false);
#endif

  for (int i = 0; i < N_BTN; i++) {
    pinMode(BUTTONS[i].pin, BUTTONS[i].pullup ? INPUT_PULLUP : INPUT);
    btnWas[i] = false; btnAt[i] = 0;
  }

  gfxBegin();
  gfxFillScreen(COL_BG);
  gfxText(GF_BIG,   GA_TL, 12, 20, "Claude-sessies", COL_TXT, COL_BG);
  gfxText(GF_SMALL, GA_TL, 12, 60, "verbinden met wifi...", COL_MUTED, COL_BG);

  gfxTouchBegin();

  leesInstellingen();

  /* Is a PC pushing over the cable? Wait a moment to find out, because the
     answer changes everything below. Without this check a machine with no usable
     Wi-Fi -- an office network, or one whose password changed -- would spend
     twenty seconds failing to connect and then sit in the setup portal, while a
     cable capable of carrying the whole payload was plugged in the entire time.
     A little over one push interval is enough to be sure. */
  gfxText(GF_SMALL, GA_TL, 12, 82, "checking USB...", COL_MUTED, COL_BG);
  /* Same reason as the portal: nothing drawn in setup() reaches a buffered panel
     until loop() flushes, and between here and there sit four seconds of cable
     check and up to twenty of Wi-Fi. That is a long time to look switched off. */
  gfxFlushNow();
  uint32_t tSer = millis();
  while (millis() - tSer < 4000 && !serialFresh()) { serialPump(); delay(20); }

  if (serialFresh()) {
    Serial.println("transport: USB (PC is pushing)");
    /* Still bring Wi-Fi up, without waiting for it: having both means a tap
       keeps working the moment somebody unplugs the cable. */
    if (cfgSsid.length()) {
      WiFi.mode(WIFI_STA);
      WiFi.begin(cfgSsid.c_str(), cfgPass.c_str());
    }
  } else {
    /* Never configured, and no PC on the cable either? Then the portal is the
       only way to tell it anything. */
    if (!cfgSsid.length()) { portaalVanzelf = true; startPortaal(); return; }

    WiFi.mode(WIFI_STA);
    WiFi.begin(cfgSsid.c_str(), cfgPass.c_str());
    uint32_t t0 = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - t0 < 20000) {
      serialPump();                      // a PC may still show up while we wait
      if (serialFresh()) break;
      delay(250);
    }

    /* Neither Wi-Fi nor a cable. The password or the network changed, and the
       portal is the only way out that needs no PC. */
    if (WiFi.status() != WL_CONNECTED && !serialFresh()) {
      portaalVanzelf = true; startPortaal(); return;
    }
    if (WiFi.status() == WL_CONNECTED) wifiVerbonden();
  }

  gfxFillScreen(COL_BG);
  drawAll();
}

void loop() {
  /* While the portal is open this thing does nothing else: no polling, no
     reconnecting. Otherwise bewaakWifi() would pull the AP out from under it.

     Except read the cable. A board with no Wi-Fi settings that boots while the
     PC service happens to be quiet ends up here, and used to stay here: the
     portal was the one path that never looked at the serial port, so a cable
     that came alive a second later went unnoticed until somebody power-cycled
     it. Flashing produces exactly that situation every single time, because
     flashing is when the service lets the port go.

     Only when the portal came up on its own. If somebody held the top bar to
     get here they are changing a password, and having the screen vanish
     mid-word because a cable woke up is its own kind of broken. */
  if (portaalActief) {
    portaalLus();
    serialPump();
    if (!(portaalVanzelf && serialFresh())) { delay(5); return; }
    Serial.println("portaal: kabel leeft, portaal sluit");
    stopPortaal();
    // and on into the ordinary loop below, this same pass
  }

  serialPump();

  /* Skip the Wi-Fi watchdog while the cable is feeding us. It would otherwise
     keep forcing reconnects to a network that is not there, and each of those
     costs a delay this loop cannot afford. */
  if (!serialFresh()) bewaakWifi();

  handleTouch();
  handleButtons();

  if (millis() - lastPoll >= (online ? POLL_MS : POLL_MS_OFF)) {
    lastPoll = millis();
    bool ok = poll();
    if (ok) pollFails = 0; else pollFails++;
    if (!ok && millis() - lastOkMs > 15000 && online) {
      online = false; nRows = 0; nAtt = nAct = nDone = 0;
      fingerprint = ""; setLed(false, false, true); drawAll();
    } else if (ok && !online) {
      online = true; fingerprint = ""; drawAll();
    }
  }

  /* While offline, keep the retry line moving. Without it the screen just says
     "no connection" and looks dead, so you cannot tell whether it has given up
     or is still trying -- which is exactly what it does, every POLL_MS_OFF. */
  if (!online) {
    static uint32_t lastRetryDraw = 0;
    if (millis() - lastRetryDraw > 200) { lastRetryDraw = millis(); drawRetry(); }
  }

  // A command from the PC. Handled here rather than in poll(), so the parser
  // has finished before the cracktro takes over the screen.
  if (cmdCracktro) { cmdCracktro = false; cracktro(); }

  // let a lit button go out again
  if (btnFlashUntil && millis() > btnFlashUntil) {
    int i = btnFlash;
    btnFlashUntil = 0; btnFlash = HIT_NONE;
    if (i == HIT_UP || i == HIT_DOWN) drawArrows(false, false);
    else if (i >= 0)                  drawButton(i, false);
  }

  /* Repaint for the bars only when their number changes. RSSI moves every
     reading, and redrawing the header for each one would flicker on the CYD and
     cost a whole 300 KB frame on the S3 for a change nobody can see. The cable
     is folded into the same number, so swapping pipe repaints as well. */
  static int staafjesGetoond = -1;
  int staafjesNu = (serialFresh() ? 100 : 0) + wifiStaafjes();
  if (staafjesNu != staafjesGetoond) { staafjesGetoond = staafjesNu; drawHeader(); }

  // clear the header line when a message has expired
  static uint32_t lastHdr = 0;
  if (toastUntil && millis() > toastUntil && millis() - lastHdr > 200) {
    toastUntil = 0; lastHdr = millis(); drawHeader();
  }

  /* One frame per pass. On the CYD this is nothing at all -- every draw call
     already went straight to the glass. On the S3 this is where a frame becomes
     visible, and doing it once here rather than inside every drawing function
     keeps a full repaint to a single 300 KB push instead of six. */
  gfxFlushNow();

  delay(20);
}
