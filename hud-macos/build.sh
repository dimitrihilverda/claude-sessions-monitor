#!/bin/bash
#
#  build.sh -- build the HUD, or run its tests.
#
#    ./build.sh           build ClaudeDeck HUD.app here
#    ./build.sh test      compile and run the logic tests
#    ./build.sh install   build, then put it in ~/Applications and start it
#
#  No Xcode. swiftc out of the Command Line Tools can see AppKit and SwiftUI,
#  and an .app bundle is a folder with a plist in it -- there is nothing here
#  that needs a project file.

set -e
cd "$(dirname "$0")"

APP="Claude Sessions HUD"
BUNDLE_ID="io.github.dimitrihilverda.claude-sessions-monitor.hud"
BIN="ClaudeSessionsHUD"
VERSION="1.0.0"

# Swift 5 language mode on purpose: the strict concurrency checking in 6 turns
# every AppKit callback into an argument, and this is a window with a timer.
SWIFTC_FLAGS=(-swift-version 5 -O)

LOGIC=(Sources/DeckAPI.swift Sources/Settings.swift Sources/Notifier.swift
       Sources/Strings.swift)
UI=(Sources/SessionStore.swift Sources/SessionListView.swift
    Sources/HUDPanel.swift Sources/DeckMenu.swift Sources/main.swift)

case "$1" in
  test)
    echo "Compiling the tests..."
    mkdir -p build
    swiftc "${SWIFTC_FLAGS[@]}" "${LOGIC[@]}" Tests/main.swift -o build/tests
    echo
    ./build/tests
    exit $?
    ;;
esac

echo "Building $APP $VERSION"
rm -rf "build/$APP.app"
mkdir -p "build/$APP.app/Contents/MacOS" "build/$APP.app/Contents/Resources"

swiftc "${SWIFTC_FLAGS[@]}" "${LOGIC[@]}" "${UI[@]}" \
       -o "build/$APP.app/Contents/MacOS/$BIN"

# LSUIElement keeps it out of the Dock and out of the menu bar. Without it a
# window that is meant to sit quietly on top would come with an app to switch
# to, which is the opposite of the point.
cat > "build/$APP.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>$APP</string>
  <key>CFBundleDisplayName</key>       <string>$APP</string>
  <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>        <string>$BIN</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSHumanReadableCopyright</key>  <string>ClaudeDeck</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Not about trust -- an unsigned bundle cannot ask for
# notification permission, because there is no stable identity to grant it to.
codesign --force --sign - "build/$APP.app" 2>/dev/null || \
    echo "  (could not sign; notifications may stay silent)"

echo "Built: build/$APP.app"

if [ "$1" = "install" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    # Quit the running copy first: replacing a bundle underneath a running
    # process gives you a version mismatch that shows up much later.
    osascript -e "tell application \"$APP\" to quit" 2>/dev/null || true
    pkill -f "$DEST/$APP.app" 2>/dev/null || true
    sleep 1
    rm -rf "$DEST/$APP.app"
    cp -R "build/$APP.app" "$DEST/"
    echo "Installed: $DEST/$APP.app"
    open -a "$DEST/$APP.app"
    echo "Started."
fi
