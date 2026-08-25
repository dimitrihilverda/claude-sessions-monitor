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
#include <FS.h>
#include <WebServer.h>
#include <DNSServer.h>

#include <TFT_eSPI.h>
#include <SPI.h>
#include <XPT2046_Touchscreen.h>

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
const bool     BEEP_ENABLED  = true;   // beep on a new attention request
#define USE_RGB_LED   1                // the status LED on the board itself
#define TOUCH_DEBUG   0                // 1 = raw touch values to Serial, for calibrating

// Touch calibration. If taps land somewhere other than where you press, set
// TOUCH_DEBUG to 1, tap the four corners and put the extremes here.
int TS_MINX = 200, TS_MAXX = 3700;
int TS_MINY = 240, TS_MAXY = 3800;
#define TOUCH_SWAP_XY  1
#define TOUCH_FLIP_X   0
#define TOUCH_FLIP_Y   1

// ---- hardware --------------------------------------------------------------
#define PIN_BL     21     // backlight
#define PIN_SPK    26     // audio output of the CYD
#define LEDC_BL     0
#define LEDC_TONE   1

// RGB LED on the CYD (active LOW)
#define PIN_LED_R   4
#define PIN_LED_G  16
#define PIN_LED_B  17

// Touch sits on a second SPI bus
#define TP_CLK  25
#define TP_MISO 39
#define TP_MOSI 32
#define TP_CS   33
#define TP_IRQ  36

/* The three buttons. GPIO 22 and 27 come out on the JST connectors and have an
   internal pull-up: switch between the pin and GND, done.
   GPIO 35 is input-only and has NO internal pull-up -- that one needs a 10k
   resistor between the pin and 3V3. The CYD's own BOOT button (GPIO 0) joins in
   as a fourth button; just do not hold it during power-up, or the ESP32 goes
   into flash mode. */
struct Btn { uint8_t pin; bool pullup; const char* id; };
Btn BUTTONS[] = {
  { 22, true,  "1" },
  { 27, true,  "2" },
  { 35, false, "3" },   // external 10k pull-up to 3V3
  {  0, true,  "4" }    // BOOT button
};
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

TFT_eSPI    tft = TFT_eSPI();
TFT_eSprite row = TFT_eSprite(&tft);
SPIClass    tpSPI(VSPI);
XPT2046_Touchscreen ts(TP_CS, TP_IRQ);

// ---- layout ----------------------------------------------------------------
#define HDR_H     28
#define ROW_Y     30
#define ROW_H     41
#define MAX_ROWS   4
#define BAR_Y    196
#define BAR_H     44

// ---- session state ---------------------------------------------------------
struct Sess { String state, name, since, why, id; };
Sess     rows[MAX_ROWS];
int      nRows = 0;
int      nAtt = 0, nAct = 0, nDone = 0;
int      selIdx = 0;
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
void drawHeader() {
  bool alarm = (nAtt > 0);
  uint16_t bg = alarm ? COL_ORANGE : COL_HDR;
  tft.fillRect(0, 0, 320, HDR_H, bg);
  tft.setTextFont(2);
  tft.setTextDatum(TL_DATUM);
  tft.setTextColor(alarm ? COL_BG : COL_TXT, bg);

  /* Offline the display has to say it itself; online the PC supplies the whole
     sentence already composed, because only there is it known whether it should
     read "1 needs you" or "2 need you" -- and in which language. */
  tft.drawString(online ? uiHeader : String(TXT_OFFLINE), 10, 5);

  tft.setTextDatum(TR_DATUM);
  String right = (millis() < toastUntil) ? toast : clockTxt;
  tft.drawString(right, 310, 5);
  tft.setTextDatum(TL_DATUM);
  tft.drawFastHLine(0, HDR_H, 320, COL_LINE);
}

