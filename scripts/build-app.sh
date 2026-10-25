#!/bin/bash
# Bouwt TimeTrack.app (universeel: Apple Silicon + Intel) en pakt het in als zip.
# Gebruik op een Mac met Xcode of de Command Line Tools:  ./scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

APP="build/TimeTrack.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/TimeTrack" "$APP/Contents/MacOS/TimeTrack"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

# Ad-hoc ondertekenen (geen Apple Developer-account nodig).
codesign --force --deep --sign - "$APP"

(cd build && ditto -c -k --keepParent TimeTrack.app "TimeTrack-$VERSION.zip")
echo "Klaar: build/TimeTrack.app en build/TimeTrack-$VERSION.zip"
