# TimeTrack voor Mac

TimeTrack draait in de **menubalk**. Het houdt bij waar je aan werkt: programma's, documenten, websites en je agenda. Elke dag stelt het voor welke tijd je nog in **Teamleader Focus** moet registreren, en bij welke klant. Jij bevestigt met één klik.

> *13:00–15:00 → Klant X · omdat: website klantx.be · 1u40 en "Offerte Klant X.docx" · 20 min*

**Installeren:** zie <https://tools.mtea.be/timetrack>, of plak in Terminal:

```bash
curl -fsSL https://tools.mtea.be/timetrack/install.sh | bash
```

## Hoe het werkt

### 1. Registreren
Elke 5 seconden noteert TimeTrack:
- het actieve programma,
- de venstertitel,
- bij Safari, Chrome, Edge, Brave, Arc of Vivaldi het **domein** van de website. Het volledige adres wordt niet bewaard.

Wat niet als werk telt of niet geregistreerd wordt:
- **Inactief:** na 5 minuten zonder muis of toetsenbord telt de tijd niet. Tijdens een videocall of presentatie blijft de tijd wel tellen; TimeTrack herkent die aan het feit dat het scherm wakker gehouden wordt.
- **Weg van de Mac:** bij vergrendelen of slaapstand wordt de tijd sinds je laatste actie afgetrokken.
- **Pauze:** met de pauzeknop registreert TimeTrack niets.

### 2. Klant herkennen
TimeTrack haalt alle actieve bedrijven uit Teamleader (naam, website en e-maildomeinen) en zoekt de klant in deze volgorde:
1. **Correcties:** je eigen regels, bijvoorbeeld *youtube.com → negeren*.
2. **Website:** het domein van de website, bijvoorbeeld `shop.klantx.be` → Klant X.
3. **Agenda:** het e-maildomein van de deelnemers van een afspraak.
4. **Naam:** de bedrijfsnaam als heel woord in de venster- of afspraaktitel. Rechtsvormen zoals BV of NV worden genegeerd.

Kies je bij een voorstel zelf de klant, dan kan TimeTrack dat **onthouden** voor de volgende keer.

### 3. Dagvoorstel
Het voorstel wordt per minuut berekend:
- Een minuut telt als **werk** bij minstens 20 seconden activiteit, of tijdens een afspraak met deelnemers of een klant.
- Minuten die **al in Teamleader staan** of die je **negeerde**, vallen weg. Zo wordt niets dubbel voorgesteld.
- Korte pauzes tot 3 minuten worden overbrugd.
- Korte uitstapjes onder 5 minuten worden opgenomen in het werk eromheen. Voor niet-herkende stukken geldt dat tot 10 minuten.
- Elk aaneengesloten blok voor dezelfde klant wordt één voorstel van minstens 5 minuten. De duur wordt afgerond op 5 minuten, maar overlapt nooit met een bestaande registratie.

Het tabblad **Vandaag** toont drie lanen:
- **Teamleader:** wat al geregistreerd is.
- **Voorstel:** wat nog open staat.
- **Activiteit:** wat je deed.

**Week** toont per dag wat geregistreerd is en wat nog open staat. Op werkdagen krijg je rond 17 u een melding als er nog tijd open staat.

### 4. Registreren in Teamleader
**Registreer** maakt een tijdsregistratie aan (`timeTracking.add`) met:
- het bedrijf als onderwerp, of geen onderwerp bij *Intern*,
- de start en de duur,
- de werksoort, de omschrijving en of de tijd factureerbaar is.

De registratie staat op naam van de aangemelde gebruiker.

## Aanmelden bij Teamleader

Medewerkers klikken op **Verbinden met Teamleader** en melden zich aan met hun eigen account. Op de achtergrond gebeurt dit:
1. Het verbinden verloopt via **tools.mtea.be**. Dat portaal kent het client secret van de MTEA-integratie.
2. Het portaal wisselt de autorisatiecode in en geeft de tokens via een **eenmalig ticket** door aan de app (`timetrack://callback`).
3. Vernieuwen van de tokens gaat ook via het portaal: `POST /api/timetrack/refresh`.
4. De tokens van medewerkers worden niet op de server bewaard. Ze staan in de macOS-sleutelhanger.

Onder Instellingen → Geavanceerd kan ook een eigen integratie gebruikt worden, met de redirect `http://127.0.0.1:53682/callback`.

## Bouwen en releasen

GitHub Actions doet bij elke push:
- `swift test` (tests voor het dagvoorstel en de klantherkenning),
- daarna de bouw van een universele `TimeTrack.zip`.

Een tag `v1.2.3` publiceert een release met `TimeTrack.zip` en `install.sh`. De app en het installatiescript halen altijd de laatste release.

```bash
git tag v0.3.0 && git push origin v0.3.0
```

### Vast certificaat (aanbevolen)
Zonder vast certificaat ziet macOS elke update als een andere app. Dan moet je na elke update opnieuw toestemming geven voor Toegankelijkheid en de sleutelhanger.

Maak daarom eenmalig een zelfondertekend certificaat aan:
```bash
cat > cs.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = MTEA TimeTrack
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cs.cnf
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "MTEA TimeTrack" -out cert.p12   # kies een wachtwoord
base64 -i cert.p12 | pbcopy
```
Zet dan in GitHub → Settings → Secrets and variables → Actions:
- `SIGNING_CERT_P12`: de base64-tekst die nu op het klembord staat,
- `SIGNING_CERT_PASSWORD`: het wachtwoord.

Bewaar `key.pem` en `cert.p12` veilig en zet ze nooit in de repository.

Voor een app zonder enige waarschuwing van Apple is een Apple Developer-account nodig (€99 per jaar): Developer ID, notarisatie en stapler. Dat is dan een extra stap in de workflow.

### Zelf bouwen op een Mac (Xcode 16+)
```bash
swift test
./scripts/build-app.sh      # → build/TimeTrack.app en build/TimeTrack.zip
```

| Bestand | Inhoud |
|---|---|
| `Tracker.swift` | Actief venster, website-domein, inactiviteit, slaapstand en vergrendelen |
| `CalendarSource.swift` | Afspraken uit de agenda's op de Mac (EventKit) |
| `Matcher.swift` | Klantherkenning via Teamleader-bedrijven en correctieregels |
| `Planner.swift` | Dagvoorstel per minuut |
| `Teamleader.swift` | API, aanmelden via het portaal, sleutelhanger |
| `Updater.swift` | Updates in de app, dagelijkse melding |
| `Views/` | Vandaag, Week, Correcties, Instellingen, eerste start |

## Privacy

- Activiteit, vensters en domeinen blijven op de Mac, in `~/Library/Application Support/TimeTrack/`.
- Er gaat niets naar tools.mtea.be, behalve het aanmelden.
- Naar Teamleader gaat alleen wat de gebruiker zelf bevestigt.

Wie TimeTrack in het team gebruikt: elke medewerker ziet alleen zijn eigen gegevens en beslist zelf wat er geregistreerd wordt. Informeer medewerkers vooraf over wat de app bijhoudt (GDPR, cao nr. 81).