void drawRow(int i) {
  int y = ROW_Y + i * ROW_H;
  row.createSprite(320, ROW_H - 3);
  row.fillSprite(COL_BG);

  if (i < nRows) {
    bool sel = (i == selIdx);
    uint16_t c = stateColor(rows[i].state);
    /* The stripe on the left says WHAT the session is doing, the lighter surface
       says which row is selected -- two separate signals, no extra outline. */
    row.fillRoundRect(6, 0, 308, ROW_H - 3, 6, sel ? COL_SEL : COL_ROW);
    row.fillRect(6, 0, 3, ROW_H - 3, c);

    // Short names large, longer titles a size smaller: since the beacon started
    // sending the real session title, those names are much longer than a folder name.
    String nm = rows[i].name;
    row.setTextColor(COL_TXT, sel ? COL_SEL : COL_ROW);
    if (nm.length() <= 16) {
      row.setTextFont(4);
      row.drawString(nm, 16, 2);
    } else {
      row.setTextFont(2);
      if (nm.length() > 34) nm = nm.substring(0, 33) + ".";
      row.drawString(nm, 16, 4);
    }

    /* State chip, just like Draw-Chip in hud.ps1: fill in the state colour at
       alpha 38 over the row, border at 150, text in the full colour. That is
       where the green (and the orange, on attention) really shows. */
    uint16_t rowBg = sel ? COL_SEL : COL_ROW;
    uint16_t chipBg = blend565(c, rowBg, 38);
    row.setTextFont(2);
    String lbl = stateLabel(rows[i].state);
    int cw = row.textWidth(lbl) + 14, ch = 17;
    int cx = 306 - cw, cy = 3;
    row.fillRoundRect(cx, cy, cw, ch, 4, chipBg);
    row.drawRoundRect(cx, cy, cw, ch, 4, blend565(c, rowBg, 150));
    row.setTextColor(c, chipBg);
    row.setTextDatum(MC_DATUM);
    row.drawString(lbl, cx + cw / 2, cy + ch / 2);
    row.setTextDatum(TL_DATUM);

    row.setTextColor(COL_MUTED, sel ? COL_SEL : COL_ROW);
    String w = rows[i].since + "  " + rows[i].why;
    if (w.length() > 52) w = w.substring(0, 51) + ".";
    row.drawString(w, 16, 23);
  } else if (i == 0) {
    row.setTextFont(2);
    row.setTextColor(COL_MUTED, COL_BG);
    if (online) {
      row.drawString(uiEmpty, 16, 10);
    } else {
      /* Name the address it is trying. A typo in the PC address is otherwise
         impossible to find: Wi-Fi works, so the portal never appears by itself,
         and the screen only said "waiting for the PC" without saying for what. */
      row.setTextColor(COL_ORANGE, COL_BG);
      row.drawString(String(TXT_NOANSWER) + cfgHost + ":" + cfgPort, 16, 3);
      row.setTextColor(COL_MUTED, COL_BG);
      row.drawString(TXT_CHECKAPI, 16, 21);
    }
  } else if (i == 1 && !online && !nRows) {
    row.setTextFont(2);
    row.setTextColor(COL_MUTED, COL_BG);
    row.drawString(TXT_HOLDSETUP, 16, 10);
  }

  row.pushSprite(0, y);
  row.deleteSprite();
}

/* One source for the position of button i, so the drawn surface and the hit
   area cannot drift apart. They did: drawing used 6 + i*104 (width 100) while
   a tap was rounded with x / 107. As long as there was no visible feedback
   nobody noticed; with a button that lights up you see immediately that you
   pressed next to it. */
void btnRect(int i, int& x, int& w) {
  w = 100;
  x = 6 + i * (w + 4);
}

int btnHit(int x) {
  for (int i = 0; i < 3; i++) {
    int bx, bw;
    btnRect(i, bx, bw);
    if (x >= bx && x < bx + bw) return i;
  }
  return -1;
}

void drawButton(int i, bool pressed) {
  int x, w;
  btnRect(i, x, w);
  uint16_t vlak = pressed ? COL_GREEN : COL_ROW;
  uint16_t ink  = pressed ? COL_BG    : COL_TXT;
  tft.fillRoundRect(x, BAR_Y, w, BAR_H - 6, 6, vlak);
  // The row surface sits close to the background, so without a border you would
  // not see that these are buttons.
  tft.drawRoundRect(x, BAR_Y, w, BAR_H - 6, 6, pressed ? COL_GREEN : COL_LINE);
  tft.setTextFont(2);
  tft.setTextDatum(MC_DATUM);
  tft.setTextColor(ink, vlak);
  String l = btnLabel[i];
  if (l.length() > 13) l = l.substring(0, 12) + ".";
  tft.drawString(l, x + w / 2, BAR_Y + (BAR_H - 6) / 2);
  tft.setTextDatum(TL_DATUM);
}

