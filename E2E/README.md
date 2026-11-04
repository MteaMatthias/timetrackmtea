# End-to-end-tests (E2E)

Deze tests draaien de **echte** TimeTrack-logica en -vensters op een echte Mac (de macOS-15-runner van
GitHub Actions heeft een window server). Ze vangen het soort fouten die bij het lezen van de code
ontsnapten: de crash bij het kiezen van een klant in de vraag, een gesprek van 4 min dat als 10 min geboekt
werd, een tweede oproep van hetzelfde nummer die niet gevraagd of niet geboekt werd.

## Hoe het werkt

| Onderdeel | Echt of nep | Waar |
|---|---|---|
| Flow (Telavox) | **nep**: een kleine AppKit-app `Flow.app` (CFBundleName "Flow") met dezelfde toegankelijke teksten als het gesprekspaneel van Flow | `E2E/FakeFlow/main.swift`, gebouwd door `E2E/build-fakeflow.sh` |
| Flow uitlezen | echt: `FlowReader` via de Accessibility-API (andere app, dus echte IPC) | `CallWatcher.swift` |
| CallWatcher, CallPrompt (paneel), CallPromptView, CompanyField | echt; de test roept `CallWatcher.shared.tick()` elke seconde aan (zelfde werk als zijn eigen lus) en bedient de knoppen van de vraag via de toegankelijkheidsobjecten in het eigen proces | `Tests/TimeTrackTests/EndToEndTests.swift` |
| Store/Database, Planner, DayModel | echt, in `TIMETRACK_DATA_DIR` | |
| Teamleader-klasse | echt (tokens, `call`, `addTime`, `registered`, `syncCompanies`) | |
| Teamleader-server en portaal | **nep**: `E2EFakeTeamleader` (URLProtocol, geregistreerd voor `URLSession.shared`) beantwoordt `users.me`, `workTypes.list`, `companies.list/info/update`, `contacts.list/info`, `timeTracking.list/add/delete`, `/api/timetrack/token` en `/refresh`, en houdt elke `timeTracking.add` bij | idem |

De nep-Flow wordt bestuurd met een bestand `$TMPDIR/timetrack-e2e-fakeflow/state` (`state=idle|ringing|active|gone|quit`,
plus `number=`, `name=`, `company=`). Bij `active` telt een teller `00:01`, `00:02`… zoals in Flow.

### Teamleader verbinden zonder testhaak

`Teamleader.storedTokens` is `private lazy`; er is geen publieke manier om tokens te zetten. De test doet het langs
de echte weg, in twee pogingen:

1. **Sleutelhanger** (`EndToEndTests.setUp` op klasseniveau): staat er nog geen item `tokens` (service
   `be.mtea.timetrack`), dan wordt er een gezet in hetzelfde formaat als `Teamleader.Tokens`. Werkt enkel als
   `Teamleader.shared` nog niet aangemaakt was door een andere testklasse.
2. **Portaal** (`ensureTeamleader`): `portalURL = timetrack-e2e://portal`, dan de echte `Teamleader.connect()`.
   Die "opent de browser" met `timetrack-e2e://portal/timetrack/koppel?state=…`; dat schema is in de Info.plist van de
   nep-Flow geregistreerd, dus LaunchServices geeft de URL aan de nep-Flow, die ze in `openurl.txt` schrijft. De test
   leest de `state` en roept `Teamleader.shared.handleOpenURL(timetrack://callback?state=…&ticket=…)` aan; de
   echte code wisselt het ticket in bij `timetrack-e2e://portal/api/timetrack/token` (de nep-Teamleader) en bewaart de
   tokens. Daarna `refreshProfile()` en `syncCompanies(force: true)` tegen de nep-Teamleader.

Na de testklasse: `Teamleader.shared.disconnect()`, `portalURL`/`roundTo`/`bundlePerClient`/`addPhoneDisabled` gewist,
URLProtocol afgemeld, nep-Flow gestopt.

