// ===========================================================================
//  User_Setup_CYD.h -- TFT_eSPI settings for the Cheap Yellow Display
//  (ESP32-2432S028R, 2.8" ILI9341 320x240)
//
//  Copy this file over
//    <Documents>\Arduino\libraries\TFT_eSPI\User_Setup.h
//  or add an #include pointing here in User_Setup_Select.h.
//
//  Note that updating TFT_eSPI overwrites User_Setup.h again.
//
//  Colours swapped (blue where red should be)? Then change ILI9341_2_DRIVER to
//  ILI9341_DRIVER -- there are two CYD variants in circulation. That is a
//  different problem from inverted colours; see TFT_INVERSION_ON below.
// ===========================================================================

#define ILI9341_2_DRIVER

#define TFT_WIDTH   240
#define TFT_HEIGHT  320

#define TFT_MISO    12
#define TFT_MOSI    13
#define TFT_SCLK    14
#define TFT_CS      15
#define TFT_DC       2
#define TFT_RST     -1
#define TFT_BL      21
#define TFT_BACKLIGHT_ON HIGH

// This CYD panel powers up with its colours inverted: send magenta and it shows
// green. None of the ILI9341 init sequences in TFT_eSPI send an inversion
// command themselves, so we set it here. TFT_eSPI then sends 0x21 (INVON) right
// after the init (see TFT_eSPI.cpp, around line 774).
//
// Worth knowing because of how it fails: inverted, two different dark shades
// both come out as light beige, so changing a colour looks like nothing
// happened at all rather than like something is wrong.
#define TFT_INVERSION_ON


// On the CYD the touch controller sits on a second SPI bus (MISO 39, MOSI 32,
// CLK 25, CS 33) and therefore does not work through TFT_eSPI. The sketch talks
// to it directly with XPT2046_Touchscreen, so leave this commented out.
// #define TOUCH_CS 33

#define LOAD_GLCD
#define LOAD_FONT2
#define LOAD_FONT4
#define LOAD_FONT6
#define LOAD_FONT7
#define LOAD_GFXFF
#define SMOOTH_FONT

#define SPI_FREQUENCY       55000000
#define SPI_READ_FREQUENCY  20000000