// Light up button i. loop() does the redraw, so no delay() is needed in touch
// or button handling and polling simply carries on.
void flashButton(int i) {
  if (i < 0 || i > 2) return;
  btnFlash = i;
  btnFlashUntil = millis() + 180;
  drawButton(i, true);
}

void drawButtonBar() {
  tft.fillRect(0, BAR_Y - 4, 320, 244 - BAR_Y, COL_BG);
  tft.drawFastHLine(0, BAR_Y - 4, 320, COL_LINE);
  for (int i = 0; i < 3; i++) drawButton(i, i == btnFlash);
}

/* Het levende deel van het offline-scherm. Alleen dit strookje wordt hertekend,
   vijf keer per seconde: een balkje dat vollooopt naar de volgende poging, het
   pogingnummer en hoe lang er al geen contact is. Zo zie je dat hij bezig is in
   plaats van een stilstaande foutmelding. */
void drawRetry() {
  /* Op de plek van de derde rij: rij 1 draagt de "houd de bovenbalk vast"-hint,
     en die zou anders vijf keer per seconde worden weggeveegd. */
  const int Y = ROW_Y + 2 * ROW_H + 2;
  uint32_t interval = POLL_MS_OFF;
  uint32_t sinds    = millis() - lastPoll;
  if (sinds > interval) sinds = interval;

  // voortgangsbalkje naar de volgende poging
  int vol = (int)((uint32_t)308 * sinds / interval);
  row.createSprite(320, 22);
  row.fillSprite(COL_BG);
  row.fillRect(6, 0, 308, 3, COL_ROW);
  row.fillRect(6, 0, vol, 3, COL_ORANGE);

  row.setTextFont(2);
  row.setTextDatum(TL_DATUM);
  row.setTextColor(COL_MUTED, COL_BG);
  /* De RSSI staat erbij omdat dit meestal geen storing in de software is maar
     bereik. Zie je hier -75 dBm of lager, dan is het schermpje te ver van je
     accesspoint en helpt geen enkele instelling. */
  uint32_t weg = (millis() - lastOkMs) / 1000;
  String s = String(TXT_RETRY) + pollFails + "  -  " + weg + TXT_AGO;
  if (WiFi.status() == WL_CONNECTED) s += "  -  " + String(WiFi.RSSI()) + " dBm";
  else                               s += "  -  no wifi";
  row.drawString(s, 16, 7);
  row.pushSprite(0, Y);
  row.deleteSprite();
}

void drawAll() {
  drawHeader();
  for (int i = 0; i < MAX_ROWS; i++) drawRow(i);
  drawButtonBar();
}

void flashAttention() {
  for (int k = 0; k < 3; k++) {
    tft.fillRect(0, 0, 320, HDR_H, COL_ORANGE); delay(120);
    tft.fillRect(0, 0, 320, HDR_H, COL_BG);     delay(120);
  }
  drawHeader();
}

