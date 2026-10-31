#!/bin/bash
# Bouwt TimeTrack.app (universeel: Apple Silicon + Intel) en pakt het in als build/TimeTrack.zip.
# Gebruik op een Mac met Xcode 16+:  ./scripts/build-app.sh
#
# Ondertekenen: is er een certificaat "MTEA TimeTrack" in de keychain (in CI geïmporteerd uit een secret),
# dan wordt daarmee getekend. Zo blijft de identiteit van de app gelijk bij updates en onthoudt macOS
# de toestemmingen (Toegankelijkheid, sleutelhanger). Anders ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
IDENTITY="${SIGN_IDENTITY:-MTEA TimeTrack}"
ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

APP="build/TimeTrack.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/TimeTrack" "$APP/Contents/MacOS/TimeTrack"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "Ondertekenen met \"$IDENTITY\""
  codesign --force --deep --identifier be.mtea.timetrack --sign "$IDENTITY" "$APP"
else
  echo "Geen certificaat \"$IDENTITY\" gevonden: ad-hoc ondertekenen"
  codesign --force --deep --identifier be.mtea.timetrack --sign - "$APP"
fi
codesign --display --requirements - "$APP" 2>&1 | tail -1

(cd build && ditto -c -k --keepParent TimeTrack.app TimeTrack.zip)
echo "Klaar: build/TimeTrack.app en build/TimeTrack.zip"
