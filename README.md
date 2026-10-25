# TimeTrack voor Mac

TimeTrack draait in de **menubalk** van je Mac en houdt automatisch bij in welk programma en venster je werkt. Daarmee bereid je je uren voor en stuur je ze met één klik naar **Teamleader Focus**.

1. **Registreren:** elke 5 seconden noteert TimeTrack het actieve programma en de venstertitel. Na 5 minuten zonder muis of toetsenbord telt de tijd als inactief. Ook slaapstand en een vergrendeld scherm worden herkend.
2. **Voorbereiden:** het tabblad **Dag** toont een tijdlijn en de lijst van vensters.
   - Met **regels** koppel je vensters automatisch aan een klant, bijvoorbeeld *titel bevat "Janssen" → Janssen NV*.
   - **Maak registraties voor deze dag** zet per klant (en werksoort) een concept klaar, afgerond op 15 minuten.
3. **Controleren en versturen:** in **Registraties** pas je de concepten aan of voeg je er manueel toe. Daarna klik je op **Verstuur naar Teamleader**.
   - Elke registratie wordt een tijdsregistratie in Teamleader, gekoppeld aan het bedrijf, met werksoort, omschrijving en of ze factureerbaar is.
   - Wat verstuurd is, krijgt een vinkje en wordt nooit dubbel verstuurd.

Alle activiteit blijft lokaal op de Mac, in `~/Library/Application Support/TimeTrack/`. Alleen de registraties die je zelf verstuurt, gaan naar Teamleader.

## Installeren

1. Download `TimeTrack-x.y.z.zip`. Die vind je onder **Actions** (laatste build → *Artifacts*) of onder **Releases**.
2. Pak het zip-bestand uit en sleep **TimeTrack.app** naar **Programma's**.
3. De app is niet bij Apple geregistreerd. Bij de eerste keer openen klik je daarom met de rechtermuisknop op de app → **Open** → **Open**. Lukt dat niet, voer dan dit uit in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/TimeTrack.app
   ```
4. Geef toestemming om venstertitels te lezen: **Instellingen** in TimeTrack → *Toestemming geven…*. Of ga naar **Systeeminstellingen → Privacy en beveiliging → Toegankelijkheid** en zet TimeTrack aan.
   > Na elke update vraagt macOS deze toestemming opnieuw. Zet TimeTrack in de lijst dan uit en weer aan.
5. Zet in Instellingen eventueel *Starten bij aanmelden* aan.

## Teamleader koppelen (eenmalig)

1. Ga naar [marketplace.focus.teamleader.eu/build](https://marketplace.focus.teamleader.eu/build) en maak een nieuwe integratie aan, bijvoorbeeld *TimeTrack MTEA*.
2. Stel als **Redirect URI** in: `http://127.0.0.1:53682/callback`
3. Kies de **scopes**:
   - `companies`: bedrijven zoeken
   - `users`: je eigen profiel
   - de scope voor tijdsregistratie en werksoorten (zie *Openstaande punten*)
4. Kopieer de **Client ID** en het **Client secret**. Vul ze in TimeTrack in onder **Instellingen → Teamleader** en klik op **Verbinden met Teamleader**. Je browser opent zodat je toegang kunt geven.

Het Client secret wordt in de macOS-sleutelhanger bewaard. Zet het nooit in deze repository.

## Werkwijze

- **Dagelijks of wekelijks:**
  1. Ga naar **Dag**, vink *Enkel niet toegewezen* aan en maak regels voor wat nog grijs staat. Houd de trefwoorden kort, bijvoorbeeld enkel de klantnaam.
  2. Klik op **Maak registraties voor deze dag**. Je kunt dit opnieuw doen: concepten die je nog niet bewerkt of verstuurd hebt, worden vervangen, en tijd die al verstuurd is, wordt afgetrokken.
  3. Kijk in **Registraties** de concepten na en klik op **Verstuur naar Teamleader**.
- **Privé:** maak een regel met *Negeren* (bijvoorbeeld voor YouTube of je bankapp) of gebruik **Pauzeer** in het menubalk-icoon.

## Bouwen

GitHub Actions bouwt de app automatisch bij elke push naar `main`. Een tag `v1.0.0` maakt een release.

Zelf bouwen op een Mac met Xcode 16 of nieuwer:
```bash
./scripts/build-app.sh          # → build/TimeTrack.app
swift run                       # snel starten tijdens ontwikkeling
```

Code:

| Bestand | Inhoud |
|---|---|
| `Tracker.swift` | Actief venster (NSWorkspace + Accessibility), inactiviteit, slaapstand |
| `Database.swift` | SQLite-opslag |
| `Store.swift` | Regels, classificatie, dagoverzicht, conceptregistraties |
| `Teamleader.swift` | OAuth 2 (redirect via 127.0.0.1), API-calls, Keychain |
| `Views/` | SwiftUI-schermen: Dag, Registraties, Regels, Instellingen |

## Openstaande punten

- **Scope voor tijdsregistratie:** de API-documentatie van Teamleader vermeldt geen aparte scope voor `timeTracking.add` en `workTypes.list`. Dit moet nog getest worden met een echte integratie.
- **Koppeling aan projecten:** registraties worden nu aan een **bedrijf** gekoppeld. De publieke API vermeldt geen koppeling aan taken uit de nieuwe Projects-module. Dit test ik nog zodra de koppeling werkt.