// ---- talking to the PC -----------------------------------------------------
String httpGet(const String& path) {
  if (WiFi.status() != WL_CONNECTED) {
    static uint32_t lastWifiLog = 0;
    if (millis() - lastWifiLog > 2000) { lastWifiLog = millis(); Serial.println("poll: wifi not connected"); }
    return "";
  }
  HTTPClient http;
  String url = String("http://") + cfgHost + ":" + cfgPort + path;
  /* 4 s, not 2.5. The API builds the session list through WMI process queries,
     which costs about 1.5 s on a cold cache and more when WMI is slow. At 2.5 s
     the poll regularly fell over that and the display said "no answer" while
     nothing was wrong. Do not go higher: a failed poll blocks this loop, and
     the touchscreen does not respond for that long. */
  /* 4 s zolang het goed gaat: de API kan er bij een koude cache 1,5 s over doen
     en die poll wil je niet weggooien. Maar zodra we offline zijn is een lange
     timeout juist schadelijk -- elke mislukte poging kost dan 4 seconden, en met
     een haperende wifi sta je zo een minuut in het donker. Offline dus kort
     wachten en snel opnieuw proberen. */
  /* Offline korter wachten dan online, maar niet te kort. 1500 ms was een val:
     als de API er 1,3 s over doet, valt de poll er net over, blijft hij offline
     en houdt daarmee de korte timeout -- dat houdt zichzelf in stand. 3000 ms
     zit ruim boven de traagste gemeten respons en halveert nog steeds de tijd
     die een mislukte poging kost. */
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

void sendFocus(int idx) {
  if (idx < 0 || idx >= nRows) return;
  String r = httpGet("/focus?id=" + rows[idx].id + tokenArg());
  say(r.length() ? r.substring(0, 22) : String(TXT_NOREPLY));
  drawHeader();
}

void sendAction(const char* btn) {
  if (nRows == 0) { say(TXT_NOSESS); drawHeader(); return; }
  int idx = (selIdx >= 0 && selIdx < nRows) ? selIdx : 0;
  String r = httpGet("/action?id=" + rows[idx].id + "&b=" + btn + tokenArg());
  say(r.length() ? r.substring(0, 22) : String(TXT_NOREPLY));
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
  String body = httpGet("/cyd.txt");
  if (!body.length()) return false;

  int    n = 0, att = 0, act = 0, done = 0;
  String clk = clockTxt, newAtt = "";
  String labels[3] = { btnLabel[0], btnLabel[1], btnLabel[2] };
  Sess   tmp[MAX_ROWS];

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

    if (n >= MAX_ROWS) continue;
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
  fp += "@" + labels[0] + labels[1] + labels[2] + "#" + String(selIdx);

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

  setLed(att > 0, att > 0 || act > 0, false);   // orange = red+green, green = working

  if (fp != fingerprint) { fingerprint = fp; drawAll(); }
  else { drawHeader(); }

  if (freshAttention) { beep(); flashAttention(); }
  return true;
}

// ---- touch -----------------------------------------------------------------
bool readTouch(int& sx, int& sy) {
  if (!ts.tirqTouched() || !ts.touched()) return false;
  TS_Point p = ts.getPoint();

  int a = p.x, b = p.y;
#if TOUCH_SWAP_XY
  int t = a; a = b; b = t;
#endif
  sx = map(a, TS_MINX, TS_MAXX, 0, 320);
  sy = map(b, TS_MINY, TS_MAXY, 0, 240);
#if TOUCH_FLIP_X
  sx = 320 - sx;
#endif
#if TOUCH_FLIP_Y
  sy = 240 - sy;
#endif
  sx = constrain(sx, 0, 319);
  sy = constrain(sy, 0, 239);

#if TOUCH_DEBUG
  Serial.printf("raw x=%d y=%d z=%d  ->  x=%d y=%d\n", p.x, p.y, p.z, sx, sy);
  tft.fillCircle(sx, sy, 3, COL_ORANGE);
#endif
  return true;
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
    while (ts.touched() && millis() - neer < 2200) delay(50);
    if (millis() - neer >= 2000) {
      say(TXT_SETUP);
      drawHeader();
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
    int i = (y - ROW_Y) / ROW_H;
    if (i < nRows) {
      selIdx = i;
      drawAll();
      sendFocus(i);
    }
    return;
  }
  if (y >= BAR_Y) {                             // tapped on a button
    int i = btnHit(x);
    if (i < 0) return;                          // in the gap between two buttons
    flashButton(i);
    char b[2] = { (char)('1' + i), 0 };
    sendAction(b);
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
      flashButton(i);          // buttons 1-3 have an on-screen surface; the BOOT button does not
      sendAction(BUTTONS[i].id);
    }
    btnWas[i] = down;
  }
}

// ---- settings in NVS -------------------------------------------------------
/* Wi-Fi and the PC address live in NVS (the flash area a new sketch does not
   erase), not in the code. That keeps passwords out of git and lets you move
   the thing to another network without USB -- which helps, because that cable
   is the unreliable part here. */
