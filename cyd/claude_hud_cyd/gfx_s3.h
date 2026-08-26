/* ===========================================================================
   gfx_s3.h -- the Guition JC3248W535C backend: ESP32-S3, AXS15231B 480x320
               over QSPI, capacitive touch on the same controller

   Three things about this panel shape the whole file, all of them learned the
   hard way in the glucose-display project that uses the same hardware:

   1. It has no hardware rotation, and partial writes to it are unreliable. So
      everything is drawn into a full-frame canvas in PSRAM and pushed out in
      one go. The canvas is created 320x480 (the panel's native portrait) with
      rotation 1, which gives a 480x320 landscape drawing surface while the
      flush still writes the frame the panel expects.

   2. Nothing appears until that flush. On the CYD every call lands on the glass
      immediately; here the sketch has to say when a frame is done, which is
      what gfxFlushNow() is for. On the CYD it compiles away to nothing.

   3. The framebuffer is 320 * 480 * 2 = 300 KB. That does not fit in internal
      RAM next to Wi-Fi, so the board must be built with PSRAM enabled
      (PSRAM=opi in the FQBN). Without it gfxBegin() fails and says so on the
      serial port rather than hanging.

   Text uses the built-in 6x8 font at size 2 and 3. In this library that font
   takes the cursor as the top-left corner and paints its own background when
   the background colour differs from the ink -- the same semantics TFT_eSPI has
   on the CYD, which is why one gfxText() can serve both. It is monospaced and
   plain; a proportional font generated from a TTF would look better and is the
   obvious next improvement, at about 90 KB of flash per face.
   =========================================================================== */
#ifndef GFX_S3_H
#define GFX_S3_H

#include <Arduino_GFX_Library.h>
#include <Wire.h>

// ---- panel wiring -----------------------------------------------------------
#define QSPI_CS   45
#define QSPI_SCK  47
#define QSPI_D0   21
#define QSPI_D1   48
#define QSPI_D2   40
#define QSPI_D3   39

#define PANEL_W  320      // native, portrait
#define PANEL_H  480
#define QSPI_HZ  (40 * 1000 * 1000)

// ---- touch wiring -----------------------------------------------------------
/* The AXS15231B handles the touch glass too, on its own fixed I2C pins, so
   there is nothing external to wire.

   The INT line decides when to believe the bus. Asked out of the blue this
   controller does not answer "nothing is happening" -- it answers with whatever
   it has, and measured on this panel that is a stale point that never changes.
   Reading only after INT has fallen is the difference between a finger and a
   leftover. INT is the same discriminator the reference project on this panel
   uses.

   Which leaves the question that made polling look attractive: the sketch asks
   "is a finger down right now" while somebody holds the top bar, and an edge is
   a moment, not a state. A held finger keeps the reports coming, so the state is
   rebuilt from them -- down until TOUCH_HOLD_MS passes with nothing new. */
#define TOUCH_SDA   4
#define TOUCH_SCL   8
#define TOUCH_INT   3
#define TOUCH_ADDR  0x3B
#define TOUCH_HOLD_MS 250

/* Set to 1 if taps land mirrored on real hardware -- which way round the glass
   is fitted is not something you can tell from the datasheet. */
#define TOUCH_FLIP_X 0
#define TOUCH_FLIP_Y 0
/* Prints every reply the controller accepts. Left switchable from the build
   rather than by editing this file, because the one thing you want when taps
   land wrong is a build you can make without touching the source. */
#ifndef GFX_TOUCH_DEBUG
#define GFX_TOUCH_DEBUG 0
#endif

static Arduino_DataBus *gQspi =
    new Arduino_ESP32QSPI(QSPI_CS, QSPI_SCK, QSPI_D0, QSPI_D1, QSPI_D2, QSPI_D3);
static Arduino_GFX *gPanel =
    new Arduino_AXS15231B(gQspi, GFX_NOT_DEFINED, 0, false, PANEL_W, PANEL_H);
// 320x480 native, rotation 1 -> we draw in 480x320 landscape.
static Arduino_Canvas *gCv =
    new Arduino_Canvas(PANEL_W, PANEL_H, gPanel, 0, 0, 1);

static bool gDirty = false;     // something was drawn since the last flush

// ---- how big is the screen, and how big is the type -------------------------
static inline int gfxWidth()  { return PANEL_H; }   // 480, we are rotated
static inline int gfxHeight() { return PANEL_W; }   // 320

// Built-in font: the cell is 6*size wide and 8*size tall.
static inline uint8_t gfxSizeOf(GfxFont f) {
  switch (f) {
    case GF_BIG:  return 3;    // 18x24
    case GF_HUGE: return 5;    // 30x40, the cracktro only
    default:      return 2;    // 12x16
  }
}

