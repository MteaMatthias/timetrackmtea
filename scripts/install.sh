#!/bin/bash
# Installeert (of werkt bij) TimeTrack voor Mac.
# Gebruik:  curl -fsSL https://tools.mtea.be/timetrack/install.sh | bash
set -euo pipefail

URL="https://github.com/MteaMatthias/timetrackmtea/releases/latest/download/TimeTrack.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "⏱  TimeTrack downloaden…"
curl -fsSL "$URL" -o "$TMP/TimeTrack.zip"
ditto -x -k "$TMP/TimeTrack.zip" "$TMP"

# /Applications als dat kan, anders ~/Applications (geen beheerdersrechten nodig).
DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

osascript -e 'tell application id "be.mtea.timetrack" to quit' >/dev/null 2>&1 || true
pkill -x TimeTrack >/dev/null 2>&1 || true
sleep 1
rm -rf "$DEST/TimeTrack.app"
mv "$TMP/TimeTrack.app" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/TimeTrack.app" 2>/dev/null || true

echo "✅  TimeTrack staat in $DEST. Het programma start nu; volg de stappen op het scherm."
open "$DEST/TimeTrack.app"