void leesInstellingen() {
  nvs.begin("claudedeck", true);          // true = read only
  cfgSsid = nvs.getString("ssid", WIFI_SSID_START);
  cfgPass = nvs.getString("pass", WIFI_PASS_START);
  cfgHost = nvs.getString("host", API_HOST_START);
  cfgPort = nvs.getUShort("port", API_PORT_START);
  nvs.end();
  if (cfgPort == 0) cfgPort = 8787;
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
  tft.fillScreen(COL_BG);
  tft.setTextDatum(TL_DATUM);
  tft.setTextFont(4);
  tft.setTextColor(COL_ORANGE, COL_BG);
  tft.drawString("Instellen", 14, 12);

  tft.setTextFont(2);
  tft.setTextColor(COL_MUTED, COL_BG);
  tft.drawString("Verbind je telefoon met dit wifi-netwerk:", 14, 52);
  tft.setTextColor(COL_TXT, COL_BG);
  tft.setTextFont(4);
  tft.drawString(PORTAAL_SSID, 14, 72);
  tft.setTextFont(2);
  tft.setTextColor(COL_MUTED, COL_BG);
  tft.drawString(String("wachtwoord: ") + PORTAAL_PASS, 14, 104);

  tft.setTextColor(COL_TXT, COL_BG);
  tft.drawString("Springt er geen pagina open, ga dan naar:", 14, 136);
  tft.setTextFont(4);
  tft.setTextColor(COL_GREEN, COL_BG);
  tft.drawString(WiFi.softAPIP().toString(), 14, 156);

  tft.setTextFont(2);
  tft.setTextColor(COL_MUTED, COL_BG);
  tft.drawString("Na opslaan herstart hij zelf.", 14, 200);
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

  bewaarInstellingen(ssid, pass, host, port);
  portaalWeb.send(200, "text/html; charset=utf-8",
                  "<meta charset=utf-8><body style='background:#2A3238;color:#EEF3F5;"
                  "font:16px system-ui;padding:24px'>Opgeslagen. Het schermpje "
                  "herstart nu en verbindt met <b>" + htmlVeilig(ssid) +
                  "</b>.</body>");
  delay(800);                       // give the page a moment to be sent
  ESP.restart();
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

// ---- cracktro --------------------------------------------------------------
/* A nod to the intros of 1992. Open it: hold the BOOT button for two seconds.
   Back: touch the screen or press any button.

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

  tft.fillScreen(TFT_BLACK);
  tft.setViewport(0, 0, 320, 240);

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
  const int SCR_Y = 182, SCR_H = 56, GOLF = 14;

  TFT_eSprite scr = TFT_eSprite(&tft);
  scr.setColorDepth(16);
  /* 46 tall, not 26: font 4 is 26 pixels by itself, and the swing of the wave
     comes on top of that. At 26 the letters were cut off at the bottom. */
  scr.createSprite(320, SCR_H);
  int scrollX = 320;
  uint32_t frame = 0, t0 = millis();
  int noot = -1;

  while (true) {
    // ---- time to leave? --------------------------------------------------
    /* Only leave on a button that goes down while we are here. Reading "is it
       low right now" was wrong: GPIO35 has no internal pull-up, so with no
       10k resistor fitted it floats and reads low at random -- which dropped
       straight back out of the cracktro on the first pass through this loop. */
    if (ts.touched()) { Serial.println("cracktro: touch"); break; }
    bool weg = false;
    for (int i = 0; i < N_BTN; i++) {
      bool nu = (digitalRead(BUTTONS[i].pin) == LOW);
      if (nu && !startDown[i]) { Serial.printf("cracktro: button %s\n", BUTTONS[i].id); weg = true; }
      if (!nu) startDown[i] = false;      // released: from now on it counts
    }
    if (weg) break;

    // ---- stars -----------------------------------------------------------
    for (int i = 0; i < N_STAR; i++) {
      tft.drawPixel(st[i].x, st[i].y, TFT_BLACK);        // erase the old one
      st[i].x -= snelheid[st[i].laag];
      if (st[i].x < 0) { st[i].x = 319; st[i].y = random(240); }
      // do not draw stars over the logo and the scroller
      bool bedekt = (st[i].y >= LOGO_Y && st[i].y < COP_Y + COP_H) ||
                    (st[i].y >= SCR_Y && st[i].y < SCR_Y + SCR_H);
      if (!bedekt) tft.drawPixel(st[i].x, st[i].y, sterKleur[st[i].laag]);
    }

    // ---- copper bars -----------------------------------------------------
    for (int y = 0; y < COP_H; y++) {
      int idx = (int)((y + frame / 2)) % N_COP;
      tft.drawFastHLine(0, COP_Y + y, 320, cop[idx]);
    }

    // ---- logo with copper banding ----------------------------------------
    /* The trick: draw the logo one horizontal band at a time, using setViewport
       as a clip, each band in a different copper colour. Eight drawString
       calls, instead of reading and rewriting 7200 pixels. */
    int bob = (int)(sin(frame * 0.06f) * 5.0f);
    tft.fillRect(0, LOGO_Y - 6, 320, LOGO_H + 12, TFT_BLACK);
    const int BAND = 4;
    for (int b = 0; b < LOGO_H; b += BAND) {
      tft.setViewport(0, LOGO_Y + bob + b, 320, BAND);
      tft.setTextDatum(TC_DATUM);
      tft.setTextFont(4);
      tft.setTextColor(cop[((b / BAND) + frame / 3) % N_COP]);
      tft.drawString("CLAUDE DECK", 160, -b);      // negative y = shift upwards
      tft.setTextDatum(TL_DATUM);
    }
    tft.resetViewport();

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
        scr.drawString(c, x, (SCR_H / 2) - 13 + golf);
      }
      x += w;
    }
    scr.pushSprite(0, SCR_Y);
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
  tft.resetViewport();
  while (ts.touched()) delay(20);       // finger off the glass before we carry on
  lastTouch = millis();
  tft.fillScreen(COL_BG);
  fingerprint = "";                     // the next poll repaints everything
  drawAll();
}

