/* ===========================================================================
   claude_hud_cyd.ino -- Claude-sessies op de Cheap Yellow Display
   Board: ESP32-2432S028R (2,8" ILI9341, 320x240, XPT2046-touch)

   Wat het doet:
     - toont je live Claude-sessies (oranje = wacht op jou, groen = actief,
       grijs = klaar) met bovenaan de tellers en de klok
     - TIKKEN op een rij  -> die sessie wordt geselecteerd en het bijbehorende
       venster op je pc springt naar voren (net als klikken in de HUD)
     - DRIE KNOPPEN onderaan -> voeren de actie uit die in actions.json op je
       pc staat (goedkeuren, weigeren, snoozen, ...). De labels onder in beeld
       komen ook uit dat bestand, dus omzetten hoeft niet opnieuw geflasht
     - de RGB-led op de CYD kleurt mee, ook als je het scherm niet aankijkt

   Vereist: TFT_eSPI (Bodmer) met User_Setup_CYD.h, en XPT2046_Touchscreen
   (Paul Stoffregen). Geen ArduinoJson: de pc levert platte tekst op /cyd.txt.
   =========================================================================== */

#include <WiFi.h>
#include <HTTPClient.h>
#include <TFT_eSPI.h>
#include <SPI.h>
#include <XPT2046_Touchscreen.h>

// ---- INSTELLEN -------------------------------------------------------------
const char* WIFI_SSID = "ZET-HIER-JE-WIFI";
const char* WIFI_PASS = "ZET-HIER-JE-WACHTWOORD";

// IP van je pc (waar session-api.ps1 draait). Zet een DHCP-reservering in je
// router, anders klopt dit adres na een herstart niet meer.
const char* API_HOST  = "192.168.1.10";
const int   API_PORT  = 8787;
const char* API_TOKEN = "";            // alleen invullen als je in actions.json een token zet

const uint32_t POLL_MS       = 3000;   // hoe vaak vragen we de pc om de stand
const uint8_t  BACKLIGHT_PCT = 70;     // helderheid 0-100
const bool     BEEP_ENABLED  = true;   // piepje bij nieuwe aandachtsvraag
#define USE_RGB_LED   1                // statuslampje op de CYD zelf
#define TOUCH_DEBUG   0                // 1 = raw touchwaarden naar Serial, voor het kalibreren

// Touch-kalibratie. Klopt de tik niet met waar je drukt, zet TOUCH_DEBUG op 1,
// tik de vier hoeken aan en vul de uitersten hier in.
int TS_MINX = 200, TS_MAXX = 3700;
int TS_MINY = 240, TS_MAXY = 3800;
#define TOUCH_SWAP_XY  1
#define TOUCH_FLIP_X   0
#define TOUCH_FLIP_Y   1

// ---- hardware --------------------------------------------------------------
#define PIN_BL     21     // backlight
#define PIN_SPK    26     // audio-uitgang van de CYD
#define LEDC_BL     0
#define LEDC_TONE   1

// RGB-led op de CYD (actief LAAG)
#define PIN_LED_R   4
#define PIN_LED_G  16
#define PIN_LED_B  17

// Touch zit op een tweede SPI-bus
#define TP_CLK  25
#define TP_MISO 39
#define TP_MOSI 32
#define TP_CS   33
#define TP_IRQ  36

/* De drie knoppen. GPIO 22 en 27 komen op de JST-connectoren naar buiten en
   hebben een interne pull-up: knop tussen de pin en GND, klaar.
   GPIO 35 is input-only en heeft GEEN interne pull-up -- daar hoort een
   weerstand van 10k tussen de pin en 3V3. De BOOT-knop van de CYD (GPIO 0)
   doet als vierde knop gewoon mee; alleen niet ingedrukt houden tijdens het
   opstarten, dan gaat de ESP32 in flashmodus. */
struct Btn { uint8_t pin; bool pullup; const char* id; };
Btn BUTTONS[] = {
  { 22, true,  "1" },
  { 27, true,  "2" },
  { 35, false, "3" },   // externe 10k pull-up naar 3V3
  {  0, true,  "4" }    // BOOT-knop
};
const int N_BTN = sizeof(BUTTONS) / sizeof(BUTTONS[0]);
bool     btnWas[8];
uint32_t btnAt[8];

// ---- kleuren (Moving-In) ---------------------------------------------------
#define COL_BG      0x18E3   // navy   #1F262F
#define COL_ROW     0x2166   // rijvlak
#define COL_SEL     0x3A6E   // geselecteerde rij
#define COL_TXT     0xF79E   // wit
#define COL_MUTED   0x8410   // grijsblauw
#define COL_GREEN   0x8E47   // leaf   #8DC63F
#define COL_ORANGE  0xED05   // oranje #E8A33D
#define COL_STEEL   0x9DB9   // staalblauw

TFT_eSPI    tft = TFT_eSPI();
TFT_eSprite row = TFT_eSprite(&tft);
SPIClass    tpSPI(VSPI);
XPT2046_Touchscreen ts(TP_CS, TP_IRQ);

