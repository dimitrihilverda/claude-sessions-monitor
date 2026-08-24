# -*- coding: utf-8 -*-
"""
build-pakket.py -- zet het installeerbare zipje in elkaar.

    python build-pakket.py [uitvoermap]

Neemt de HUD, de gedeelde bibliotheken, de hookbeacon en de installer mee.
De dashboardpagina en alles wat met de geplande taak te maken heeft blijft
eruit: dat is persoonlijk en niet nodig om de HUD te draaien.
"""
import os, sys, zipfile, hashlib

HIER = os.path.dirname(os.path.abspath(__file__))
UIT  = sys.argv[1] if len(sys.argv) > 1 else HIER
NAAM = "ClaudeDeck"

# (bron, pad in het zipje)
BESTANDEN = [
    ("installer/Installeer.cmd", "Installeer.cmd"),
    ("installer/install.ps1",    "install.ps1"),
    ("installer/uninstall.ps1",  "uninstall.ps1"),
    ("installer/LEESMIJ.md",     "LEESMIJ.md"),
    ("installer/Diagnose.cmd",   "Diagnose.cmd"),
    ("diagnose.ps1",             "diagnose.ps1"),
    ("sessionlib.ps1",           "sessionlib.ps1"),
    ("focuslib.ps1",             "focuslib.ps1"),
    ("beacon.ps1",               "beacon.ps1"),
    ("hud.ps1",                  "hud.ps1"),
    ("hud.vbs",                  "hud.vbs"),
    ("check-titels.ps1",         "check-titels.ps1"),
    ("zoek-titel.ps1",           "zoek-titel.ps1"),
    ("session-api.ps1",          "session-api.ps1"),
    ("api.vbs",                  "api.vbs"),
    ("actions.json",             "actions.json"),
]
MAPPEN = [
    ("cyd",  "cyd"),
    ("case", "case"),
]
# hier hoeft niemand anders iets mee
OVERSLAAN = {"preview.png"}   # blijft wel in de repo, maar niet in het zipje


def voeg_toe(zf, bron, doel):
    if not os.path.exists(bron):
        print("  ! ontbreekt:", bron)
        return 0
    zf.write(bron, "%s/%s" % (NAAM, doel))
    return os.path.getsize(bron)


def main():
    zippad = os.path.join(UIT, NAAM + ".zip")
    totaal = 0
    with zipfile.ZipFile(zippad, "w", zipfile.ZIP_DEFLATED) as zf:
        for bron, doel in BESTANDEN:
            totaal += voeg_toe(zf, os.path.join(HIER, bron), doel)
        for bronmap, doelmap in MAPPEN:
            vol = os.path.join(HIER, bronmap)
            if not os.path.isdir(vol):
                print("  ! map ontbreekt:", bronmap)
                continue
            for wortel, _, files in os.walk(vol):
                for f in sorted(files):
                    if f in OVERSLAAN:
                        continue
                    p = os.path.join(wortel, f)
                    rel = os.path.relpath(p, vol).replace("\\", "/")
                    totaal += voeg_toe(zf, p, "%s/%s" % (doelmap, rel))

    with open(zippad, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    print("%s  (%.0f kB uit %.0f kB aan bestanden)"
          % (zippad, os.path.getsize(zippad) / 1024.0, totaal / 1024.0))
    print("sha256: " + sha)


if __name__ == "__main__":
    main()
