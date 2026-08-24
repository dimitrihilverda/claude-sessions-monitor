# Claude-sessies op de Cheap Yellow Display

De CYD (ESP32-2432S028R) haalt elke 3 seconden de sessielijst op bij je pc en
toont per sessie een rij: oranje = wacht op jou, groen = actief, grijs = klaar.
Bij een nieuwe oranje sessie piept hij kort, knippert de bovenbalk en kleurt de
RGB-led op het board mee.

**Tikken op een rij** selecteert die sessie en haalt het bijbehorende venster op
je pc naar voren — precies wat een klik in de HUD doet.

**De drie knoppen** voeren uit wat er in `actions.json` op je pc staat. De CYD
stuurt alleen "knop 2 op sessie X"; je pc bepaalt de betekenis. Standaard:
knop 1 keurt goed (Enter), knop 2 weigert (Esc), knop 3 zet de sessie 10 minuten
stil. De labels onderin het scherm komen uit datzelfde bestand, dus omzetten
kan zonder opnieuw te flashen. De BOOT-knop van de CYD doet als knop 4 mee.

Een printbare behuizing met die drie toetsen staat in `..\case\`.

## 1. Op de pc: de API aanzetten

De CYD praat met `session-api.ps1` in de map erboven.

    powershell -ExecutionPolicy Bypass -File session-api.ps1

Of stil op de achtergrond: dubbelklik `api.vbs`.

Bij de eerste start vraagt Windows Firewall om toestemming; kies
**prive-netwerken toestaan**. Wil je die regel vooraf zetten, dan in een
administrator-prompt:

    netsh advfirewall firewall add rule name="Claude sessie-API" dir=in action=allow protocol=TCP localport=8787

Het script print bij het starten de bruikbare adressen. Test in je browser:

    http://<ip-van-je-pc>:8787/cyd.txt      <- wat de CYD leest
    http://<ip-van-je-pc>:8787/             <- klein statuspaginaatje (ook op je telefoon)

Zet in je router een DHCP-reservering voor je pc, anders klopt het IP in de
sketch na een herstart niet meer.

## 2. In de Arduino IDE

1. **Board**: ESP32 Dev Module (esp32 by Espressif, 2.x of 3.x -- beide werken).
   Upload speed 921600, Flash 4MB, Partition Scheme: Default.
2. **Libraries** via Library Manager: **TFT_eSPI** (Bodmer) en
   **XPT2046_Touchscreen** (Paul Stoffregen).
3. Kopieer `User_Setup_CYD.h` over
   `Documenten\Arduino\libraries\TFT_eSPI\User_Setup.h`.
   Let op: bij een update van TFT_eSPI wordt dat bestand overschreven.
4. Open `claude_hud_cyd/claude_hud_cyd.ino` en vul bovenaan in:
   `WIFI_SSID`, `WIFI_PASS`, `API_HOST` (het IP van je pc).
5. Uploaden. Werkt de upload niet, houd dan BOOT ingedrukt terwijl je start.

## 3. Als het niet klopt

| Symptoom | Oorzaak |
|---|---|
| Wit of zwart scherm | verkeerde `User_Setup.h`, of `TFT_BL` niet op 21 |
| Kleuren omgekeerd | wissel `ILI9341_2_DRIVER` voor `ILI9341_DRIVER` |
| Spiegelbeeld of staand | `tft.setRotation(1)` naar 3 (of 0/2) |
| "GEEN VERBINDING" | API draait niet, firewall blokkeert, of `API_HOST` is verouderd |
| Geen piepje | de CYD heeft geen luidspreker aan boord; sluit er een op de speaker-pads (IO26) aan of zet `BEEP_ENABLED` op false |
| Tik komt naast waar je drukt | zet `TOUCH_DEBUG` op 1, tik de vier hoeken aan, lees de raw-waarden in de seriële monitor en vul `TS_MINX/MAXX/MINY/MAXY` in. Staat alles gespiegeld, wissel dan `TOUCH_FLIP_X` / `TOUCH_FLIP_Y` |
| Knop doet niets | knop 3 zit op GPIO35 en heeft een externe pull-up van 10k naar 3V3 nodig; zonder die weerstand zweeft de ingang |
| "kan alleen als die sessie wacht" | de actie staat in `actions.json` op `requireAttention` en die sessie vraagt niets. Dat is expres: zo duw je nooit per ongeluk een Enter in een sessie die gewoon aan het werk is |

## De endpoints

| URL | Voor |
|---|---|
| `/cyd.txt` | de sessielijst als platte tekst |
| `/focus?id=<sessie>` | haalt dat venster naar voren (tikken) |
| `/action?id=<sessie>&b=<1-4>` | voert knopactie N uit |
| `/sessions.json` | dezelfde data als JSON |
| `/` | statuspaginaatje; tik daar ook een rij aan om het venster te halen |

`/cyd.txt` levert per regel `state|naam|sinds|waarom|sessie-id`, met een kopregel
`#aandacht|actief|klaar|klok|knoplabels`. Zo heeft de sketch geen ArduinoJson
nodig en blijft het parsen een paar `indexOf`-aanroepen.

## Een waarschuwing over de goedkeurknop

`/action` kan toetsen naar je terminal sturen, en iedereen op je netwerk kan dat
aanroepen. Twee remmen zitten er standaard op: een actie met `requireAttention`
werkt alleen als die sessie ook echt om iets vraagt, en elke actie komt in
`actions.log` te staan. Zit je op een netwerk dat je niet vertrouwt, zet dan
`token` in `actions.json` en vul dezelfde waarde in bij `API_TOKEN` in de sketch.

En bedenk wat die knop doet: hij bevestigt wat er op dat moment op je scherm
staat, ook een commando dat je liever eerst had gelezen. Wil je dat niet, zet
knop 1 dan op `"type": "focus"` — dan spring je naar het venster en beslis je
zelf.
