/* ===========================================================================
   board.h -- everything that differs between the two boards, except drawing

   gfx.h covers the panel and the touch glass. What is left is the rest of the
   hardware (backlight, LED, speaker, buttons) and the layout metrics, and both
   are board facts rather than sketch logic: the CYD is 320x240 with an RGB LED
   and a speaker on a DAC pin, the Guition is 480x320 with neither.

   The layout numbers live here for one reason: the vertical ones cannot be
   derived from the panel. Widths can -- a row is simply the screen minus a
   margin -- but how tall a row has to be is set by how tall the type is, and
   the two boards do not use the same type. Deriving them anyway is what
   produces a 480x320 screen with a 240-pixel layout stranded at the top.

   Names are the ones the sketch already used, so the drawing code reads the
   same on both boards.
   =========================================================================== */
#ifndef BOARD_H
#define BOARD_H

#include "gfx.h"       // for BOARD_KIND

#if BOARD_KIND == BOARD_CYD
/* ---------------------------------------------------------------------------
   Cheap Yellow Display: ESP32-2432S028R, 320x240
   --------------------------------------------------------------------------- */
#define PIN_BL       21    // backlight
#define PIN_SPK      26    // audio output of the CYD
#define LEDC_BL       0
#define LEDC_TONE     1

#define BOARD_HAS_SPK 1
#define USE_RGB_LED   1    // the status LED on the board itself
#define PIN_LED_R     4    // active LOW
#define PIN_LED_G    16
#define PIN_LED_B    17

/* The three buttons. GPIO 22 and 27 come out on the JST connectors and have an
   internal pull-up: switch between the pin and GND, done.
   GPIO 35 is input-only and has NO internal pull-up -- that one needs a 10k
   resistor between the pin and 3V3. The CYD's own BOOT button (GPIO 0) joins in
   as a fourth button; just do not hold it during power-up, or the ESP32 goes
   into flash mode. */
#define BOARD_BUTTONS { { 22, true,  "1" }, \
                        { 27, true,  "2" }, \
                        { 35, false, "3" }, \
                        {  0, true,  "4" } }

// ---- layout: 320x240, TFT_eSPI fonts 2 (16 px) and 4 (26 px) ----------------
#define HDR_H        28
#define HDR_TXT_Y     5
#define ROW_Y        30
#define ROW_H        41
#define MAX_ROWS      4    // rows that fit on screen at once
#define NAME_Y        2    // a short name, in the big font
#define NAME_SM_Y     4    // a long one, a size down
#define INFO_Y       23
#define CHIP_H       17
#define BAR_Y       196
#define BAR_H        44
#define BTN_W       100
#define BTN_GAP       4
/* Truncation limits in characters. Both fonts are proportional here, so these
   are deliberately conservative rather than exact. */
#define NAME_BIG_MAX 16    // up to this length the name gets the big font
#define NAME_MAX     34
#define WHY_MAX      52

#elif BOARD_KIND == BOARD_S3
/* ---------------------------------------------------------------------------
   Guition JC3248W535C: ESP32-S3, 480x320 landscape

   No RGB LED and no speaker on a DAC pin -- audio on this board goes to an
   NS4168 amplifier over I2S, which is a different mechanism altogether and not
   worth carrying for one beep. The attention beep is simply off here.

   GPIO 0 is the BOOT button. If a particular board does not wire one, the
   pull-up keeps it reading HIGH and the button never fires.
   --------------------------------------------------------------------------- */
#define PIN_BL        1    // backlight, PWM
#define PIN_SPK      -1    // no speaker on a plain pin
#define LEDC_BL       0
#define LEDC_TONE     1

#define BOARD_HAS_SPK 0
#define USE_RGB_LED   0
#define PIN_LED_R    -1
#define PIN_LED_G    -1
#define PIN_LED_B    -1

#define BOARD_BUTTONS { { 0, true, "4" } }

/* ---- layout: 480x320, built-in font at size 2 (12x16) and 3 (18x24) --------
   It adds up exactly: header 36, then 5 rows of 46 from y=40 (ends at 270),
   and the button bar from 272 to 320. Change one and check the sum. */
#define HDR_H        36
#define HDR_TXT_Y    10
#define ROW_Y        40
#define ROW_H        46
#define MAX_ROWS      5
#define NAME_Y        1
#define NAME_SM_Y     4
#define INFO_Y       26
#define CHIP_H       19
#define BAR_Y       272
#define BAR_H        48
#define BTN_W       152    // 8 + 3*152 + 2*6 gaps = 476, inside 480
#define BTN_GAP       6
/* This font is monospaced, so these are exact: a row is 468 px wide, less a
   16 px indent, at 12 px per character for the small font and 18 for the big. */
#define NAME_BIG_MAX 18
#define NAME_MAX     25
#define WHY_MAX      37

#else
#error "board.h: unknown BOARD_KIND"
#endif

#endif  // BOARD_H
