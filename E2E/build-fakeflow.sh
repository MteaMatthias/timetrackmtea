#!/bin/bash
# Bouwt de nep-Flow-app voor de end-to-end-tests: E2E/build/Flow.app
# (CFBundleName "Flow", zodat FlowReader.app() ze vindt, en het URL-schema timetrack-e2e://).
# Gebruik op een Mac met Xcode:  ./E2E/build-fakeflow.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Flow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc -O -o "$APP/Contents/MacOS/Flow" FakeFlow/main.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Flow</string>
    <key>CFBundleDisplayName</key><string>Flow</string>
    <key>CFBundleExecutable</key><string>Flow</string>
    <key>CFBundleIdentifier</key><string>be.mtea.timetrack.e2e.fakeflow</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>TimeTrack E2E portal</string>
            <key>CFBundleURLSchemes</key><array><string>timetrack-e2e</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
# Bij LaunchServices aanmelden, zodat NSWorkspace.open(timetrack-e2e://…) bij deze app uitkomt.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$PWD/$APP" || true
echo "Klaar: $PWD/$APP"