// ---- indeling --------------------------------------------------------------
#define HDR_H     28
#define ROW_Y     30
#define ROW_H     41
#define MAX_ROWS   4
#define BAR_Y    196
#define BAR_H     44

// ---- sessiestand -----------------------------------------------------------
struct Sess { String state, name, since, why, id; };
Sess     rows[MAX_ROWS];
int      nRows = 0;
int      nAtt = 0, nAct = 0, nDone = 0;
int      selIdx = 0;
String   clockTxt = "--:--:--";
String   btnLabel[3] = { "Knop 1", "Knop 2", "Knop 3" };
String   fingerprint = "";
String   attKey = "";
String   toast = "";
uint32_t toastUntil = 0;
bool     online = false;
uint32_t lastPoll = 0, lastOkMs = 0, lastTouch = 0;

// ===========================================================================
/* De LEDC-API is in ESP32-core 3.x veranderd (pin in plaats van kanaal).
   Deze wrappers houden de sketch werkend op 2.x en 3.x. */
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
  digitalWrite(PIN_LED_R, r ? LOW : HIGH);   // actief laag
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
  if (s == "attention") return "WACHT OP JOU";
  if (s == "active")    return "ACTIEF";
  return "KLAAR";
}

void say(const String& msg) {          // kort berichtje in de kopregel
  toast = msg;
  toastUntil = millis() + 2500;
}

// ---- tekenen ---------------------------------------------------------------
void drawHeader() {
  bool alarm = (nAtt > 0);
  uint16_t bg = alarm ? COL_ORANGE : COL_BG;
  tft.fillRect(0, 0, 320, HDR_H, bg);
  tft.setTextFont(2);
  tft.setTextDatum(TL_DATUM);
  tft.setTextColor(alarm ? COL_BG : COL_TXT, bg);

  char left[48];
  if (!online)       snprintf(left, sizeof(left), "GEEN VERBINDING");
  else if (alarm)    snprintf(left, sizeof(left), "%d WACHT%s OP JOU", nAtt, nAtt == 1 ? "" : "EN");
  else if (nAct > 0) snprintf(left, sizeof(left), "%d ACTIEF", nAct);
  else               snprintf(left, sizeof(left), "CLAUDE RUSTIG");
  tft.drawString(left, 10, 5);

  tft.setTextDatum(TR_DATUM);
  String right = (millis() < toastUntil) ? toast : clockTxt;
  tft.drawString(right, 310, 5);
  tft.setTextDatum(TL_DATUM);
  tft.drawFastHLine(0, HDR_H, 320, COL_ROW);
}

void drawRow(int i) {
  int y = ROW_Y + i * ROW_H;
  row.createSprite(320, ROW_H - 3);
  row.fillSprite(COL_BG);

  if (i < nRows) {
    bool sel = (i == selIdx);
    uint16_t c = stateColor(rows[i].state);
    row.fillRoundRect(6, 0, 308, ROW_H - 3, 6, sel ? COL_SEL : COL_ROW);
    row.fillRect(6, 0, sel ? 5 : 3, ROW_H - 3, c);
    if (sel) row.drawRoundRect(6, 0, 308, ROW_H - 3, 6, c);

    // Korte naam groot, langere titel een maatje kleiner: sinds de beacon de
    // echte sessietitel meestuurt zijn die namen een stuk langer dan een mapnaam.
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

    row.setTextFont(2);
    row.setTextColor(c, sel ? COL_SEL : COL_ROW);
    row.setTextDatum(TR_DATUM);
    row.drawString(stateLabel(rows[i].state), 306, 3);
    row.setTextDatum(TL_DATUM);

    row.setTextColor(COL_MUTED, sel ? COL_SEL : COL_ROW);
    String w = rows[i].since + "  " + rows[i].why;
    if (w.length() > 52) w = w.substring(0, 51) + ".";
    row.drawString(w, 16, 23);
  } else if (i == 0) {
    row.setTextFont(2);
    row.setTextColor(COL_MUTED, COL_BG);
    row.drawString(online ? "Geen actieve sessies." : "Wacht op de pc...", 16, 10);
  }

  row.pushSprite(0, y);
  row.deleteSprite();
}

