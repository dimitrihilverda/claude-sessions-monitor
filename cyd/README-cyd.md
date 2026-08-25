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
4. Uploaden. Werkt de upload niet, houd dan BOOT ingedrukt terwijl je start.

Wifi en het adres van je pc hoef je *niet* in de sketch te zetten; die stel je in
op het schermpje zelf. Zie de volgende paragraaf.

## 2b. Wifi instellen zonder pc

Bij de eerste start -- of als hij niet op je wifi kan komen -- zet de CYD zijn
eigen netwerk op en zet hij op het scherm wat je moet doen:

    netwerk:     Claude-Deck
    wachtwoord:  claudedeck
    daarna:      http://192.168.4.1

Verbind je telefoon daarmee. Op de meeste telefoons springt de pagina van zichzelf
open; zo niet, ga dan naar dat adres. Je kiest je netwerk uit een lijst, typt het
wachtwoord en vult het adres van je pc in. Na opslaan herstart hij en verbindt hij.

Alles wordt bewaard in NVS, het stukje flash dat een nieuwe sketch niet wist. Je
gegevens blijven dus staan als je opnieuw flasht, en er staat geen wachtwoord in
de sketch of in git.

**Later nog eens wijzigen**: houd twee seconden je vinger op de bovenbalk (waar de
tellers en de klok staan). Dat is de uitweg voor als hij wél op wifi zit maar het
pc-adres verouderd is -- dan komt het portaal namelijk nooit vanzelf. Een kórte
tik op die balk doet iets anders: die stapt de helderheid.

Rol je meerdere schermpjes uit en wil je ze niet allemaal los instellen, dan kun
je `WIFI_SSID_START`, `WIFI_PASS_START` en `API_HOST_START` bovenin de sketch
vullen. Dat zijn startwaarden: zodra er iets in NVS staat, gaat die voor. Wat je
daar neerzet komt wel in je git-geschiedenis terecht.

## 3. Als het niet klopt

| Symptoom | Oorzaak |
|---|---|
| Wit of zwart scherm | verkeerde `User_Setup.h`, of `TFT_BL` niet op 21 |
| Kleuren omgekeerd (stuur je magenta, toont hij groen) | `#define TFT_INVERSION_ON` ontbreekt in je `User_Setup.h`. Geen van de ILI9341-init-sequenties stuurt zelf een inversie-commando, dus dit paneel blijft in zijn omgekeerde opstartstand. Let op dat twee donkere tinten dan allebei als lichtbeige uitkomen, waardoor kleurwijzigingen lijken alsof er niets verandert |
| Kleuren door elkaar (blauw waar rood hoort) | dat is wél de driver: wissel `ILI9341_2_DRIVER` voor `ILI9341_DRIVER`. Meng nooit power- of gammawaarden uit een andere driver in een bestaande initvolgorde -- `0xC0`/`0xC1`/`0xC5`/`0xC7` horen bij elkaar en half overnemen ontregelt het paneel |
| Spiegelbeeld of staand | `tft.setRotation(1)` naar 3 (of 0/2) |
| "GEEN VERBINDING" | de API draait niet (start "Claude Deck API" of `api.vbs`), de firewall blokkeert, of het pc-adres is verouderd -- dat laatste zet je goed door twee seconden op de bovenbalk te drukken en het portaal te openen |
| Hij pakt je wifi niet meer (ander wachtwoord, nieuw netwerk) | hij zet dan zelf het netwerk `Claude-Deck` op; verbind je telefoon en stel hem opnieuw in. Geen USB nodig |
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
