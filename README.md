# Claude-deck

Zie in één oogopslag waar je lokale Claude Code-sessies mee bezig zijn, en of er
eentje op je wacht. Drie weergaven, één gedeelde bron van waarheid:

| Waar | Wat |
|---|---|
| **Floating HUD** op Windows | klein venster dat altijd bovenop blijft, met alleen de sessies |
| **Cheap Yellow Display** | fysiek bordje met touch en drie mechanische toetsen |
| **Dashboardpagina** | agenda, werk-inbox en sessies, ook bruikbaar als bureaubladachtergrond |

Alles draait lokaal op je eigen machine. Er gaat niets naar buiten: de sessies
komen uit de hooks van Claude Code, agenda en inbox uit je eigen Outlook.

## Hoe het werkt

Claude Code roept bij elke gebeurtenis `beacon.ps1` aan. Die schrijft per sessie
een klein statusbestandje en bundelt alles in `sessions.json`. De HUD, de
webpagina en de CYD lezen daar dezelfde stand uit, via twee gedeelde
bibliotheken:

- `sessionlib.ps1` — statussen, opruimen van dode sessies, snooze, payload
- `focuslib.ps1` — welk venster hoort bij welke sessie, en hoe je het naar voren haalt

### Statussen

| Hook-event | Status | Kleur |
|---|---|---|
| `Notification` | **Aandacht nodig** — Claude vraagt permissie of input | oranje |
| `SessionStart` / `UserPromptSubmit` / `PostToolUse` | Actief | groen |
| `Stop` | Klaar — het antwoord staat er | grijsblauw |
| `SessionEnd`, of het proces is weg | verdwijnt meteen | — |

Alleen oranje is een alarm. Twee dingen die daarbij belangrijk bleken: de beacon
legt de PID van het Claude-proces vast, zodat een sessie waarvan de terminal hard
is afgesloten meteen verdwijnt in plaats van een uur als "actief" te blijven
staan. En `PostToolUse` haalt een sessie uit de oranje stand zodra het werk na
een goedgekeurde permissievraag verdergaat — zonder die hook vuurt Claude Code
tussen `Notification` en `Stop` namelijk niets.

## Aan de slag

Voor anderen is er een installeerbaar pakket: bouw het met

```
python build-pakket.py
```

Dat levert `ClaudeDeck.zip` op met alleen wat nodig is om de HUD te draaien —
zonder de dashboardpagina en zonder de geplande taak. Uitpakken en
`Installeer.cmd` dubbelklikken; de installer zet de bestanden neer, koppelt de
hooks, maakt snelkoppelingen en start de HUD. Zie
[installer/LEESMIJ.md](installer/LEESMIJ.md).

Op deze machine zelf, vanuit deze map:

```powershell
# 1. hooks installeren (eenmalig)
powershell -ExecutionPolicy Bypass -File install-hooks.ps1

# 2. de HUD starten
wscript.exe hud.vbs

# 3. optioneel: de webservice voor de CYD en je telefoon
wscript.exe api.vbs
```

Uitgebreide uitleg staat in **[README-sessies.md](README-sessies.md)**.

## Mappen

| Pad | Wat |
|---|---|
| `beacon.ps1`, `install-hooks.ps1` | de hooks die de sessiestand bijhouden |
| `sessionlib.ps1`, `focuslib.ps1` | gedeelde logica |
| `hud.ps1`, `hud.vbs` | de floating HUD |
| `session-api.ps1`, `api.vbs`, `actions.json` | webservice + wat de fysieke knoppen doen |
| `cyd/` | Arduino-sketch voor de ESP32-2432S028R, TFT-instellingen, flash-instructies |
| `case/` | printbare behuizing: STL's, parametrische generator, bouwbeschrijving |
| `installer/` | installatiepakket voor andere machines |
| `build-pakket.py` | zet `ClaudeDeck.zip` in elkaar |
| `README-sessies.md` | de volledige handleiding |

## Wat er bewust niet in staat

`dashboard.html`, `sessions.json`, `session-status/` en `actions.log` worden
gegenereerd en bevatten je agenda, je inbox en de prompts van je sessies. Die
staan in `.gitignore`. De pagina wordt elk uur opnieuw opgebouwd door een
geplande taak.

## Randvoorwaarden

Windows met PowerShell 5.1 (standaard aanwezig), Claude Code met hooks. Voor de
CYD: Arduino IDE met TFT_eSPI en XPT2046_Touchscreen. Voor het aanpassen van de
behuizing: Python met trimesh, manifold3d en shapely.