// ---- setup / loop ----------------------------------------------------------
void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.printf("BUILD %s %s  COL_BG=0x%04X COL_ROW=0x%04X COL_SEL=0x%04X\n",
                __DATE__, __TIME__, COL_BG, COL_ROW, COL_SEL);
  setBacklight(BACKLIGHT_PCT);

#if USE_RGB_LED
  pinMode(PIN_LED_R, OUTPUT); pinMode(PIN_LED_G, OUTPUT); pinMode(PIN_LED_B, OUTPUT);
  setLed(false, false, false);
#endif

  for (int i = 0; i < N_BTN; i++) {
    pinMode(BUTTONS[i].pin, BUTTONS[i].pullup ? INPUT_PULLUP : INPUT);
    btnWas[i] = false; btnAt[i] = 0;
  }

  tft.init();
  tft.setRotation(1);            // landscape, USB on the left

  tft.fillScreen(COL_BG);
  tft.setTextFont(4);
  tft.setTextColor(COL_TXT, COL_BG);
  tft.drawString("Claude-sessies", 12, 20);
  tft.setTextFont(2);
  tft.setTextColor(COL_MUTED, COL_BG);
  tft.drawString("verbinden met wifi...", 12, 60);

  tpSPI.begin(TP_CLK, TP_MISO, TP_MOSI, TP_CS);
  ts.begin(tpSPI);
  ts.setRotation(0);   // raw orientation: we do the rotating ourselves with TOUCH_SWAP/FLIP

  leesInstellingen();

  /* Never configured? Then straight to the portal, without first waiting twenty
     seconds on an empty SSID. */
  if (!cfgSsid.length()) { startPortaal(); return; }

  WiFi.mode(WIFI_STA);
  WiFi.begin(cfgSsid.c_str(), cfgPass.c_str());
  uint32_t t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < 20000) delay(250);

  /* If it fails, the password or the network changed. The portal is then the
     only way out that needs no USB. */
  if (WiFi.status() != WL_CONNECTED) { startPortaal(); return; }
  wifiVerbonden();

  tft.fillScreen(COL_BG);
  drawAll();
}

void loop() {
  /* While the portal is open this thing does nothing else: no polling, no
     reconnecting. Otherwise bewaakWifi() would pull the AP out from under it. */
  if (portaalActief) { portaalLus(); delay(5); return; }

  bewaakWifi();

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
    btnFlashUntil = 0; btnFlash = -1;
    if (i >= 0) drawButton(i, false);
  }

  // clear the header line when a message has expired
  static uint32_t lastHdr = 0;
  if (toastUntil && millis() > toastUntil && millis() - lastHdr > 200) {
    toastUntil = 0; lastHdr = millis(); drawHeader();
  }

  delay(20);
}
