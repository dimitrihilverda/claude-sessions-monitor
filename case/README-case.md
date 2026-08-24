# Claude-deck — printbare behuizing voor de CYD met drie toetsen

Twee varianten, allebei uit hetzelfde script. Kies er één:

| | **deck-plat** | **deck-compact** |
|---|---|---|
| buitenmaat | 94,5 × 103,8 × **29,4** mm | 94,5 × 89,1 × 50,1 mm |
| hellingshoek | 9° | 26° |
| voorrand | 14,6 mm | 9,2 mm |
| achterkant | 20° uit het lood, loopt weg | 6°, vrijwel recht |
| karakter | vlak plankje, blijft laag in beeld | duidelijke wig, kleinere voetafdruk |

De wisselwerking zit vast in de meetkunde: hetzelfde bedieningsvlak van ruim
9 cm moet ergens heen. Zet je het vlakker, dan wordt de behuizing lager maar
dieper; zet je het steiler, dan wordt hij korter maar hoger. Onder de 30 mm
komen betekende dus 15 mm extra diepte.

En nog iets waar de vlakke variant tegenaan liep: bij een lage hoek wordt de
voorkant van de behuizing dun, terwijl een MX-schakelaar zo'n 14 mm achter de
plaat nodig heeft. Het script rekent de voorrand daarom uit vanuit je
schakelaartype — vandaar dat de vlakke variant een voorrand van 11,5 mm heeft
en de compacte maar 6,7 mm. Wil je hem écht dun, zet `SWITCH = "CHOC"`
bovenin: Kailh low-profile heeft maar 7 mm nodig en dan kan de voorrand naar
ongeveer 4 mm.

| Bestand | Wat |
|---|---|
| `deck-plat-shell-print.stl` | de behuizing, al goed gedraaid voor de printer |
| `deck-plat-shell.stl` | dezelfde, rechtop (handig om te bekijken) |
| `deck-plat-bodem.stl` | de grondplaat — **1×** |
| `deck-plat-brace.stl` | klembalkje dat de print vasthoudt — **1×** |
| `deck-compact-*.stl` | idem voor de steilere variant |
| `make_case.py` | de generator; alle maten staan bovenin |
| `preview.png` | aanzichten, onderkant, losse delen en een doorsnede |

## De grondplaat

De onderranden zijn bewust níet afgerond: de plaat sluit vlak aan. Hij valt in
de onderkant, verdwijnt helemaal in de behuizing (de hoogte blijft dus 29,4 mm)
en schroeft met vier M3-schroeven vast in vier klossen in de hoeken. De
schroefkoppen zijn verzonken, dus de onderkant blijft vlak.

Plaatmaat: 89,0 × 98,2 × 2,5 mm. Speling rondom is 0,35 mm; schuurt hij, verhoog
dan `PLATE_CLR` en draai het script opnieuw.

Ik heb geen klik-verbinding gemaakt maar schroeven, en dat is een keuze: een
snapverbinding over zo'n grote omtrek moet je inpassen met proefprints, en dat
kan ik hier niet doen. Schroeven werken de eerste keer.

Let op de wisselwerking die dit oplevert: een dichte bodem kost hoogte, want de
MX-schakelaars steken aan de voorkant naar beneden en moeten nu boven de
grondplaat blijven. Daarom is de vlakke variant van 11° naar 9° gegaan. Met
`SWITCH = "CHOC"` verdwijnt dat probleem — die hebben maar 7 mm nodig.

## Hoe de print vastzit

Bovenaan zitten twee vaste haakjes: daar schuif je de bovenrand van de CYD
onder. Onderaan klem je hem met één balkje op twee pilaren. Dat scheelde
schroefpilaren boven het scherm, en dat is precies waarom de behuizing korter
kon dan de eerste versie.

Rondom het schermgat zit een afschuining van 45° en alle buitenranden zijn
afgerond (3 mm op het zijprofiel, 6 mm op de staande hoeken).

## Voordat je print: even nameten

De CYD-maten komen uit de datasheets van de gangbare ESP32-2432S028R, maar er
zijn varianten. Pak een schuifmaat en controleer `PCB_W`, `PCB_H`, `SCREEN_W`,
`SCREEN_H`, waar het glas op de print zit (`SCREEN_OFF_U/V`) en op welke hoogte
de USB-connector op de linkerrand zit (`USB_V`). Ook `PCB_BACK` is een schatting:
hoeveel ruimte de onderdelen op de achterkant nodig hebben. Aanpassen en opnieuw
draaien:

    pip install trimesh manifold3d shapely
    python make_case.py

Het script meldt per variant de hoogte en de twee krappe plekken: de ruimte
onder de toetsen en de ruimte achter de bovenrand van de print. Staat daar geen
"LET OP", dan past het.

**Print eerst alleen de onderste 5 mm** van het `-print.stl` (in je slicer
afkappen). Tien minuten werk, en je weet of het schermgat en de drie toetsgaten
kloppen voordat je uren gaat printen.

## Printinstellingen

PLA of PETG, laagje 0,2 mm, 3 wanden, 15–20 % vulling, **geen support**: in het
`-print.stl` ligt het bedieningsvlak plat op het bed en print de rest zichzelf.
Een brim helpt tegen loslaten.

## Wat je erbij nodig hebt

- 3× MX-schakelaar (of Choc, als je `SWITCH` omzet) + keycaps
- 6× zelftappende schroef M3 × 10 — twee voor het klembalkje, vier voor de
  grondplaat (de voorgaten zijn 2,6 mm en snijden hun eigen draad)
- 1× weerstand 10 kΩ
- dun draad, en bij voorkeur twee JST 1.25 mm 4-pins pigtails

## Bedrading

Elke schakelaar met één pootje naar GND, het andere naar een GPIO:

| Knop | GPIO | Bijzonderheid |
|---|---|---|
| 1 | 22 | interne pull-up, verder niets nodig |
| 2 | 27 | interne pull-up, verder niets nodig |
| 3 | 35 | **input-only, geen interne pull-up**: 10 kΩ tussen pin 35 en 3V3 |
| 4 | 0 | de BOOT-knop van de CYD zelf, hoef je niet te bedraden |

De twee 4-pins JST-connectoren dragen op de gangbare uitvoering
GND/IO35/IO22/IO21 en GND/IO22/IO27/3V3. Er lopen meerdere versies rond, dus
meet even door voordat je soldeert. IO21 is de achtergrondverlichting — daar
moet je vanaf blijven.

## In elkaar zetten

1. Schakelaars solderen en in de drie gaten klikken (de plaat is daar 1,5 mm).
2. Draden naar de connectoren, kabel naar de linkerzijkant.
3. Bovenrand van de CYD onder de twee haakjes schuiven, daarna de onderkant
   in de uitsparing laten zakken.
4. Het klembalkje over de onderrand leggen — opstaand randje naar de print toe —
   en vastschroeven. Niet te strak.
5. USB-kabel door de sleuf in de linkerwand.
6. Grondplaat erin leggen en met vier schroeven vastzetten. Vier rubber dopjes
   eronder en hij schuift niet meer weg.
