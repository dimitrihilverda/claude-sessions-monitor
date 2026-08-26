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
   there is nothing external to wire. We poll it instead of using the INT line:
   the sketch asks "is a finger down right now" in two different places (a tap,
   and holding the top bar), and an edge-triggered flag cannot answer the second
   one. One transaction is eight bytes at 400 kHz, cheap enough to do on every
   pass of the loop. */
#define TOUCH_SDA   4
#define TOUCH_SCL   8
#define TOUCH_ADDR  0x3B

/* Set to 1 if taps land mirrored on real hardware -- which way round the glass
   is fitted is not something you can tell from the datasheet. */
#define TOUCH_FLIP_X 0
#define TOUCH_FLIP_Y 0
#define GFX_TOUCH_DEBUG 0

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
static inline void gfxTouchBegin() {
  Wire.begin(TOUCH_SDA, TOUCH_SCL);
  Wire.setClock(400000);
}

/* One transaction: an eight-byte command asking for the first touch point, and
   an eight-byte reply carrying the point count and its coordinates. Both come
   back in the panel's native portrait frame. */
static bool s3TouchRaw(int& px, int& py) {
  static const uint8_t cmd[8] = {0xB5, 0xAB, 0xA5, 0x5A, 0x00, 0x00, 0x00, 0x08};
  uint8_t buf[8];
  Wire.beginTransmission(TOUCH_ADDR);
  Wire.write(cmd, sizeof(cmd));
  if (Wire.endTransmission() != 0) return false;
  if (Wire.requestFrom((uint8_t)TOUCH_ADDR, (uint8_t)sizeof(buf)) != sizeof(buf)) return false;
  for (unsigned i = 0; i < sizeof(buf); i++) buf[i] = Wire.read();
  uint8_t points = buf[1];                       // 0 on release, 0xFF on garbage
  if (points == 0 || points == 0xFF) return false;
  px = (int)((((uint16_t)(buf[2] & 0x0F)) << 8) | buf[3]);
  py = (int)((((uint16_t)(buf[4] & 0x0F)) << 8) | buf[5]);
  return true;
}

static inline bool gfxTouched() {
  int px, py;
  return s3TouchRaw(px, py);
}

/* Native portrait counts into the landscape frame we draw in. The canvas is at
   rotation 1, which puts drawing pixel (x,y) at native column 319-y and native
   row x -- so a native point (px,py) sits at x=py, y=319-px. Worth deriving
   rather than guessing: with the axes right but a flip wrong, taps land in a
   mirror image and every hit test looks broken. */
static inline bool gfxTouchPoint(int& sx, int& sy) {
  int px, py;
  if (!s3TouchRaw(px, py)) return false;
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
