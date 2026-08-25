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

/* De volgorde hieronder is niet vrij. TFT_eSPI definieert FS_NO_GLOBALS
   (Processors/TFT_eSPI_ESP32.h), en de core zet "using namespace fs;" in FS.h
   juist achter die guard. Staat TFT_eSPI eerst, dan is de naam FS onzichtbaar
   en breekt WebServer.h -- die gebruikt "FS &fs" ongekwalificeerd. Dus: eerst
   het netwerkspul, daarna het scherm. */
#include <WiFi.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <FS.h>
#include <WebServer.h>
#include <DNSServer.h>

#include <TFT_eSPI.h>
#include <SPI.h>
#include <XPT2046_Touchscreen.h>

/* ---- INSTELLEN -------------------------------------------------------------
   Wifi en het pc-adres hoef je hier NIET in te vullen. Die zet je op het
   schermpje zelf: lukt verbinden niet, dan zet de CYD zijn eigen netwerk op
   (zie PORTAAL_SSID hieronder) en stel je het in vanaf je telefoon. Wat je
   invult wordt bewaard in NVS en overleeft opnieuw flashen.

   Wil je toch vooraf vullen -- bijvoorbeeld om een stapel schermpjes uit te
   rollen -- dan mag dat hieronder. Het is dan een startwaarde: zodra er iets
   in NVS staat, gaat die voor. Let op dat een wachtwoord dat je hier neerzet
   in je git-geschiedenis belandt. */
const char* WIFI_SSID_START = "";
const char* WIFI_PASS_START = "";
const char* API_HOST_START  = "";
const int   API_PORT_START  = 8787;

const char* API_TOKEN = "";            // alleen invullen als je in actions.json een token zet

// Het eigen netwerk waarmee je hem instelt. Bewust met wachtwoord: op een open
// netwerk kan iedereen in de buurt de instellingen van je schermpje overschrijven.
const char* PORTAAL_SSID = "Claude-Deck";
const char* PORTAAL_PASS = "claudedeck";

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

/* ---- kleuren --------------------------------------------------------------
   Omgerekend van RGB888 naar RGB565: ((r>>3)<<11) | ((g>>2)<<5) | (b>>3).

   Let op dat 565 grof afrondt: rood en blauw in stappen van 8, groen in
   stappen van 4. Twee hexwaarden die op je monitor duidelijk verschillen
   kunnen op dit paneel identiek uitkomen. De trap achtergrond -> rijvlak ->
   hover is daarop gekozen: achtergrond en rijvlak verschillen in groen,
   rijvlak en hover in rood en blauw, zodat beide stappen zichtbaar blijven.
   Wat het paneel er werkelijk van maakt staat achter elke regel. */
#define COL_BG      0x2987   // #2A3238  achtergrond (ook de kopbalk)
#define COL_HDR     0x2987   // gelijk aan de achtergrond
#define COL_ROW     0x29C8   // #2E3840  rijvlak, een tik lichter dan de achtergrond
#define COL_SEL     0x3209   // #364048  hover / geselecteerde rij
#define COL_LINE    0x3A29   // #3A444B  scheidingslijnen en knoprand
#define COL_TXT     0xEF9E   // #EEF3F5  titel van een sessie
#define COL_MUTED   0x8CF1   // #8E9C8B  de inforegel eronder
#define COL_GREEN   0x9648   // #91C847  actief
#define COL_ORANGE  0xE528   // #E6A745  wacht op jou
#define COL_STEEL   0x7C70   // #7E8C84  klaar -- neutraal grijs; stond op het
                             // staalblauw #9BB0C7 en dat las als "blauw balkje"

/* De HUD tekent statuslabels als "chip": een vlakje in de statuskleur op
   alpha 38 over de rij, een rand op alpha 150 en de tekst in de volle kleur.
   Met deze helper hoeven die tussenkleuren niet hardgecodeerd te worden en
   klopt de chip op zowel een gewone als een geselecteerde rij. */
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
int      btnFlash = -1;        // welke schermknop nu oplicht (-1 = geen)
/* Helderheidstrap. Tik op de bovenbalk om te wisselen; het paneel oogt bij een
   te hoge stand snel flets. De stand die je kiest kun je als BACKLIGHT_PCT
   bovenin vastzetten, dan start hij er meteen mee. */
const uint8_t BL_TRAP[] = { 100, 70, 50, 35, 25, 15 };
const int     N_BL = sizeof(BL_TRAP) / sizeof(BL_TRAP[0]);
int      blIdx = 1;            // wijst naar 70, gelijk aan BACKLIGHT_PCT

