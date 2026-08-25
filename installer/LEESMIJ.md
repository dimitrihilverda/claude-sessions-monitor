# Claude Deck

Zie in een klein venster welke Claude Code-sessies er draaien, waar ze mee bezig
zijn en welke op jou wacht. Altijd bovenop, klik op een sessie om naar dat
venster te springen.

Optioneel kun je er een goedkoop touchscreen (een "Cheap Yellow Display" op een
ESP32) aan hangen, met drie mechanische toetsen om te reageren zonder je muis.

## Installeren

Dubbelklik **`Installeer.cmd`**. Er worden drie dingen gevraagd: waar het
mag komen, of je het touchscreen wilt gebruiken en of alles bij inloggen moet
starten. Administratorrechten zijn niet nodig.

Standaard komt alles in `%LOCALAPPDATA%\ClaudeDeck`.

Wat de installatie doet:

- de bestanden neerzetten
- de hooks van Claude Code koppelen in `%USERPROFILE%\.claude\settings.json`
  (met een backup, en bestaande verwijzingen naar een oudere versie worden
  bijgewerkt in plaats van verdubbeld)
- snelkoppelingen maken in het startmenu, en bij "starten bij inloggen" ook in
  je Startup-map -- de webservice voor het touchscreen komt daar mee, want zonder
  die service staat het schermpje op "GEEN VERBINDING"
- de HUD starten, en de webservice erbij als je het touchscreen koos

Sessies die al draaien pikken de hooks pas op na een herstart van die sessie.

## Gebruiken

| Actie | Wat het doet |
|---|---|
| Slepen | het venster verplaatsen; de positie wordt onthouden |
| Klik op een rij | het venster van die sessie naar voren halen |
| Shift + klik | de projectmap openen in Verkenner |
| Ctrl + klik | laten zien welke vensters gevonden zijn en met welke score |
| Rechtermuis | menu: altijd bovenop, compacte rijen, alleen aandacht nodig, herstarten, afsluiten |
| Dubbelklik tray-icoon | HUD verbergen of terugtoveren |
| Esc / F5 | verbergen / nu verversen |

Kleuren: **oranje** betekent dat Claude iets van je wil (permissie of invoer),
**groen** dat hij aan het werk is, **grijsblauw** dat hij klaar is. Alleen
oranje geeft een piepje en een melding.

Een sessie verdwijnt zodra het Claude-proces weg is, ook als je de terminal hard
hebt afgesloten.

## Het touchscreen

Kies je daarvoor, dan komt er een webservice mee. Die start meteen na de
installatie, en met "starten bij inloggen" ook bij elke herstart van je pc.
Handmatig starten kan via "Claude Deck API" in je startmenu. Windows Firewall
vraagt de eerste keer om toestemming (kies prive-netwerken). Op je telefoon of tablet kun je dan naar
`http://<ip-van-je-pc>:8787/` voor dezelfde lijst.

Voor het echte schermpje: bouwinstructies, de Arduino-sketch en een printbare
behuizing staan in `cyd\` en `case\`. Wat de drie fysieke toetsen doen bepaal
je in `actions.json` — dat leest de service bij elke druk opnieuw, dus omzetten
kan zonder opnieuw te flashen.

## De HUD laat niets zien

Dat is bijna altijd hetzelfde: **hooks worden ingelezen als een sessie start**,
niet daarna. Alles wat al draaide toen je installeerde, meldt zich niet.

- **Terminal**: sluit die Claude Code-sessies af en start een nieuwe.
- **Desktop-app**: sluit Claude helemaal af, ook uit het systeemvak naast de
  klok, en start hem opnieuw. Een nieuwe chat openen in een app die al draaide
  is niet genoeg — die gebruikt nog de instellingen van toen de app startte.

Geef daarna een opdracht en de HUD vult zich.

Blijft het leeg, dubbelklik dan **`Diagnose.cmd`**. Die loopt de hele keten na —
bestanden, hooks in `settings.json`, een echte proefaanroep van de beacon, de
statusbestanden en de HUD zelf — en zegt waar het misgaat. Twee dingen die hij
vaak vindt: het filter "alleen aandacht nodig" dat aan staat, of hooks die nog
naar een oude installatiemap wijzen.

## Als een naam niet klopt

De naam van een sessie komt uit het transcript van Claude Code: eerst een naam
die je zelf hebt gegeven, anders de titel die Claude Code bijhoudt, anders de
eerste opdracht, anders de mapnaam.

```
powershell -ExecutionPolicy Bypass -File check-titels.ps1
```

laat per sessie zien welke bron gebruikt wordt.

## Verwijderen

```
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

Dat haalt de hooks uit `settings.json` (met backup), verwijdert de
snelkoppelingen en vraagt of de map ook weg mag.

## Wat het niet doet

Er gaat niets naar buiten. De sessiestand komt uit de hooks van Claude Code en
blijft op je eigen machine; de webservice voor het touchscreen luistert alleen
op je lokale netwerk en staat standaard uit.

Let wel op met de knop "goedkeuren" op het touchscreen: die bevestigt wat er op
dat moment op je scherm staat. Iedereen op je netwerk kan die webservice
aanroepen, dus zet er een `token` in `actions.json` bij als je het netwerk niet
vertrouwt.
