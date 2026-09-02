# -*- coding: utf-8 -*-
"""
build-pakket.py -- assembles the installable zip.

    python build-pakket.py [output-dir]

Includes the HUD, the shared libraries, the hook beacon and the installer.
Anything personal stays out: the dashboard page and the generated session data
are not needed to run the HUD, and would leak your prompts.
"""
import os, re, sys, zipfile, hashlib

HIER = os.path.dirname(os.path.abspath(__file__))
UIT  = sys.argv[1] if len(sys.argv) > 1 else HIER
NAAM = "ClaudeDeck"

# (source, path inside the zip[, executable])
BESTANDEN = [
    ("installer/Install.cmd",     "Install.cmd"),
    ("installer/Install.command", "Install.command", True),
    ("installer/install.ps1",    "install.ps1"),
    ("installer/uninstall.ps1",  "uninstall.ps1"),
    ("installer/README-installer.md", "README-installer.md"),
    ("installer/Diagnose.cmd",   "Diagnose.cmd"),
    ("diagnose.ps1",             "diagnose.ps1"),
    ("selftest.ps1",             "selftest.ps1"),
    ("platformlib.ps1",          "platformlib.ps1"),
    ("sessionlib.ps1",           "sessionlib.ps1"),
    ("focuslib.ps1",             "focuslib.ps1"),
    ("langlib.ps1",              "langlib.ps1"),
    ("updatelib.ps1",            "updatelib.ps1"),
    ("install-hooks.ps1",        "install-hooks.ps1"),
    ("VERSION",                  "VERSION"),
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
    # The macOS window is built on the machine it runs on -- swiftc out of the
    # Command Line Tools, no Xcode -- so what ships is the source and build.sh,
    # not a bundle. Install.command looks for this folder and offers to build it;
    # without it here that offer is a permanent "not in this package".
    ("hud-macos", "hud-macos"),
]
# nobody else needs this
OVERSLAAN = {"preview.png", ".gitignore"}  # stay in the repo, not in the zip
OVERSLAAN_MAPPEN = {"build", "build-s3", "__pycache__"}


def voeg_toe(zf, bron, doel, uitvoerbaar=False):
    if not os.path.exists(bron):
        print("  ! missing:", bron)
        return 0
    naam = "%s/%s" % (NAAM, doel)
    if uitvoerbaar:
        # Install.command has to be double-clickable straight out of the zip,
        # and build.sh has to be runnable; that is the execute bit. zf.write
        # cannot carry it over from a Windows checkout, where the file has no
        # such bit to begin with, so
        # we set it on the entry by hand: 0o100755 is "regular file, rwxr-xr-x".
        info = zipfile.ZipInfo.from_file(bron, naam)
        info.external_attr = 0o100755 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        with open(bron, "rb") as fh:
            zf.writestr(info, fh.read())
    else:
        zf.write(bron, naam)
    return os.path.getsize(bron)


# A script's own dot-source lines: ". (Join-Path $Root 'platformlib.ps1')",
# indented or not, whichever variable holds the folder.
DOTSOURCE = re.compile(r"^\s*\.\s+\(Join-Path\s+\$\w+\s+'([^']+\.ps1)'\)", re.M)


def ontbrekende_afhankelijkheden(zf):
    """Which scripts does the package load that the package does not contain?

    BESTANDEN is written by hand, and a hand-written list drifts. platformlib.ps1
    arrived with the macOS work and nobody added it: the zip built, installed and
    passed its file check, and then session-api.ps1 died on its first line. Nobody
    has to remember anything if we read the dot-source lines back out of what we
    just packed.
    """
    def binnen(naam):
        # Written on Windows the entries can carry backslashes; compare on one form.
        return naam.replace("\\", "/").split("/", 1)[-1]

    namen = set(binnen(i.filename) for i in zf.infolist())
    tekort = []
    for info in sorted(zf.infolist(), key=lambda i: i.filename):
        naam = binnen(info.filename)
        if not naam.endswith(".ps1"):
            continue
        with zf.open(info) as fh:
            tekst = fh.read().decode("utf-8", "replace")
        for nodig in DOTSOURCE.findall(tekst):
            if nodig not in namen:
                tekort.append("%s loads %s, which is not in the package" % (naam, nodig))
    return tekort


def main():
    zippad = os.path.join(UIT, NAAM + ".zip")
    totaal = 0
    with zipfile.ZipFile(zippad, "w", zipfile.ZIP_DEFLATED) as zf:
        for regel in BESTANDEN:
            bron, doel = regel[0], regel[1]
            uitvoerbaar = len(regel) > 2 and regel[2]
            totaal += voeg_toe(zf, os.path.join(HIER, bron), doel, uitvoerbaar)
        for bronmap, doelmap in MAPPEN:
            vol = os.path.join(HIER, bronmap)
            if not os.path.isdir(vol):
                print("  ! folder missing:", bronmap)
                continue
            for wortel, mappen, files in os.walk(vol):
                # A local checkout has compiler output sitting next to the sketch.
                # CI never sees it, so nobody noticed the zip was forty times its
                # proper size when built by hand.
                mappen[:] = [m for m in mappen if m not in OVERSLAAN_MAPPEN]
                for f in sorted(files):
                    if f in OVERSLAAN:
                        continue
                    p = os.path.join(wortel, f)
                    rel = os.path.relpath(p, vol).replace("\\", "/")
                    # A build script that arrives without its execute bit is a
                    # build script nobody can run, and the zip is written on
                    # Windows where the file never had one to carry over.
                    totaal += voeg_toe(zf, p, "%s/%s" % (doelmap, rel),
                                       f.endswith(".sh"))

    # On the finished file rather than the open handle: what ships is what gets
    # checked, and a zip still being written cannot be read back reliably.
    with zipfile.ZipFile(zippad) as zf:
        tekort = ontbrekende_afhankelijkheden(zf)
    if tekort:
        for regel in tekort:
            print("  ! " + regel)
        os.remove(zippad)
        raise SystemExit("package is incomplete; see above")

    with open(zippad, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    print("%s  (%.0f kB from %.0f kB of files)"
          % (zippad, os.path.getsize(zippad) / 1024.0, totaal / 1024.0))
    print("sha256: " + sha)


if __name__ == "__main__":
    main()