Lukt geen van beide (bv. LaunchServices geeft de URL niet door), dan worden de gesprekstests overgeslagen met
de reden. **Minimale testhaak** die dat oplost (enkel als het nodig blijkt): in `Sources/TimeTrack/Teamleader.swift`
`private func storeTokens(_ json: [String: Any]) throws` → `func storeTokens(_ json: [String: Any]) throws`
(internal; enkel zichtbaar voor `@testable import`). De test kan dan
`try Teamleader.shared.storeTokens(["access_token": "a", "refresh_token": "r", "expires_in": 3600.0])` doen.

## De tests

| Test | Wat |
|---|---|
| `test0_Diagnostics` | Faalt nooit. Drukt `E2E-DIAG:`-regels af: `AXIsProcessTrusted()`, de ouderketen van het testproces, SIP-status, of `FlowReader.app()` de nep-Flow vindt, welke teksten `FlowReader.texts` leest in de toestanden idle/ringing/active en wat `FlowReader.parse` ervan maakt, en of Teamleader verbonden raakte. |
| `test1_AnsweredCall…` | Rinkelt 6 s → opnemen → 70 s praten → ophangen. Geen vraag tijdens het rinkelen; vraag na het opnemen, op vaste grootte; klant kiezen via de echte knoppen (**Andere klant → zoeken "M&M" → resultaat → Opslaan**, het pad van de crash; lukt de UI-bediening niet, dan `CallWatcher.choose`); vraag verdwijnt; één `CallRecord` met begin = opnemen en einde = ophangen; `DayModel.reload()` geeft precies één gespreksvoorstel met die begintijd en duur = op de minuut naar boven (70 s → 120 s, met `roundTo` = 15 en bundelen aan); `DayModel.register` stuurt `timeTracking.add` met die `started_at`, `duration` en `subject` c-mm; daarna niet meer voorgesteld. |
| `test2_SameNumberCallingAgain…` | Gesprek 1 (25 s, klant kiezen), 60 s na ophangen belt hetzelfde nummer opnieuw (70 s). Gesprek 2: opnieuw een vraag, met de onthouden klant ("eerder door jou gekozen"), bevestigd met **Ja**. Twee aparte records, twee aparte voorstellen (exacte begin/duur, niet overlappend), elk apart geregistreerd → twee `timeTracking.add` met de juiste tijden. |
| `test3_MissedCall…` | Rinkelt 6 s en verdwijnt: niets bewaard, geen vraag, geen voorstel, geen registratie. |
| `test4_MainWindow…` | Het echte hoofdvenster via `AppDelegate().showMainWindow()` (NSHostingController zoals in de app); tabs 0–3 wisselen; venstergrootte moet gelijk blijven; een blok op een voorstelkaart aanklikken opent de echte `BlockAssignView`-popover; daarin een klant zoeken, kiezen en **Toewijzen**; het menubalkpaneel (`MenuContent`). Een NSException laat het proces crashen (`NSApplicationCrashOnExceptions` + een handler die de uitzondering afdrukt). Vereist geen Accessibility. |

Elke test die niet kan draaien, gooit `XCTSkip` en drukt `E2E-SKIP: <test>: <reden>` af. Zonder `TIMETRACK_E2E=1` of
zonder `TIMETRACK_DATA_DIR` wordt alles overgeslagen (lokaal raakt niets je echte database of sleutelhanger).
Extra knoppen: `TIMETRACK_E2E_CALL_SECONDS` (standaard 70), `TIMETRACK_E2E_ROUND_TO` (standaard 15),
`TIMETRACK_FAKEFLOW_APP` (pad naar een andere Flow.app). De gesprekstests duren samen ±5 min (echte tijd).

## Lokaal draaien (op een Mac)

```bash
./E2E/build-fakeflow.sh
TIMETRACK_E2E=1 TIMETRACK_DATA_DIR=/tmp/tt-e2e swift test --filter EndToEndTests
```
Het testprogramma (Terminal of Xcode) moet dan Toegankelijkheid hebben (Systeeminstellingen → Privacy en
beveiliging → Toegankelijkheid). Let op: weg 2 hierboven schrijft tokens in je sleutelhanger als je nog niet verbonden
was; `disconnect()` ruimt ze op. Ben je wél verbonden, dan blijven je echte tokens staan en gaan alle
Teamleader-verzoeken van het testproces naar de nep-Teamleader.

