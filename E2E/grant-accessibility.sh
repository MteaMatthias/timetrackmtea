#!/bin/bash
# ENKEL VOOR DE WEGWERP-MACHINE VAN GITHUB ACTIONS (macOS-runner). Nooit op je eigen Mac draaien.
#
# Toont of SIP aan staat en welke programma's Toegankelijkheid hebben, en voegt (als dat kan) de
# testprogramma's van Xcode/SwiftPM toe aan de TCC-database, zodat `swift test` andere apps mag uitlezen.
# De runner-images van GitHub zetten zelf al bash, osascript, de provisioner en hosted-compute-agent in
# TCC.db; dit script voegt xctest en swiftpm-testing-helper toe voor het geval de toestemming aan het
# testproces zelf wordt toegekend. Mislukt iets, dan gaat het gewoon verder (de tests melden dan "overgeslagen").
# (geen set -u: bash 3.2 op macOS struikelt over lege arrays)
[ "${CI:-}" = "true" ] || { echo "Weigert: enkel bedoeld voor CI (CI=true)."; exit 0; }

echo "== SIP =="
csrutil status 2>&1 || true

DEV="$(xcode-select -p 2>/dev/null || echo /Applications/Xcode.app/Contents/Developer)"
CLIENTS=()
for c in "$(xcrun --find xctest 2>/dev/null)" "$DEV/usr/bin/xctest" \
         "$(dirname "$DEV")/SharedFrameworks/SwiftPM.framework/SharedSupport/swiftpm-testing-helper" \
         "$(find "$DEV/.." -maxdepth 8 -name swiftpm-testing-helper -type f 2>/dev/null | head -1)" \
         "$(find "$DEV/Platforms/MacOSX.platform" -maxdepth 6 -name xctest -type f 2>/dev/null | head -1)"; do
  [ -n "$c" ] && [ -e "$c" ] && CLIENTS+=("$c")
done
# Dubbels eruit.
CLIENTS=($(printf '%s\n' "${CLIENTS[@]}" | sort -u))
echo "== Toe te voegen clients =="; printf '  %s\n' "${CLIENTS[@]}"

NOW=$(date +%s)
for DB in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
  SUDO=""; [[ "$DB" == /Library/* ]] && SUDO="sudo"
  echo "== $DB =="
  $SUDO sqlite3 "$DB" "SELECT client, auth_value FROM access WHERE service='kTCCServiceAccessibility';" 2>&1 || true
  for c in "${CLIENTS[@]}"; do
    $SUDO sqlite3 "$DB" "INSERT OR REPLACE INTO access
      (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id,
       indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified)
      VALUES ('kTCCServiceAccessibility', '$c', 1, 2, 4, 1, NULL, NULL, 0, 'UNUSED', NULL, 0, $NOW);" 2>&1 \
      && echo "  + $c" || echo "  ! niet gelukt voor $c"
  done
done
# tccd de nieuwe rijen laten inlezen.
sudo killall tccd 2>/dev/null || true
killall tccd 2>/dev/null || true
exit 0