uint32_t btnFlashUntil = 0;
bool     online = false;
uint32_t lastPoll = 0, lastOkMs = 0, lastTouch = 0;

// ---- instellingen uit NVS (hier al declareren: httpGet gebruikt ze) --------
Preferences nvs;
String   cfgSsid, cfgPass, cfgHost;
uint16_t cfgPort = 8787;

bool      portaalActief = false;
WebServer portaalWeb(80);
DNSServer portaalDns;


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
  uint16_t bg = alarm ? COL_ORANGE : COL_HDR;
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
  tft.drawFastHLine(0, HDR_H, 320, COL_LINE);
}

void drawRow(int i) {
  int y = ROW_Y + i * ROW_H;
  row.createSprite(320, ROW_H - 3);
  row.fillSprite(COL_BG);

  if (i < nRows) {
    bool sel = (i == selIdx);
    uint16_t c = stateColor(rows[i].state);
    /* De streep links zegt WAT de sessie doet, het lichtere vlak welke rij
       geselecteerd is -- twee losse signalen, geen extra omlijning. */
    row.fillRoundRect(6, 0, 308, ROW_H - 3, 6, sel ? COL_SEL : COL_ROW);
    row.fillRect(6, 0, 3, ROW_H - 3, c);

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

    /* Statuschip, net als Draw-Chip in hud.ps1: vulling in de statuskleur op
       alpha 38 over de rij, rand op 150, tekst in de volle kleur. Dat is waar
       het groen (en bij aandacht het oranje) echt in beeld komt. */
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
      row.drawString("Geen actieve sessies.", 16, 10);
    } else {
      /* Zet er het adres bij dat hij probeert. Een typefout in het pc-adres is
         anders onvindbaar: wifi werkt, dus het portaal komt niet vanzelf, en het
         scherm zei alleen "Wacht op de pc..." zonder te verklappen waarop. */
      row.setTextColor(COL_ORANGE, COL_BG);
      row.drawString(String("Geen antwoord van ") + cfgHost + ":" + cfgPort, 16, 3);
      row.setTextColor(COL_MUTED, COL_BG);
      row.drawString("Draait de API op je pc? Klopt dit adres?", 16, 21);
    }
  } else if (i == 1 && !online && !nRows) {
    row.setTextFont(2);
    row.setTextColor(COL_MUTED, COL_BG);
    row.drawString("Bovenbalk 2 sec vasthouden = instellen", 16, 10);
  }

  row.pushSprite(0, y);
  row.deleteSprite();
}

/* Eén bron voor de plaats van knop i, zodat het getekende vlak en het
   trefvlak niet uit elkaar kunnen lopen. Dat gebeurde wel: er werd getekend
   op 6 + i*104 (breed 100) terwijl de tik werd afgerond met x / 107. Zolang
   er geen zichtbare feedback was viel dat niet op; met een oplichtende knop
   zie je meteen dat je naast het vlak drukt. */
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
  // Het rijvlak ligt dicht tegen de achtergrond, dus zonder rand zou je niet
  // zien dat het knoppen zijn.
  tft.drawRoundRect(x, BAR_Y, w, BAR_H - 6, 6, pressed ? COL_GREEN : COL_LINE);
  tft.setTextFont(2);
  tft.setTextDatum(MC_DATUM);
  tft.setTextColor(ink, vlak);
  String l = btnLabel[i];
  if (l.length() > 13) l = l.substring(0, 12) + ".";
  tft.drawString(l, x + w / 2, BAR_Y + (BAR_H - 6) / 2);
  tft.setTextDatum(TL_DATUM);
}