## CI: stappen voor `.github/workflows/build.yml`

Vervang de bestaande stap **Tests** door:

```yaml
      - name: E2E – nep-Flow bouwen
        run: ./E2E/build-fakeflow.sh

      - name: E2E – Toegankelijkheid voor het testproces (enkel op de wegwerp-runner)
        run: ./E2E/grant-accessibility.sh

      - name: Tests
        timeout-minutes: 25
        run: TIMETRACK_E2E=1 TIMETRACK_DATA_DIR="$RUNNER_TEMP/tt-test" swift test 2>&1 | tee test.log; exit ${PIPESTATUS[0]}

      - name: E2E-diagnose tonen
        if: always()
        run: |
          grep -E "E2E(-DIAG|-SKIP)?:" test.log | head -60 | while IFS= read -r line; do
            echo "::notice::${line}"
          done
          grep -A30 "ONOPGEVANGEN NSException" test.log || true
```

## Toegankelijkheid op de GitHub-runner: wat zeker is en wat niet

**Zeker** (uit `actions/runner-images`, `images/macos/scripts/build/configure-tccdb-macos.sh`):
de images schrijven zelf rijen in de systeem-TCC.db (`/Library/Application Support/com.apple.TCC/TCC.db`)
en in de gebruikers-TCC.db, o.a. `kTCCServiceAccessibility` voor `/bin/bash`, `/usr/bin/osascript`,
`/opt/hca/hosted-compute-agent`, `/usr/local/opt/runner/provisioner/provisioner`, `runprovisioner.sh`,
`com.apple.Terminal` en `com.apple.dt.Xcode-Helper`. Dat de systeem-TCC.db aangepast kan worden, betekent dat SIP op
die images uit staat (een beschermde database is anders niet schrijfbaar).

**Waarschijnlijk, niet zeker**: macOS kent Toegankelijkheid toe aan het "verantwoordelijke" proces. Voor een
stap in Actions is dat vermoedelijk `hosted-compute-agent`/de provisioner (die staan in de lijst), zodat
`AXIsProcessTrusted()` in `swift test` al `true` geeft zonder iets te doen. `test0_Diagnostics` drukt de waarde
en de ouderketen af: daaruit blijkt het bij de eerste run.

**Terugvaloptie**: `E2E/grant-accessibility.sh` (weigert buiten CI) toont `csrutil status` en de bestaande
Accessibility-rijen, en voegt `xctest` en `swiftpm-testing-helper` van de actieve Xcode toe aan beide TCC-databases
(met expliciete kolomnamen, `client_type` 1 = pad, `auth_value` 2 = toegestaan), en herstart `tccd`. Of macOS 15
een padregel zonder `csreq` aanvaardt voor een binair bestand van Apple, is **niet zeker**; `tccutil` kan enkel
toestemmingen intrekken (`reset`), niet toekennen. Geeft de diagnose nog `false`, plak dan de ouderketen uit
`E2E-DIAG` terug: het juiste pad uit die keten kan aan het script toegevoegd worden.

## Bekende valkuilen

- `Reminder.notify` (na "nummer toevoegen aan de fiche") gebruikt `UNUserNotificationCenter.current()`; buiten een
  app-bundel (xctest) geeft dat een NSException. De E2E-tests vermijden dat pad (het nummer staat al bij M&M en
  `addPhoneDisabled` = true). Andere tests die `CallWatcher.choose` met een onbekend nummer aanroepen, lopen dat risico.
- De nep-Flow is geen Electron-app; `AXManualAccessibility` doet daar niets. De teksten en hun volgorde komen
  overeen met wat de eigenaar in Flow zag ("Inkomende oproep", "M.", "Matthias .", "M&M", "0493 29 50 63", "Via",
  "Mtea - Verkoop", "Gewenst 003256446650", Verwijderen/Antwoorden; tijdens het gesprek de teller en
  Ophangen/Parkeren/Doorverbinden).
- Rond middernacht (UTC op de runner) kan een gesprek over twee dagen vallen; dan falen de dagvoorstel-controles.
