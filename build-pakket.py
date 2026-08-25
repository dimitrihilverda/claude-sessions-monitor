# -*- coding: utf-8 -*-
"""
build-pakket.py -- assembles the installable zip.

    python build-pakket.py [output-dir]

Includes the HUD, the shared libraries, the hook beacon and the installer.
Anything personal stays out: the dashboard page and the generated session data
are not needed to run the HUD, and would leak your prompts.
"""
import os, sys, zipfile, hashlib

HIER = os.path.dirname(os.path.abspath(__file__))
UIT  = sys.argv[1] if len(sys.argv) > 1 else HIER
NAAM = "ClaudeDeck"

# (source, path inside the zip)
BESTANDEN = [
    ("installer/Install.cmd",     "Install.cmd"),
    ("installer/install.ps1",    "install.ps1"),
    ("installer/uninstall.ps1",  "uninstall.ps1"),
    ("installer/README-installer.md", "README-installer.md"),
    ("installer/Diagnose.cmd",   "Diagnose.cmd"),
    ("diagnose.ps1",             "diagnose.ps1"),
    ("sessionlib.ps1",           "sessionlib.ps1"),
    ("focuslib.ps1",             "focuslib.ps1"),
    ("langlib.ps1",              "langlib.ps1"),
    ("beacon.ps1",               "beacon.ps1"),
    ("hud.ps1",                  "hud.ps1"),
    ("hud.vbs",                  "hud.vbs"),
    ("check-titles.ps1",         "check-titles.ps1"),
    ("find-title.ps1",           "find-title.ps1"),
    ("session-api.ps1",          "session-api.ps1"),
    ("api.vbs",                  "api.vbs"),
    ("actions.json",             "actions.json"),
]
MAPPEN = [
    ("cyd",  "cyd"),
    ("case", "case"),
]
# nobody else needs this
OVERSLAAN = {"preview.png"}   # stays in the repo, but not in the zip


def voeg_toe(zf, bron, doel):
    if not os.path.exists(bron):
        print("  ! missing:", bron)
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
                print("  ! folder missing:", bronmap)
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
    print("%s  (%.0f kB from %.0f kB of files)"
          % (zippad, os.path.getsize(zippad) / 1024.0, totaal / 1024.0))
    print("sha256: " + sha)


if __name__ == "__main__":
    main()