// Laat knop i oplichten. Het terugtekenen doet loop(), zodat er geen delay()
// in de touch- of knopafhandeling hoeft en het pollen gewoon doorloopt.
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
  String url = String("http://") + cfgHost + ":" + cfgPort + path;
  /* 4 s, niet 2,5. De API bouwt de sessielijst op via WMI-procesqueries en dat
     kost bij een koude cache zo'n 1,5 s, met uitschieters daarboven als WMI
     traag is. Op 2,5 s viel de poll daar regelmatig op om en zei het schermpje
     "geen antwoord" terwijl er niets mis was. Hoger dan dit niet: een mislukte
     poll blokkeert deze lus, en dan reageert het aanraakscherm zolang niet. */
  http.setConnectTimeout(4000);
  http.setTimeout(4000);
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

  /* Bovenbalk: korte tik stapt de helderheid, twee seconden vasthouden opent
     het instelportaal. Die lange druk is de uitweg voor het geval hij wél op
     wifi zit maar het pc-adres verkeerd staat -- dan komt het portaal nooit
     vanzelf en zou je zonder USB vastzitten.
     Het moet touch zijn en geen knop: knop 3 heeft een externe weerstand nodig
     die er misschien niet is, en de BOOT-knop ingedrukt houden bij het opstarten
     zet de ESP32 in flashmodus. */
  if (y < HDR_H) {
    uint32_t neer = millis();
    while (ts.touched() && millis() - neer < 2200) delay(50);
    if (millis() - neer >= 2000) {
      say("instellen...");
      drawHeader();
      startPortaal();
      return;
    }
    blIdx = (blIdx + 1) % N_BL;
    setBacklight(BL_TRAP[blIdx]);
    Serial.printf("helderheid %d%%\n", BL_TRAP[blIdx]);
    say(String("licht ") + BL_TRAP[blIdx] + "%");
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
  if (y >= BAR_Y) {                             // op een knopvlak getikt
    int i = btnHit(x);
    if (i < 0) return;                          // tussen twee knoppen in
    flashButton(i);
    char b[2] = { (char)('1' + i), 0 };
    sendAction(b);
  }
}

// ---- knoppen ---------------------------------------------------------------
void handleButtons() {
  for (int i = 0; i < N_BTN; i++) {
    bool down = (digitalRead(BUTTONS[i].pin) == LOW);
    /* De BOOT-knop is de uitzondering: die beslist bij het LOSLATEN, want een
       korte druk is knop 4 en twee seconden vasthouden opent de cracktro. De
       andere knoppen vuren op de neergaande rand, want daar wil je geen
       vertraging op een goedkeur-knop. */
    if (BUTTONS[i].pin == 0) {
      if (down && !btnWas[i]) btnAt[i] = millis();
      if (!down && btnWas[i]) {
        uint32_t vast = millis() - btnAt[i];
        if (vast >= 2000)     cracktro();
        else if (vast > 40)   sendAction(BUTTONS[i].id);   // 40 ms = ontdenderen
      }
      btnWas[i] = down;
      continue;
    }

    if (down && !btnWas[i] && millis() - btnAt[i] > 250) {
      btnAt[i] = millis();
      flashButton(i);          // knop 1-3 heeft een schermvlak; de BOOT-knop niet
      sendAction(BUTTONS[i].id);
    }
    btnWas[i] = down;
  }
}

// ---- instellingen in NVS ---------------------------------------------------
/* Wifi en het pc-adres staan in NVS (het flashgebied dat een nieuwe sketch niet
   wist), niet in de code. Zo hoeft er geen wachtwoord in git en kun je het ding
   op een ander netwerk zetten zonder USB -- wat uitkomt, want die kabel is nu
   precies het onbetrouwbare deel. */
void leesInstellingen() {
  nvs.begin("claudedeck", true);          // true = alleen lezen
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

// ---- portaal ---------------------------------------------------------------
// wat er op het schermpje staat zolang het portaal open is
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
  // De scan staat in AP_STA-modus toe; even wachten hoeft niet, dit duurt
  // een paar honderd ms en gebeurt alleen als iemand de pagina opent.
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
  delay(800);                       // de pagina nog laten wegsturen
  ESP.restart();
}