// ---- screen -----------------------------------------------------------------
static inline void gfxBegin() {
  if (!gCv->begin(QSPI_HZ)) {
    Serial.println("gfx: canvas failed -- is PSRAM enabled in the build?");
    return;
  }
  gCv->setTextWrap(false);     // a long session name must clip, not wrap
  gCv->fillScreen(0);
  gCv->flush();
}

/* Push the frame, but only if there is a new one. Called once per pass of the
   main loop and before anything that blocks for long enough to be noticed --
   without that second part a tapped row would not light up until the HTTP
   request it triggers had come back. */
static inline void gfxFlushNow() {
  if (!gDirty) return;
  gCv->flush();
  gDirty = false;
}

static inline void gfxFillScreen(uint16_t c)                           { gCv->fillScreen(c); gDirty = true; }
static inline void gfxFillRect(int x, int y, int w, int h, uint16_t c)  { gCv->fillRect(x, y, w, h, c); gDirty = true; }
static inline void gfxFillRoundRect(int x, int y, int w, int h, int r, uint16_t c) { gCv->fillRoundRect(x, y, w, h, r, c); gDirty = true; }
static inline void gfxDrawRoundRect(int x, int y, int w, int h, int r, uint16_t c) { gCv->drawRoundRect(x, y, w, h, r, c); gDirty = true; }
static inline void gfxDrawHLine(int x, int y, int w, uint16_t c)        { gCv->drawFastHLine(x, y, w, c); gDirty = true; }
static inline void gfxDrawPixel(int x, int y, uint16_t c)               { gCv->drawPixel(x, y, c); gDirty = true; }
static inline void gfxFillTriangle(int x1, int y1, int x2, int y2, int x3, int y3, uint16_t c) { gCv->fillTriangle(x1, y1, x2, y2, x3, y3, c); gDirty = true; }
static inline void gfxFillCircle(int x, int y, int r, uint16_t c)       { gCv->fillCircle(x, y, r, c); gDirty = true; }

static inline int gfxTextWidth(GfxFont f, const String& s) {
  return (int)s.length() * 6 * gfxSizeOf(f);
}

/* x,y mean what the alignment says: the top-left corner, the top-right corner,
   or the centre of the text. The library's own cursor is always top-left, so
   the other two are worked out here. */
static inline void gfxText(GfxFont f, GfxAlign a, int x, int y,
                           const String& s, uint16_t fg, uint16_t bg) {
  uint8_t sz = gfxSizeOf(f);
  int w = (int)s.length() * 6 * sz, h = 8 * sz;
  int cx = x, cy = y;
  if (a == GA_TR)      { cx = x - w; }
  else if (a == GA_MC) { cx = x - w / 2; cy = y - h / 2; }
  gCv->setFont((const GFXfont *)nullptr);
  gCv->setTextSize(sz);
  gCv->setTextColor(fg, bg);
  gCv->setCursor(cx, cy);
  gCv->print(s);
  gDirty = true;
}

/* ---- the "offscreen buffer" ------------------------------------------------
   On the CYD this is a real sprite, because there the alternative is watching a
   row being built up on the glass. Here the canvas is already offscreen -- the
   panel sees nothing until the flush -- so a second buffer would buy nothing
   and cost another 300 KB. All these do is shift the coordinates, which is why
   the destination is given at gfxBufBegin() and gfxBufPush() has nothing left
   to do. */
static int gBufX = 0, gBufY = 0, gBufW = 0, gBufH = 0;

static inline void gfxBufBegin(int x, int y, int w, int h) {
  gBufX = x; gBufY = y; gBufW = w; gBufH = h;
}
static inline void gfxBufFill(uint16_t c)                              { gfxFillRect(gBufX, gBufY, gBufW, gBufH, c); }
static inline void gfxBufRect(int x, int y, int w, int h, uint16_t c)   { gfxFillRect(gBufX + x, gBufY + y, w, h, c); }
static inline void gfxBufRoundRect(int x, int y, int w, int h, int r, uint16_t c) { gfxFillRoundRect(gBufX + x, gBufY + y, w, h, r, c); }
static inline void gfxBufDrawRoundRect(int x, int y, int w, int h, int r, uint16_t c) { gfxDrawRoundRect(gBufX + x, gBufY + y, w, h, r, c); }
static inline void gfxBufHLine(int x, int y, int w, uint16_t c)         { gfxDrawHLine(gBufX + x, gBufY + y, w, c); }
static inline void gfxBufText(GfxFont f, GfxAlign a, int x, int y,
                              const String& s, uint16_t fg, uint16_t bg) {
  gfxText(f, a, gBufX + x, gBufY + y, s, fg, bg);
}
static inline int gfxBufTextWidth(GfxFont f, const String& s) { return gfxTextWidth(f, s); }
static inline void gfxBufPush() { }
static inline void gfxBufEnd()  { gBufW = gBufH = 0; }

