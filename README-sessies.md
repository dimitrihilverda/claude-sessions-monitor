# Dashboard · Claude-sessies in beeld

Deze map (`C:\Users\dimx\claude-sessions\dashboard\`) hoort bij je persoonlijke
dashboard. De geplande taak "Dashboard verversen (Dimmy)" schrijft hier elk uur
(ma–vr 07:00–19:00) een verse `dashboard.html` naartoe.

Er zijn nu drie manieren om je Claude-sessies te zien. Ze delen dezelfde data en
dezelfde logica (`sessionlib.ps1`), dus ze spreken elkaar nooit tegen:

| Waar | Bestand | Waarvoor |
|---|---|---|
| Webpagina / achtergrond | `dashboard.html` | agenda, inbox en sessies op één plek |
| Floating HUD op Windows | `hud.ps1` + `hud.vbs` | altijd bovenop, alleen de sessies |
| Cheap Yellow Display | `session-api.ps1` + `cyd\` | fysiek bordje met touch en drie toetsen |

Tip: staat deze map in je git-repo in de weg? Voeg `dashboard/` toe aan je
`.gitignore`.

## 1 · De beacon: waar de sessiedata vandaan komt

Elke lokale Claude Code-sessie meldt zichzelf via hooks. Bij start, bij elke
opdracht, wanneer Claude om aandacht vraagt en bij afronden schrijft
`beacon.ps1` een statusbestandje naar `session-status\` en bundelt alles in
`sessions.json` (voor de HUD en de CYD) en `sessions.js` (voor de webpagina).

### Hoe een sessie heet

Claude Code schrijft de naam van een sessie als losse regels in het transcript,
en de hook stuurt het pad van dat transcript mee. Er zijn drie soorten, en de
beacon neemt van elk de laatste:

| Regeltype | Wat het is |
|---|---|
| `custom-title` | de naam die je zelf hebt gegeven met de rename-functie — wint altijd |
| `ai-title` | de titel die Claude Code zelf bijhoudt en tijdens het werk blijft bijwerken |
| `summary` | de samenvatting na een `/compact` of bij het hervatten van een sessie |

Het veld waarin die tekst staat kan per versie van Claude Code verschillen, dus
de beacon pakt het eerste veld met een niet-lege tekst uit `title`,
`customTitle`, `aiTitle`, `name`, `text`, `value`, `content` of `summary`.
Verandert dat in een toekomstige versie, dan is het één regel bijwerken in
`$velden` in `sessionlib.ps1`.

Levert dat allemaal niets op, dan is de volgorde: de tabtitel van de terminal
(alleen bij een echte terminal — een IDE houdt die tabnaam binnen zijn eigen
vensters), dan de eerste opdracht uit het gesprek afgekapt op 34 tekens, en
anders de mapnaam. Cowork-sessies hangen aan een venster dat altijd "Claude"
heet; die krijgen `Cowork · <map>`.

De titel wordt één keer opgezocht en bewaard in het beacon-bestandje. Bij elke
`Stop` kijkt de beacon opnieuw, want dan kan er net een nieuwe `ai-title` of een
rename bij zijn gekomen.

Hebben twee zichtbare sessies dezelfde naam, dan komt er een stukje van hun
session_id achter zodat je ze uit elkaar houdt. De map staat in de tweede regel,
samen met het tijdstip en waar Claude mee bezig is.

Twee hulpscripts als een naam je niet bevalt:

```
powershell -ExecutionPolicy Bypass -File check-titels.ps1
powershell -ExecutionPolicy Bypass -File zoek-titel.ps1 -SessionId <id>
```

De eerste laat per sessie zien welke bron gebruikt wordt. De tweede dumpt de
titelregels uit een transcript en laat zien wat het dashboard daarvan maakt.

### Statussen

| Laatste hook-event | Status | Kleur |
|---|---|---|
| `Notification` | **Aandacht nodig** — Claude vraagt permissie of input | oranje |
| `SessionStart` / `UserPromptSubmit` / `PostToolUse` | Actief — Claude is aan het werk | groen |
| `Stop` | Klaar — het antwoord staat er, jouw beurt | grijsblauw |
| `SessionEnd`, of het Claude-proces is weg | verdwijnt meteen | — |

**Alleen oranje is een alarm.** `Stop` betekent in Claude Code "klaar met
antwoorden", niet "er wacht iets op je"; dat stond eerder verkeerd in het
dashboard en zorgde ervoor dat elke afgeronde sessie oranje ging piepen.

### Waarom "aandacht nodig" nu weer weggaat

Tussen `Notification` (Claude vraagt permissie) en de volgende `Stop` vuurt
Claude Code geen enkele hook. Keurde je een permissievraag goed, dan bleef de
sessie dus oranje staan terwijl Claude allang weer aan het werk was.

Daarom staat `PostToolUse` nu ook in de hooks: die vuurt bij elke tool-aanroep
en zet de sessie op "Actief" zodra het werk verdergaat. Om te voorkomen dat dat
elke tool-aanroep vertraagt, stapt `beacon.ps1` er meteen weer uit als de sessie
al binnen de laatste 20 seconden op "Actief" stond — alleen de overgang en een
hartslag elke 20 seconden kosten echt werk. Die hartslag houdt bovendien de
`updated`-tijd fris, wat de TTL ten goede komt.

Heb je de hooks eerder geïnstalleerd, draai `install-hooks.ps1` dan opnieuw:
`PostToolUse` wordt er dan bijgezet, de rest blijft staan.

### Waarom oude sessies nu echt verdwijnen

`SessionEnd` gaat niet altijd af: sla je een terminal hard dicht, crasht er iets,
of doe je `/clear` (nieuwe session_id in dezelfde map), dan bleef er een
`SessionStart` achter die een uur lang als "Actief" in beeld stond.

De beacon legt daarom nu de **PID van het Claude-proces** vast (plus de
starttijd, tegen hergebruikte PID's). Bij het inlezen wordt gecontroleerd of dat
proces nog bestaat; zo niet, dan gaat het beacon-bestand direct weg. Dubbelingen
per Claude-proces worden samengevoegd: alleen de nieuwste blijft over. De TTL van
45 minuten (`$DashMaxAgeMinutes` in `sessionlib.ps1`) is nog maar een vangnet
voor oude beacons zonder PID.

`$DashHideCwds` in `sessionlib.ps1` is standaard leeg: je ziet alles, ook de
Cowork-sessie waarin je met Claude aan dit dashboard werkt. Wil je een map toch
wegfilteren, zet het volledige pad daar neer.

### Installeren (eenmalig)

```
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\dimx\claude-sessions\dashboard\install-hooks.ps1"
```

Het script maakt een backup van je `settings.json`, voegt de vijf hook-events toe
(idempotent) en laat zien wat het gedaan heeft. Handmatig kan ook: het blok staat
in `claude-hooks-snippet.json`. Hooks gelden voor sessies die je daarna start.

Controleren: start een sessie, geef een opdracht, en kijk of er een `.json` in
`session-status\` verschijnt.

## 2 · De floating HUD (aanrader)

Klein venstertje dat altijd bovenop blijft, met alleen je sessies.

Starten zonder dat er een PowerShell-venster opflitst — dubbelklik:

```
hud.vbs
```

Testen met foutmeldingen in beeld:

```
powershell -ExecutionPolicy Bypass -File hud.ps1
```

| Actie | Wat het doet |
|---|---|
| Slepen met links | venster verplaatsen (positie wordt bewaard in `hud-config.json`) |
| Klik op een rij | haalt het venster van die sessie naar voren |
| Shift + klik | opent de projectmap in Verkenner |
| Ctrl + klik | laat zien welke vensters de HUD vond en met welke score — voor als hij het verkeerde venster pakt |
| Rechtermuis | menu: altijd bovenop, compacte rijen, alleen aandacht nodig, dashboard openen, starten bij inloggen, herstarten, afsluiten |
| Dubbelklik op het tray-icoon | HUD verbergen of terugtoveren |
| Esc / F5 | verbergen / nu verversen |

Het tray-icoon is groen als alles draait en oranje zodra een sessie op je wacht.
Bij een nieuwe oranje sessie klinkt er een piepje en komt er een ballontip.

### Welk venster hoort bij een sessie?

Alleen de ouderketen van het Claude-proces aflopen is niet genoeg. Bij *attach
project* delen twee PhpStorm-projecten één proces, en dan geeft Windows een
willekeurig van de twee vensters terug. En is de tussenliggende shell al
afgesloten, dan wijst de ouder-PID naar een hergebruikt proces — dus naar een
willekeurig ander venster.

De HUD scoort daarom alle zichtbare vensters:

| Punten | Waarvoor |
|---|---|
| +100 | het venster hoort bij een proces uit de ouderketen (met controle op starttijd, tegen hergebruikte PID's) |
| +45 | het volledige pad van de sessie staat in de venstertitel |
| +30 | de projectnaam staat in de venstertitel |
| +10 | het proces is een IDE of terminal (`$DashHostProcs` in `hud.ps1`) |

Het hoogste boven de 30 wint; is er niets, dan opent hij de projectmap. Zo wint
binnen één PhpStorm-proces het venster met de juiste projectnaam in de titel.
Pakt hij er alsnog naast, gebruik dan Ctrl+klik: je ziet dan alle titels met hun
score en dat is meestal genoeg om `$DashHostProcs` of de weging bij te stellen.

De HUD leest de beacons zelf elke 3 seconden, dus hij is actueler dan de
webpagina, en hij werkt de payload voor het dashboard en de CYD bij (alleen als
er echt iets veranderd is). Wil je dat niet, zet `$WritePayload = $false`
bovenin `hud.ps1`.

Hertekenen gebeurt alleen als er echt iets verandert; wisselt alleen de klok,
dan wordt uitsluitend de kopregel bijgewerkt. Samen met `DoubleBuffered` en
`WS_EX_COMPOSITED` is dat het einde van het geflikker dat de eerste versie had.

## 3 · De Cheap Yellow Display

De CYD haalt de stand elke 3 seconden op bij je pc. Op de pc:

```
powershell -ExecutionPolicy Bypass -File session-api.ps1     (of: dubbelklik api.vbs)
```

Endpoints op poort 8787:

| URL | Voor |
|---|---|
| `/cyd.txt` | de ESP32 — platte tekst, geen ArduinoJson nodig |
| `/sessions.json` | dezelfde data als JSON |
| `/` | piepklein statuspaginaatje, ook prima op je telefoon |

De eerste keer vraagt Windows Firewall om toestemming: kies **prive-netwerken
toestaan**. Flashen van de CYD en het oplossen van scherm-eigenaardigheden staat
in `cyd\README-cyd.md`; de printbare behuizing met drie MX-toetsen in
`case\README-case.md`.

### Tikken en knoppen

Tik je op een rij, dan stuurt de CYD `/focus?id=<sessie>` en haalt je pc het
venster van die sessie naar voren — dezelfde vensterzoeker als in de HUD, want
die zit in `focuslib.ps1` en wordt door allebei gebruikt.

De drie fysieke knoppen sturen `/action?id=<sessie>&b=<nummer>`. Wat dat
betekent staat in **`actions.json`** op je pc, niet in de sketch:

| Type | Wat het doet |
|---|---|
| `focus` | venster van de sessie naar voren halen |
| `keys` | venster halen en toetsen sturen (`{ENTER}`, `{ESC}`, `^c`, ...) |
| `snooze` | die sessie een aantal minuten stil zetten: geen oranje, geen piepje |
| `run` | programma of commando starten (`{cwd}` wordt de map van de sessie) |
| `open` | map, bestand of url openen |

Standaard: knop 1 keurt goed, knop 2 weigert, knop 3 snoozet 10 minuten, en de
BOOT-knop van de CYD springt als knop 4 naar het venster. De labels onder in het
CYD-scherm komen uit hetzelfde bestand, dus na een wijziging hoef je niet te
flashen — alleen de API leest opnieuw.

Twee remmen op de goedkeurknop: `requireAttention` zorgt dat toetsen alleen
worden gestuurd als die sessie ook echt iets vraagt, en alles komt in
`actions.log`. Zit je op een onvertrouwd netwerk, zet dan `token` in
`actions.json` en dezelfde waarde bij `API_TOKEN` in de sketch.

## 4 · Dashboard als live achtergrond

`dashboard.html` herlaadt zichzelf elke 5 minuten.

**Los venster zonder browserbalken** — snelkoppeling met als doel:

```
msedge --app=file:///C:/Users/dimx/claude-sessions/dashboard/dashboard.html
```

**Echt bureaubladbehang** — [Lively Wallpaper](https://apps.microsoft.com/detail/9NTM2QC6QWS7)
(gratis, Microsoft Store), "+ Add Wallpaper", wijs `dashboard.html` aan.

Let op: als achtergrond zie je de oranje banner wel, maar hoor je meestal niets
en kun je niet klikken. Daar zijn de HUD, de Windows-toast en de CYD je echte
melding.

## 5 · Windows-meldingen

| Event | Melding |
|---|---|
| `Notification` | altijd: "Claude wacht op je: `<map>`" met de reden erbij |
| `Stop` | alleen als de run langer dan 60 seconden duurde |

Bovenin `beacon.ps1` staan de knoppen: `$ToastEnabled = $false` zet alles uit,
`$ToastStopMinSeconds` bepaalt vanaf welke duur een afgeronde run een melding
waard is. Dit is puur de toast — in het dashboard, de HUD en op de CYD blijft
`Stop` een rustige "Klaar".

## 6 · Wat je hiermee wél en niet ziet

Wél: al je lokale Claude Code-sessies op deze laptop, met wat ze doen en of ze
aandacht nodig hebben. Niet: Cowork-cloudsessies — die draaien in afgesloten
omgevingen zonder API om ze account-breed op te sommen.

De uurlijkse verversing van agenda en inbox draait als geplande taak in je
Claude-app en heeft de desktop-app open nodig. De sessies hebben dat niet nodig:
die komen van de beacon, de HUD en de API op je eigen machine.

## 7 · Bestanden in deze map

| Bestand | Wat het is |
|---|---|
| `sessionlib.ps1` | gedeelde sessielogica (statussen, PID-check, snooze, payload) |
| `focuslib.ps1` | welk venster hoort bij welke sessie, en hoe je het naar voren haalt |
| `beacon.ps1` | wordt door de Claude Code-hooks aangeroepen |
| `install-hooks.ps1` | zet de hooks in je `settings.json` |
| `hud.ps1` / `hud.vbs` | de floating HUD en zijn stille starter |
| `hud-config.json` | positie en voorkeuren van de HUD (wordt zelf aangemaakt) |
| `session-api.ps1` / `api.vbs` | webservice voor de CYD en je telefoon |
| `actions.json` | wat de knoppen op de CYD doen |
| `actions.log` | wat er is uitgevoerd, met tijdstip |
| `snooze.json` | welke sessies tijdelijk stil staan |
| `cyd\` | Arduino-sketch, TFT-instellingen en flash-instructies |
| `case\` | printbare behuizing: STL's, generator en bouwbeschrijving |
| `dashboard.html` | de pagina met agenda, inbox en sessies |
| `sessions.json` / `sessions.js` | de huidige stand, door de beacon geschreven |
| `session-status\` | één bestandje per sessie |