void startPortaal() {
  if (portaalActief) return;
  portaalActief = true;
  Serial.println("portaal gestart");

  WiFi.disconnect(true);
  WiFi.mode(WIFI_AP_STA);           // AP_STA: nodig om te kunnen scannen
  WiFi.softAP(PORTAAL_SSID, PORTAAL_PASS);
  delay(200);

  portaalDns.start(53, "*", WiFi.softAPIP());   // alles naar ons toe -> pagina springt open
  portaalWeb.on("/", HTTP_GET, []() {
    portaalWeb.send(200, "text/html; charset=utf-8", portaalPagina());
  });
  portaalWeb.on("/opslaan", HTTP_POST, portaalOpslaan);
  portaalWeb.onNotFound([]() {                  // captive-portal detectie van telefoons
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
/* Powersave uitzetten moet ná het verbinden. De ESP32-core stelt de slaapstand
   opnieuw in zodra de link tot stand komt, dus een setSleep(false) vóór
   WiFi.begin() beklijft vaak niet. Het symptoom is een pingtijd die tussen een
   paar ms en het beacon-interval van de router (~100 ms) heen en weer springt,
   met verbindingen die daardoor af en toe helemaal wegvallen.
   De RSSI staat erbij omdat powersave maar één verklaring is: bij -75 dBm of
   lager is het gewoon bereik en helpt geen enkele instelling. */
void wifiVerbonden() {
  WiFi.setSleep(false);
  Serial.printf("IP: %s  RSSI %d dBm\n",
                WiFi.localIP().toString().c_str(), WiFi.RSSI());
}

/* WiFi.reconnect() is onbetrouwbaar zodra de AP de client heeft weggegooid --
   de status blijft dan hangen zonder dat er een nieuwe associatie komt. Daarom
   eerst een gewone reconnect, en als dat na 10 seconden niets oplevert een
   volledige disconnect + begin. Die dwingt wel altijd een nieuwe associatie af,
   en wordt daarna elke 10 seconden herhaald zolang de link weg blijft. */
void bewaakWifi() {
  static uint32_t wegSinds = 0;

  if (WiFi.status() == WL_CONNECTED) {
    if (wegSinds) { wegSinds = 0; wifiVerbonden(); }   // net teruggekomen
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
/* Een knipoog naar de intro's van 1992. Openen: BOOT-knop twee seconden
   vasthouden. Terug: het scherm aanraken of een knop indrukken.

   >>> HIER JE EIGEN TEKST <<<  Laat de spaties aan het eind staan, dan loopt
   hij netjes rond in plaats van tegen zichzelf aan te botsen. */
const char* SCROLL_TEXT =
  "CLAUDE DECK ... GREETINGS TO ... EN JIJ VULT DE REST IN ...        ";

/* Melodie voor de speaker op IO26. Let op: op de CYD zit geen luidspreker,
   alleen de pads -- zonder er een op te solderen blijft dit stil.
   0 = rust. Toonhoogtes in Hz, duur in eenheden van NOOT_MS. */
const uint16_t MELODIE[] = { 659,0,659,0,523,659,784,0,659,523,440,0,440,523,659,0 };
const int      N_NOOT    = sizeof(MELODIE) / sizeof(MELODIE[0]);
const uint16_t NOOT_MS   = 140;

struct Star { int16_t x, y; uint8_t laag; };

void cracktro() {
  // pollen en herverbinden staan stil zolang dit draait; het is een bewuste actie
  tft.fillScreen(TFT_BLACK);
  tft.setViewport(0, 0, 320, 240);

  const int N_STAR = 54;
  Star st[N_STAR];
  for (int i = 0; i < N_STAR; i++) {
    st[i].x = random(320);
    st[i].y = random(240);
    st[i].laag = i % 3;                 // 3 dieptes -> parallax
  }
  const uint8_t snelheid[3] = { 1, 2, 4 };
  const uint16_t sterKleur[3] = { 0x4208, 0x8410, 0xFFFF };   // ver -> dichtbij

  // Copperpalet: van donker via warm naar wit en terug, dat geeft de
  // metaalglans van een echte copper bar.
  const int N_COP = 16;
  uint16_t cop[N_COP];
  for (int i = 0; i < N_COP; i++) {
    int t = (i < N_COP / 2) ? i : (N_COP - 1 - i);          // 0..7..0
    uint8_t r = 60 + t * 27;
    uint8_t g = 20 + t * 24;
    uint8_t b = 10 + t * 8;
    cop[i] = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
  }

  TFT_eSprite scr = TFT_eSprite(&tft);
  scr.setColorDepth(16);
  scr.createSprite(320, 26);

  const int LOGO_Y = 44, LOGO_H = 32, COP_Y = 96, COP_H = 44, SCR_Y = 190;
  int scrollX = 320;
  uint32_t frame = 0, t0 = millis();
  int noot = -1;

  while (true) {
    // ---- weg hier? -------------------------------------------------------
    if (ts.touched()) break;
    bool knop = false;
    for (int i = 0; i < N_BTN; i++) if (digitalRead(BUTTONS[i].pin) == LOW) knop = true;
    if (knop) break;

    // ---- sterren ---------------------------------------------------------
    for (int i = 0; i < N_STAR; i++) {
      tft.drawPixel(st[i].x, st[i].y, TFT_BLACK);        // oude weg
      st[i].x -= snelheid[st[i].laag];
      if (st[i].x < 0) { st[i].x = 319; st[i].y = random(240); }
      // niet over het logo en de scroller heen sterren tekenen
      bool bedekt = (st[i].y >= LOGO_Y && st[i].y < COP_Y + COP_H) ||
                    (st[i].y >= SCR_Y && st[i].y < SCR_Y + 26);
      if (!bedekt) tft.drawPixel(st[i].x, st[i].y, sterKleur[st[i].laag]);
    }

    // ---- copper bars -----------------------------------------------------
    for (int y = 0; y < COP_H; y++) {
      int idx = (int)((y + frame / 2)) % N_COP;
      tft.drawFastHLine(0, COP_Y + y, 320, cop[idx]);
    }

    // ---- logo met copperbanden -------------------------------------------
    /* De truc: het logo per horizontale band tekenen met setViewport als
       clip, elke band in een andere copperkleur. Acht drawString-aanroepen,
       in plaats van 7200 pixels lezen en terugschrijven. */
    int bob = (int)(sin(frame * 0.06f) * 5.0f);
    tft.fillRect(0, LOGO_Y - 6, 320, LOGO_H + 12, TFT_BLACK);
    const int BAND = 4;
    for (int b = 0; b < LOGO_H; b += BAND) {
      tft.setViewport(0, LOGO_Y + bob + b, 320, BAND);
      tft.setTextDatum(TC_DATUM);
      tft.setTextFont(4);
      tft.setTextColor(cop[((b / BAND) + frame / 3) % N_COP]);
      tft.drawString("CLAUDE DECK", 160, -b);      // negatieve y = omhoog schuiven
      tft.setTextDatum(TL_DATUM);
    }
    tft.resetViewport();

    // ---- golvende scroller ------------------------------------------------
    scr.fillSprite(TFT_BLACK);
    scr.setTextFont(4);
    scr.setTextDatum(TL_DATUM);
    int x = scrollX;
    for (const char* p = SCROLL_TEXT; *p && x < 320; p++) {
      char c[2] = { *p, 0 };
      int w = scr.textWidth(c);
      if (x + w > 0) {
        int golf = (int)(sin((x + frame * 3) * 0.035f) * 5.0f);
        scr.setTextColor(cop[(int)((x / 8) + frame / 2) % N_COP]);
        scr.drawString(c, x, 8 + golf);
      }
      x += w;
    }
    scr.pushSprite(0, SCR_Y);
    scrollX -= 3;
    if (x < 0) scrollX = 320;                       // rond, zodra alles voorbij is

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
    delay(16);                                      // ~60 fps zolang hij het haalt
  }

  // ---- opruimen ----------------------------------------------------------
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWriteTone(PIN_SPK, 0); ledcDetach(PIN_SPK);
#else
  ledcWriteTone(LEDC_TONE, 0); ledcDetachPin(PIN_SPK);
#endif
  scr.deleteSprite();
  tft.resetViewport();
  while (ts.touched()) delay(20);       // vinger van het glas voordat we verder gaan
  lastTouch = millis();
  tft.fillScreen(COL_BG);
  fingerprint = "";                     // volgende poll tekent alles opnieuw
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

  leesInstellingen();

  /* Nog nooit ingesteld? Dan meteen het portaal op, zonder eerst twintig
     seconden op een leeg SSID te wachten. */
  if (!cfgSsid.length()) { startPortaal(); return; }

  WiFi.mode(WIFI_STA);
  WiFi.begin(cfgSsid.c_str(), cfgPass.c_str());
  uint32_t t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < 20000) delay(250);

  /* Lukt het niet, dan is het wachtwoord of het netwerk veranderd. Het portaal
     is dan de enige uitweg die geen USB nodig heeft. */
  if (WiFi.status() != WL_CONNECTED) { startPortaal(); return; }
  wifiVerbonden();

  tft.fillScreen(COL_BG);
  drawAll();
}

void loop() {
  /* Staat het portaal open, dan doet dit ding niets anders: geen pollen, geen
     herverbinden. Anders zou bewaakWifi() de AP onder het formulier weghalen. */
  if (portaalActief) { portaalLus(); delay(5); return; }

  bewaakWifi();

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

  // een opgelichte knop weer laten uitgaan
  if (btnFlashUntil && millis() > btnFlashUntil) {
    int i = btnFlash;
    btnFlashUntil = 0; btnFlash = -1;
    if (i >= 0) drawButton(i, false);
  }

  // de kopregel opruimen als een berichtje is uitgewerkt
  static uint32_t lastHdr = 0;
  if (toastUntil && millis() > toastUntil && millis() - lastHdr > 200) {
    toastUntil = 0; lastHdr = millis(); drawHeader();
  }

  delay(20);
}
