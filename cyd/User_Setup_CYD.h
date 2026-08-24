// ===========================================================================
//  User_Setup_CYD.h -- TFT_eSPI-instellingen voor de Cheap Yellow Display
//  (ESP32-2432S028R, 2,8" ILI9341 320x240)
//
//  Kopieer dit bestand als User_Setup.h over
//    <Documenten>\Arduino\libraries\TFT_eSPI\User_Setup.h
//  of zet in User_Setup_Select.h een #include naar dit bestand.
//
//  Staan je kleuren omgekeerd (blauw waar rood moet zijn)? Wissel dan
//  ILI9341_2_DRIVER voor ILI9341_DRIVER. Er zijn twee CYD-varianten in omloop.
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

// Touch zit op de CYD op een tweede SPI-bus (MISO 39, MOSI 32, CLK 25, CS 33)
// en werkt dus niet via TFT_eSPI. De sketch gebruikt geen touch.
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