// ---- touch ------------------------------------------------------------------
/* The handler does nothing but raise a flag: the I2C transaction that follows
   takes the best part of a millisecond and has no business inside an interrupt. */
static volatile bool s3TouchIrq = false;
static void IRAM_ATTR s3TouchIsr() { s3TouchIrq = true; }

static inline void gfxTouchBegin() {
  Wire.begin(TOUCH_SDA, TOUCH_SCL);
  Wire.setClock(400000);
  pinMode(TOUCH_INT, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(TOUCH_INT), s3TouchIsr, FALLING);
}

/* One transaction: an eight-byte command asking for the first touch point, and
   an eight-byte reply carrying the point count and its coordinates. Both come
   back in the panel's native portrait frame.

   Believe the reply only when it could be a finger. Measured on the panel: with
   nobody near the glass this controller answers 0F 0F 0F 0F 0F 0F 0F 0F -- a
   count of fifteen at (3855, 3855). That is neither of the two values the count
   was checked against, so it used to be read as a real touch, and mapping those
   coordinates put it at the top of the screen, held. The screen therefore opened
   the setup portal on its own a second after every boot, which also silences the
   cable: the portal loop is the one path that never reads the serial port.

   Hence both tests. A count of one to five is what a five-point controller can
   truthfully report, and a point has to land on the panel it belongs to. */
static bool s3TouchRaw(int& px, int& py) {
  static const uint8_t cmd[8] = {0xB5, 0xAB, 0xA5, 0x5A, 0x00, 0x00, 0x00, 0x08};
  uint8_t buf[8];
  Wire.beginTransmission(TOUCH_ADDR);
  Wire.write(cmd, sizeof(cmd));
  if (Wire.endTransmission() != 0) return false;
  if (Wire.requestFrom((uint8_t)TOUCH_ADDR, (uint8_t)sizeof(buf)) != sizeof(buf)) return false;
  for (unsigned i = 0; i < sizeof(buf); i++) buf[i] = Wire.read();
  uint8_t points = buf[1];               // 0 on release, anything above 5 is noise
  if (points < 1 || points > 5) return false;
  int x = (int)((((uint16_t)(buf[2] & 0x0F)) << 8) | buf[3]);
  int y = (int)((((uint16_t)(buf[4] & 0x0F)) << 8) | buf[5]);
  if (x < 0 || x >= PANEL_W || y < 0 || y >= PANEL_H) return false;
  px = x; py = y;
  return true;
}

/* The state both callers want: is a finger down, and where. Only an interrupt
   opens the bus; between interrupts the last point stands for TOUCH_HOLD_MS, so
   a finger that is being held reads as down for as long as the reports keep
   arriving, and lifting it reads as up a quarter of a second later. */
static bool s3TouchNow(int& px, int& py) {
  static bool     down = false;
  static uint32_t seen = 0;
  static int      lastX = 0, lastY = 0;

  if (s3TouchIrq) {
    s3TouchIrq = false;
    if (s3TouchRaw(px, py)) {
      lastX = px; lastY = py; seen = millis(); down = true;
      return true;
    }
    /* INT also fires on release, and that read reports no point. Believe it:
       it is the earliest and most certain sign the finger is gone. */
    down = false;
    return false;
  }
  if (down && millis() - seen < TOUCH_HOLD_MS) { px = lastX; py = lastY; return true; }
  down = false;
  return false;
}

static inline bool gfxTouched() {
  int px, py;
  return s3TouchNow(px, py);
}

/* Native portrait counts into the landscape frame we draw in. The canvas is at
   rotation 1, which puts drawing pixel (x,y) at native column 319-y and native
   row x -- so a native point (px,py) sits at x=py, y=319-px. Worth deriving
   rather than guessing: with the axes right but a flip wrong, taps land in a
   mirror image and every hit test looks broken. */
static inline bool gfxTouchPoint(int& sx, int& sy) {
  int px, py;
  if (!s3TouchNow(px, py)) return false;
  sx = py;
  sy = (PANEL_W - 1) - px;
#if TOUCH_FLIP_X
  sx = (PANEL_H - 1) - sx;
#endif
#if TOUCH_FLIP_Y
  sy = (PANEL_W - 1) - sy;
#endif
  sx = constrain(sx, 0, PANEL_H - 1);
  sy = constrain(sy, 0, PANEL_W - 1);
#if GFX_TOUCH_DEBUG
  Serial.printf("raw px=%d py=%d  ->  x=%d y=%d\n", px, py, sx, sy);
#endif
  return true;
}

#endif  // GFX_S3_H