void drawButtonBar() {
  tft.fillRect(0, BAR_Y - 4, 320, 244 - BAR_Y, COL_BG);
  tft.drawFastHLine(0, BAR_Y - 4, 320, COL_ROW);
  int w = 100;
  for (int i = 0; i < 3; i++) {
    int x = 6 + i * (w + 4);
    tft.fillRoundRect(x, BAR_Y, w, BAR_H - 6, 6, COL_ROW);
    tft.setTextFont(2);
    tft.setTextDatum(MC_DATUM);
    tft.setTextColor(COL_TXT, COL_ROW);
    String l = btnLabel[i];
    if (l.length() > 13) l = l.substring(0, 12) + ".";
    tft.drawString(l, x + w / 2, BAR_Y + (BAR_H - 6) / 2);
    tft.setTextDatum(TL_DATUM);
  }
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

// ---- praten met de pc ------------------------------------------------------
String httpGet(const String& path) {
  if (WiFi.status() != WL_CONNECTED) return "";
  HTTPClient http;
  String url = String("http://") + API_HOST + ":" + API_PORT + path;
  http.setConnectTimeout(2500);
  http.setTimeout(2500);
  if (!http.begin(url)) return "";
  int code = http.GET();
  String body = (code == 200) ? http.getString() : String("");
  http.end();
  return body;
}

String tokenArg() {
  return (strlen(API_TOKEN) > 0) ? String("&t=") + API_TOKEN : String("");
}

void sendFocus(int idx) {
  if (idx < 0 || idx >= nRows) return;
  String r = httpGet("/focus?id=" + rows[idx].id + tokenArg());
  say(r.length() ? r.substring(0, 22) : "pc reageert niet");
  drawHeader();
}

void sendAction(const char* btn) {
  if (nRows == 0) { say("geen sessies"); drawHeader(); return; }
  int idx = (selIdx >= 0 && selIdx < nRows) ? selIdx : 0;
  String r = httpGet("/action?id=" + rows[idx].id + "&b=" + btn + tokenArg());
  say(r.length() ? r.substring(0, 22) : "pc reageert niet");
  drawHeader();
}

// ---- data ophalen ----------------------------------------------------------
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
      String f[5];
      splitFields(line, 1, f, 5);
      att = f[0].toInt(); act = f[1].toInt(); done = f[2].toInt();
      if (f[3].length()) clk = f[3];
      if (f[4].length()) {           // knoplabels, gescheiden door ;
        int p = 0;
        for (int i = 0; i < 3; i++) {
          int sc = f[4].indexOf(';', p);
          labels[i] = (sc < 0) ? f[4].substring(p) : f[4].substring(p, sc);
          if (sc < 0) break;
          p = sc + 1;
        }
      }
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

  // Selectie zo veel mogelijk op dezelfde sessie houden
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
  // nieuwe aandachtsvraag? die wil je selecteren, daar druk je zo op
  if (freshAttention) {
    for (int i = 0; i < n; i++) if (rows[i].state == "attention") { selIdx = i; break; }
  }

  setLed(att > 0, att > 0 || act > 0, false);   // oranje = rood+groen, groen = actief

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
  if (millis() - lastTouch < 350) return;      // ontdender
  lastTouch = millis();

  if (y >= ROW_Y && y < ROW_Y + MAX_ROWS * ROW_H) {
    int i = (y - ROW_Y) / ROW_H;
    if (i < nRows) {
      selIdx = i;
      drawAll();
      sendFocus(i);
    }
    return;
  }
  if (y >= BAR_Y) {                             // op een knopvlak getikt
    int i = x / 107;
    if (i > 2) i = 2;
    char b[2] = { (char)('1' + i), 0 };
    sendAction(b);
  }
}

// ---- knoppen ---------------------------------------------------------------
void handleButtons() {
  for (int i = 0; i < N_BTN; i++) {
    bool down = (digitalRead(BUTTONS[i].pin) == LOW);
    if (down && !btnWas[i] && millis() - btnAt[i] > 250) {
      btnAt[i] = millis();
      sendAction(BUTTONS[i].id);
    }
    btnWas[i] = down;
  }
}

// ---- setup / loop ----------------------------------------------------------
void setup() {
  Serial.begin(115200);
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
  tft.setRotation(1);            // landschap, USB links
  tft.fillScreen(COL_BG);
  tft.setTextFont(4);
  tft.setTextColor(COL_TXT, COL_BG);
  tft.drawString("Claude-sessies", 12, 20);
  tft.setTextFont(2);
  tft.setTextColor(COL_MUTED, COL_BG);
  tft.drawString("verbinden met wifi...", 12, 60);

  tpSPI.begin(TP_CLK, TP_MISO, TP_MOSI, TP_CS);
  ts.begin(tpSPI);
  ts.setRotation(0);   // ruwe stand: het draaien doen we zelf met TOUCH_SWAP/FLIP

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  uint32_t t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < 20000) delay(250);

  tft.fillScreen(COL_BG);
  if (WiFi.status() == WL_CONNECTED) { Serial.print("IP: "); Serial.println(WiFi.localIP()); }
  drawAll();
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) {
    WiFi.reconnect();
    delay(1000);
  }

  handleTouch();
  handleButtons();

  if (millis() - lastPoll >= POLL_MS) {
    lastPoll = millis();
    bool ok = poll();
    if (!ok && millis() - lastOkMs > 15000 && online) {
      online = false; nRows = 0; nAtt = nAct = nDone = 0;
      fingerprint = ""; setLed(false, false, true); drawAll();
    } else if (ok && !online) {
      online = true; fingerprint = ""; drawAll();
    }
  }

  // de kopregel opruimen als een berichtje is uitgewerkt
  static uint32_t lastHdr = 0;
  if (toastUntil && millis() > toastUntil && millis() - lastHdr > 200) {
    toastUntil = 0; lastHdr = millis(); drawHeader();
  }

  delay(20);
}
