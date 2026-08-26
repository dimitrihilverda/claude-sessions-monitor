/* ===========================================================================
   gfx.h -- one drawing interface, two very different panels behind it

   The sketch used to talk straight to TFT_eSPI. That is fine for one board and
   a dead end for two: the Guition JC3248W535C is an ESP32-S3 with an AXS15231B
   over QSPI, driven by Arduino_GFX, and none of TFT_eSPI's calls exist there.
   Rather than a second sketch that slowly drifts from this one, the drawing
   sits behind these functions and each board provides them.

   Three decisions worth knowing about:

   - Text is ONE call. TFT_eSPI wants setTextFont, setTextColor, setTextDatum and
     then drawString; that pattern accounted for about fifty call sites, and
     four-calls-per-string is four chances for a leftover setting to bleed into
     the next draw. gfxText carries everything it needs.

   - Colours stay uint16_t RGB565. Both backends speak it natively, so there is
     nothing to convert and nothing to get wrong.

   - Fonts are an enum, not a number. TFT_eSPI's "font 2" means nothing to
     Arduino_GFX, so the sketch asks for SMALL or BIG and each backend decides
     what that is on its panel. On a 480x320 screen those are simply larger.

   The offscreen buffer (gfxBuf*) is how a row gets drawn without flicker. On the
   CYD that is a TFT_eSPI sprite; on the S3 the whole screen is already a canvas,
   so there it is only a coordinate shift. Hence gfxBufBegin() takes the spot on
   screen it will end up in: the S3 needs it up front, and the CYD does not mind
   being told early. One buffer at a time is all the sketch ever needs.

   gfxFlushNow() is the other thing the two panels disagree about. On the CYD a
   draw call lands on the glass immediately; the S3 shows nothing until its frame
   is pushed. So the sketch says when a frame is done, and on the CYD that call
   compiles away to nothing.
   =========================================================================== */
#ifndef GFX_H
#define GFX_H

#define BOARD_CYD 1     // ESP32 + ILI9341 320x240 over SPI, XPT2046 touch
#define BOARD_S3  2     // ESP32-S3 + AXS15231B 480x320 over QSPI, touch on the same chip

#ifndef BOARD_KIND
#define BOARD_KIND BOARD_CYD
#endif

/* Sizes, not point sizes: what BIG means is the backend's business. SMALL is for
   the second line of a row, BIG for a session name, HUGE only for the cracktro. */
enum GfxFont { GF_SMALL = 0, GF_BIG = 1, GF_HUGE = 2 };

/* Where x,y sits relative to the text. Only the three the sketch actually uses:
   top-left, top-right, and centred on both axes. */
enum GfxAlign { GA_TL = 0, GA_TR = 1, GA_MC = 2 };

#if BOARD_KIND == BOARD_CYD
  #include "gfx_cyd.h"
#elif BOARD_KIND == BOARD_S3
  #include "gfx_s3.h"
#else
  #error "Set BOARD_KIND to BOARD_CYD or BOARD_S3"
#endif

#endif  // GFX_H
