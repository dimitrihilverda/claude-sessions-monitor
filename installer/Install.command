#!/bin/bash
#
#  Install.command -- Claude Deck on a Mac
#
#  Double-click it in Finder, or run:  bash Install.command
#
#  What it does, in order: check that PowerShell is there, copy the files
#  somewhere they can stay, register the Claude Code hooks, run the self test,
#  and offer to start the web service.
#
#  Why a copy rather than running it from your Downloads folder: the hooks are
#  registered with the full path to beacon.ps1. Run it from a folder you later
#  clean up and every Claude session quietly stops reporting in, with nothing to
#  suggest why.
#
#  The Mac half of this project was written without a Mac to try it on. That is
#  what the self test is for, and why this script shows you its output instead
#  of hiding it: if something is wrong, that is where it says so.

cd "$(dirname "$0")" || exit 1
BRON="$(pwd)"
DOEL="$HOME/Library/Application Support/ClaudeDeck"

kop() { printf '\n\033[1m%s\033[0m\n' "$1"; }
zeg() { printf '  %s\n' "$1"; }
fout() { printf '\n\033[31m%s\033[0m\n' "$1"; }

printf '\n\033[1mClaude Deck\033[0m -- installing on macOS\n'

# ---- 1. PowerShell ----------------------------------------------------------
kop 'PowerShell'
PWSH="$(command -v pwsh)"
if [ -z "$PWSH" ]; then
    fout 'PowerShell 7 is not installed.'
    zeg 'This project is written in PowerShell, so it needs pwsh:'
    zeg ''
    zeg '    brew install powershell'
    zeg ''
    zeg 'Then run this installer again.'
    echo
    read -r -p 'Press return to close. '
    exit 1
fi
zeg "Found: $PWSH"
zeg "$("$PWSH" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null)"

# ---- 2. the files -----------------------------------------------------------
kop 'Copying files'
if [ "$BRON" = "$DOEL" ]; then
    zeg 'Already running from the install folder; nothing to copy.'
else
    mkdir -p "$DOEL" || { fout "Could not create $DOEL"; exit 1; }
    for f in "$BRON"/*.ps1 "$BRON"/VERSION "$BRON"/actions.json; do
        [ -e "$f" ] || continue
        naam="$(basename "$f")"
        # Your own button actions live in actions.json. Reinstalling must not
        # throw them away.
        if [ "$naam" = "actions.json" ] && [ -e "$DOEL/$naam" ]; then
            zeg "= $naam (keeping your existing settings)"
            continue
        fi
        cp "$f" "$DOEL/" && zeg "+ $naam"
    done
    # The sketch and the flashing notes, for whoever has a display.
    if [ -d "$BRON/cyd" ]; then
        rm -rf "$DOEL/cyd"
        cp -R "$BRON/cyd" "$DOEL/cyd" && zeg '+ cyd/ (sketch and instructions)'
    fi
fi
# The beacon makes this itself on its first run, but the API answers with an
# empty list until it exists -- which looks exactly like a broken install.
mkdir -p "$DOEL/session-status"
zeg "Folder: $DOEL"

# ---- 3. the hooks -----------------------------------------------------------
kop 'Linking to Claude Code'
if ! "$PWSH" -NoProfile -File "$DOEL/install-hooks.ps1"; then
    fout 'Registering the hooks failed. Nothing else will work until that does.'
    read -r -p 'Press return to close. '
    exit 1
fi

# ---- 4. does any of this work here ------------------------------------------
kop 'Self test'
zeg 'Every assumption the Mac side rests on, checked on this machine.'
echo
"$PWSH" -NoProfile -File "$DOEL/selftest.ps1"
echo
zeg 'If anything above says FAIL, that output is the thing to send back.'

# ---- 5. the floating window -------------------------------------------------
kop 'The floating window'
if [ ! -d "$BRON/hud-macos" ]; then
    zeg 'Not in this package.'
elif ! command -v swiftc >/dev/null 2>&1; then
    zeg 'Skipped: no Swift compiler here.'
    zeg 'The window is native AppKit, so it needs the Command Line Tools:'
    zeg ''
    zeg '    xcode-select --install'
    zeg ''
    zeg 'Then run hud-macos/build.sh install. Xcode itself is not needed.'
else
    zeg 'A window that floats above everything, listing your sessions.'
    zeg 'Built here from source; it needs no Xcode, only the Command Line Tools.'
    echo
    read -r -p '  Build and install it? [Y/n] ' hudantwoord
    case "$hudantwoord" in
        [Nn]*) zeg 'Skipped. hud-macos/build.sh install does it later.' ;;
        *)
            if (cd "$BRON/hud-macos" && ./build.sh install); then
                zeg 'The window is up. Right-click it for the menu.'
            else
                fout 'Building the window failed. The rest of the install is fine.'
            fi
            ;;
    esac
fi

# ---- 6. the web service -----------------------------------------------------
kop 'The web service'
zeg 'This is what the display, your phone and the window above all talk to.'
zeg 'Without it the window has nothing to show.'
echo
zeg "  \"$PWSH\" -NoProfile -File \"$DOEL/session-api.ps1\""
echo
IP="$("$PWSH" -NoProfile -Command ". '$DOEL/platformlib.ps1'; Get-DashLanAddress" 2>/dev/null)"
if [ -n "$IP" ]; then
    zeg "On this machine:  http://localhost:8787/"
    zeg "From the display: $IP:8787"
else
    zeg 'On this machine:  http://localhost:8787/'
    zeg 'No network address found -- the display needs one, a browser here does not.'
fi
echo
read -r -p '  Start it now? [Y/n] ' antwoord
case "$antwoord" in
    [Nn]*)
        echo
        zeg 'Not started. The line above starts it whenever you want.'
        ;;
    *)
        echo
        zeg 'Running. Ctrl+C stops it, and closing this window does too.'
        zeg 'The first time you tap a row, macOS will ask whether this may'
        zeg 'control other applications. Until you agree, nothing is raised.'
        echo
        "$PWSH" -NoProfile -File "$DOEL/session-api.ps1"
        ;;
esac

echo
read -r -p 'Press return to close. '
