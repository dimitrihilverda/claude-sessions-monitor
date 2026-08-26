/* ===========================================================================
   gfx_cyd.h -- the CYD backend: ESP32, ILI9341 320x240 over SPI, XPT2046 touch

   Include order is not free here. TFT_eSPI defines FS_NO_GLOBALS, and the core
   puts "using namespace fs;" in FS.h behind that guard -- so anything needing
   the name FS must be included before TFT_eSPI. The sketch does that; this
   header only assumes it already happened.
   =========================================================================== */
#ifndef GFX_CYD_H
#define GFX_CYD_H

#include <TFT_eSPI.h>
#include <SPI.h>
#include <XPT2046_Touchscreen.h>

// ---- panel and touch wiring -------------------------------------------------
// Touch sits on a second SPI bus, which is why TFT_eSPI cannot drive it.
#define TP_CLK  25
#define TP_MISO 39
#define TP_MOSI 32
#define TP_CS   33
#define TP_IRQ  36

/* Touch calibration. If taps land somewhere other than where you press, set
   GFX_TOUCH_DEBUG to 1, tap the four corners and put the extremes here. */
#define GFX_TOUCH_DEBUG 0
static int TS_MINX = 200, TS_MAXX = 3700;
static int TS_MINY = 240, TS_MAXY = 3800;
#define TOUCH_SWAP_XY  1
#define TOUCH_FLIP_X   0
#define TOUCH_FLIP_Y   1

static TFT_eSPI    gTft = TFT_eSPI();
static TFT_eSprite gBuf = TFT_eSprite(&gTft);
static SPIClass    gTpSpi(VSPI);
static XPT2046_Touchscreen gTs(TP_CS, TP_IRQ);

static bool gBufAlive = false;

// ---- how big is the screen, and how big is the type -------------------------
static inline int gfxWidth()  { return 320; }
static inline int gfxHeight() { return 240; }

// TFT_eSPI's built-in fonts: 2 is ~16 px tall, 4 is ~26, 6 is digits-only large.
static inline uint8_t gfxFontOf(GfxFont f) {
  switch (f) {
    case GF_BIG:  return 4;
    case GF_HUGE: return 6;
    default:      return 2;
  }
}

static inline uint8_t gfxDatumOf(GfxAlign a) {
  switch (a) {
    case GA_TR: return TR_DATUM;
    case GA_MC: return MC_DATUM;
    default:    return TL_DATUM;
  }
}

// ---- screen -----------------------------------------------------------------
static inline void gfxBegin() {
  gTft.init();
  gTft.setRotation(1);            // landscape, USB on the left
}

static inline void gfxFillScreen(uint16_t c)                        { gTft.fillScreen(c); }
static inline void gfxFillRect(int x, int y, int w, int h, uint16_t c) { gTft.fillRect(x, y, w, h, c); }
static inline void gfxFillRoundRect(int x, int y, int w, int h, int r, uint16_t c) { gTft.fillRoundRect(x, y, w, h, r, c); }
static inline void gfxDrawRoundRect(int x, int y, int w, int h, int r, uint16_t c) { gTft.drawRoundRect(x, y, w, h, r, c); }
static inline void gfxDrawHLine(int x, int y, int w, uint16_t c)     { gTft.drawFastHLine(x, y, w, c); }
static inline void gfxDrawPixel(int x, int y, uint16_t c)            { gTft.drawPixel(x, y, c); }
static inline void gfxFillTriangle(int x1, int y1, int x2, int y2, int x3, int y3, uint16_t c) { gTft.fillTriangle(x1, y1, x2, y2, x3, y3, c); }
static inline void gfxFillCircle(int x, int y, int r, uint16_t c)    { gTft.fillCircle(x, y, r, c); }

static inline void gfxText(GfxFont f, GfxAlign a, int x, int y,
                           const String& s, uint16_t fg, uint16_t bg) {
  gTft.setTextFont(gfxFontOf(f));
  gTft.setTextColor(fg, bg);
  gTft.setTextDatum(gfxDatumOf(a));
  gTft.drawString(s, x, y);
  gTft.setTextDatum(TL_DATUM);    // leave it as the rest of the code expects
}

static inline int gfxTextWidth(GfxFont f, const String& s) {
  gTft.setTextFont(gfxFontOf(f));
  return gTft.textWidth(s);
}

// ---- the offscreen buffer, for drawing a row without flicker ----------------
static inline void gfxBufBegin(int w, int h) {
  if (gBufAlive) gBuf.deleteSprite();
  gBuf.createSprite(w, h);
  gBufAlive = true;
}
static inline void gfxBufFill(uint16_t c)                            { gBuf.fillSprite(c); }
static inline void gfxBufRect(int x, int y, int w, int h, uint16_t c) { gBuf.fillRect(x, y, w, h, c); }
static inline void gfxBufRoundRect(int x, int y, int w, int h, int r, uint16_t c) { gBuf.fillRoundRect(x, y, w, h, r, c); }
static inline void gfxBufDrawRoundRect(int x, int y, int w, int h, int r, uint16_t c) { gBuf.drawRoundRect(x, y, w, h, r, c); }
static inline void gfxBufHLine(int x, int y, int w, uint16_t c)       { gBuf.drawFastHLine(x, y, w, c); }

static inline void gfxBufText(GfxFont f, GfxAlign a, int x, int y,
                              const String& s, uint16_t fg, uint16_t bg) {
  gBuf.setTextFont(gfxFontOf(f));
  gBuf.setTextColor(fg, bg);
  gBuf.setTextDatum(gfxDatumOf(a));
  gBuf.drawString(s, x, y);
  gBuf.setTextDatum(TL_DATUM);
}

static inline int gfxBufTextWidth(GfxFont f, const String& s) {
  gBuf.setTextFont(gfxFontOf(f));
  return gBuf.textWidth(s);
}

static inline void gfxBufPush(int x, int y) { gBuf.pushSprite(x, y); }
static inline void gfxBufEnd() {
  if (gBufAlive) { gBuf.deleteSprite(); gBufAlive = false; }
}

// ---- touch ------------------------------------------------------------------
static inline void gfxTouchBegin() {
  gTpSpi.begin(TP_CLK, TP_MISO, TP_MOSI, TP_CS);
  gTs.begin(gTpSpi);
  gTs.setRotation(0);   // raw orientation; the rotating happens below
}

static inline bool gfxTouched() { return gTs.touched(); }

/* Raw controller counts into screen pixels. The panel is wired portrait and the
   sketch runs landscape, hence the swap; the flips depend on which way the glass
   was fitted, which is why they are defines and not a constant.

   The order matters and is easy to get wrong: swap the axes FIRST, then map each
   through its own range. Mapping before swapping puts the X range on the Y axis
   and taps land nowhere near your finger. */
static inline bool gfxTouchPoint(int& sx, int& sy) {
  if (!gTs.tirqTouched() || !gTs.touched()) return false;
  TS_Point p = gTs.getPoint();

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

#if GFX_TOUCH_DEBUG
  Serial.printf("raw x=%d y=%d z=%d  ->  x=%d y=%d\n", p.x, p.y, p.z, sx, sy);
  gTft.fillCircle(sx, sy, 3, 0xE528);
#endif
  return true;
}

#endif  // GFX_CYD_H
