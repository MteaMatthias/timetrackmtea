import SwiftUI

/// Houdt het dagplan bij (activiteit + registraties uit Teamleader + voorstellen) en registreert.
@MainActor
final class DayModel: ObservableObject {
    /// Het hoofdvenster (de gekozen dag).
    static let shared = DayModel()
    /// Het menubalk-paneel (altijd vandaag).
    static let menu = DayModel()

    @Published var day = Date()
    @Published private(set) var plan = DayPlan()
    @Published private(set) var loading = false
    /// Eén registratie tegelijk, over het venster én het menubalk-paneel heen (geen dubbels).
    @Published private(set) var busy = false
    private static var registering = false
    private var generation = 0
    /// De laatste registratie, om ze ongedaan te kunnen maken.
    @Published private(set) var lastRegistration: (ids: [String], label: String)?
    /// False als de registraties uit Teamleader niet opgehaald konden worden: dan niets registreren.
    @Published private(set) var registeredLoaded = false
    @Published var error: String?
    /// Aanpassingen op kaartjes (klant, omschrijving, duur…), per voorstel-id; overleven het herladen.
    @Published var edits: [String: Proposal] = [:]

    var canRegister: Bool { Teamleader.shared.isConnected && registeredLoaded && !busy && !Self.registering }

    var dismissedCount: Int {
        let (lo, hi) = Store.dayBounds(day)
        return Store.dismissed(from: lo, to: hi).count
    }

    /// Aanpassingen op een kaart gelden ook in het menubalk-paneel (gedeeld met het hoofdvenster).
    func proposalToRegister(_ p: Proposal) -> Proposal { edits[p.id] ?? DayModel.shared.edits[p.id] ?? p }

    /// De hoogste generatie waarvan het herladen afgelopen is (gelukt, mislukt of verouderd).
    private var finishedGeneration = 0

    /// Herlaadt het dagplan. Komt er intussen een nieuwer herladen bij, dan wacht dit tot dat klaar is:
    /// na `await reload()` is het plan altijd actueel (bv. "Alles registreren" gebruikt nooit een verouderd plan).
    func reload() async {
        await load()
        var waited = 0
        while finishedGeneration < generation && waited < 600 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
    }

    private func load() async {
        generation += 1
        let gen = generation
        let day = self.day
        let (lo, hi) = Store.dayBounds(day)
        loading = true
        defer {
            if gen == generation { loading = false }
            finishedGeneration = max(finishedGeneration, gen)
        }
        var registered: [Registered] = []
        var loaded = false
        var failure: String?
        if Teamleader.shared.isConnected {
            do {
                try? await Teamleader.shared.syncCompanies(force: false)
                registered = try await Teamleader.shared.registered(from: lo, to: hi)
                loaded = true
            } catch is CancellationError {
                return
            } catch {
                failure = error.localizedDescription
            }
        }
        // Het voorstel berekenen op de achtergrond, zodat het venster vlot blijft.
        let roundTo = Prefs.roundTo, bundle = Prefs.bundlePerClient, entries = registered
        let computed = await Task.detached(priority: .userInitiated) {
            Planner.plan(day: day, registered: entries, matcher: Matcher.current(), roundTo: roundTo, bundle: bundle)
        }.value
        // Intussen een andere dag gekozen of opnieuw geladen: dit resultaat is verouderd.
        guard gen == generation else { return }
        plan = computed
        registeredLoaded = loaded
        error = failure
        let ids = Set(computed.proposals.map(\.id))
        edits = edits.filter { ids.contains($0.key) }
    }

    /// Starttijd in Teamleader: het eerste blok, maar opgeschoven tot er niets overlapt met wat al in
    /// Teamleader staat (een gebundelde registratie telt de blokken op en zou anders overlappen).
    private func startTime(for p: Proposal, taken: [(Double, Double)]) -> Double {
        // Een gesprek begint in Teamleader altijd op zijn echte begintijd, ook als de afgeronde duur van een
        // vorig gesprek (3 min → 10 min) erover loopt.
        if p.isCall { return p.start }
        var start = p.start
        var moved = true
        while moved {
            moved = false
            for (a, b) in taken where start < b && start + p.seconds > a {
                start = b
                moved = true
            }
        }
        let (_, dayEnd) = Store.dayBounds(day)
        return start + p.seconds <= dayEnd ? start : p.start
    }

    private var takenIntervals: [(Double, Double)] {
        plan.registered.compactMap { r in r.start.map { ($0, $0 + r.duration) } }
    }

    /// Maakt de registratie in Teamleader; geeft een foutmelding terug of nil.
    func register(_ worked: Proposal, learn: Rule? = nil) async -> String? {
        var p = worked
        p.seconds = Prefs.billed(worked.seconds)
        guard !Self.registering else { return "Er wordt al iets geregistreerd, even geduld." }
        Self.registering = true
        busy = true
        defer { busy = false; Self.registering = false }
        do {
            let start = startTime(for: p, taken: takenIntervals)
            let id = try await Teamleader.shared.addTime(start: start, end: start + p.seconds, match: p.match,
                                                         description: Self.text(for: p), invoiceable: p.match.invoiceable)
            Store.savePushed(teamleaderId: id, parts: p.parts)
            if let learn { Store.save(learn) }
            edits[p.id] = nil
            DayModel.shared.edits[p.id] = nil
            lastRegistration = ([id], "\(p.match.companyName) · \(formatDuration(p.seconds))")
            AppModel.shared.changed()
            await reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// De omschrijving die naar Teamleader gaat: nooit leeg.
    static func text(for p: Proposal) -> String {
        let text = p.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? Describer.describe(p) : text
    }

    func registerAll(_ proposals: [Proposal]) async {
        guard !Self.registering else { return }
        Self.registering = true
        busy = true
        defer { busy = false; Self.registering = false }
        var failures: [String] = []
        var done: [String] = []
        var total = 0.0
        var taken = takenIntervals
        for worked in proposals {
            var p = worked
            p.seconds = Prefs.billed(worked.seconds)
            do {
                let start = startTime(for: p, taken: taken)
                let id = try await Teamleader.shared.addTime(start: start, end: start + p.seconds, match: p.match,
                                                             description: Self.text(for: p), invoiceable: p.match.invoiceable)
                Store.savePushed(teamleaderId: id, parts: p.parts)
                taken.append((start, start + p.seconds))
                done.append(id)
                total += p.seconds
                edits[p.id] = nil
                DayModel.shared.edits[p.id] = nil
            } catch {
                failures.append("\(p.match.companyName): \(error.localizedDescription)")
            }
        }
        // Alles in één keer ongedaan te maken (bv. per ongeluk op "Alles registreren" geklikt).
        lastRegistration = done.isEmpty ? nil : (done, "\(done.count) registratie(s) · \(formatDuration(total))")
        AppModel.shared.changed()
        await reload()
        if !failures.isEmpty { error = "Niet gelukt: " + failures.joined(separator: "; ") }
    }

    /// Verwijdert de laatste registratie(s) weer uit Teamleader.
    func undoLastRegistration() async {
        guard let last = lastRegistration else { return }
        var failed: [String] = []
        for id in last.ids {
            do {
                try await Teamleader.shared.deleteTime(id: id)
                Store.deletePushed(teamleaderId: id)
            } catch {
                failed.append(id)
                self.error = "Ongedaan maken mislukt: \(error.localizedDescription)"
            }
        }
        lastRegistration = failed.isEmpty ? nil : (failed, "\(failed.count) registratie(s) niet verwijderd")
        AppModel.shared.changed()
        await reload()
    }

    /// Verwijdert een registratie uit Teamleader; de tijd verschijnt daarna opnieuw als voorstel.
    func deleteRegistration(_ r: Registered) async -> String? {
        do {
            try await Teamleader.shared.deleteTime(id: r.id)
            Store.deletePushed(teamleaderId: r.id)
            if let last = lastRegistration, last.ids.contains(r.id) {
                let rest = last.ids.filter { $0 != r.id }
                lastRegistration = rest.isEmpty ? nil : (rest, "\(rest.count) registratie(s)")
            }
            AppModel.shared.changed()
            await reload()
            return nil
        } catch {
            let message = "Verwijderen mislukt: \(error.localizedDescription)"
            self.error = message
            return message
        }
    }

    func dismiss(_ p: Proposal) {
        // Enkel de echte blokken negeren (bij een gebundeld voorstel zit er ander werk tussen).
        p.parts.forEach { Store.dismiss(start: $0.start, end: $0.end) }
        edits[p.id] = nil
        AppModel.shared.changed()
    }
}

enum Prefs {
    /// Per klant één voorstel voor de hele dag (standaard aan).
    static var bundlePerClient: Bool { UserDefaults.standard.object(forKey: "bundlePerClient") as? Bool ?? true }

    static var roundTo: Int {
        let v = UserDefaults.standard.integer(forKey: "roundTo")
        return v > 0 ? v : 5
    }

    /// Naar Teamleader gaat elke registratie naar boven afgerond op dit aantal minuten (standaard 10):
    /// 3 min bellen = 10 min in Teamleader.
    static var billRoundTo: Int {
        let v = UserDefaults.standard.integer(forKey: "billRoundTo")
        return v > 0 ? v : 10
    }

    /// De duur die naar Teamleader gaat: naar boven afgerond, minstens één eenheid.
    static func billed(_ seconds: Double) -> Double {
        let step = Double(billRoundTo * 60)
        return max(step, ((seconds - 0.5) / step).rounded(.up) * step)
    }
}

// MARK: - Vandaag

struct TodayView: View {
    @EnvironmentObject var model: DayModel
    @EnvironmentObject var teamleader: Teamleader
    @EnvironmentObject var appModel: AppModel
    @State private var showRegistered = false
    @State private var confirmAll: [Proposal]?
    @State private var deleting: Registered?

    private var plan: DayPlan { model.plan }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                metrics
                banners
                DayTimeline(plan: plan, day: model.day) { AppModel.shared.changed() }
                    .frame(height: 150)
                    .card()
                proposalsSection
                registeredSection
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: model.day) {
            model.edits = [:]
            await model.reload()
        }
        .onChange(of: appModel.revision) { _ in Task { await model.reload() } }
        .onReceive(Timer.publish(every: 120, on: .main, in: .common).autoconnect()) { _ in
            // Niet herladen terwijl iemand een voorstel aan het aanpassen is.
            if Calendar.current.isDateInToday(model.day), !model.busy, model.edits.isEmpty {
                Task { await model.reload() }
            }
        }
    }

    // MARK: Kop

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Calendar.current.isDateInToday(model.day) ? "Vandaag" : model.day.formatted(.dateTime.weekday(.wide)).capitalized)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(model.day.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Vorige dag")
                Button("Vandaag") { model.day = Date() }
                    .disabled(Calendar.current.isDateInToday(model.day))
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .help("Volgende dag")
                DatePicker("Dag", selection: $model.day, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .frame(width: 110)
                Button { Task { await model.reload() } } label: {
                    if model.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .help("Vernieuwen")
            }
            .controlSize(.large)
        }
    }

    private func shift(_ days: Int) {
        model.day = Calendar.current.date(byAdding: .day, value: days, to: model.day) ?? model.day
    }

    private var metrics: some View {
        let worked = max(plan.worked, 1)
        return VStack(spacing: 10) {
            HStack(spacing: 14) {
                MetricTile(icon: "laptopcomputer", title: "Gewerkt", value: formatDuration(plan.worked), tint: .blue)
                MetricTile(icon: "checkmark.circle.fill", title: "In Teamleader",
                           value: formatDuration(plan.registeredSeconds), tint: .green)
                MetricTile(icon: "tray.full.fill", title: "Te registreren",
                           value: formatDuration(plan.proposedSeconds),
                           tint: plan.proposals.isEmpty ? .secondary : .orange)
            }
            GeometryReader { geo in
                let done = min(1, plan.registeredSeconds / worked)
                let open = min(1 - done, plan.proposedSeconds / worked)
                HStack(spacing: 2) {
                    Capsule().fill(Color.green.gradient).frame(width: max(0, geo.size.width * done))
                    Capsule().fill(Color.orange.opacity(0.6)).frame(width: max(0, geo.size.width * open))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 6)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .help("Groen: in Teamleader · oranje: nog te registreren")
        }
    }

    @ViewBuilder
    private var banners: some View {
        if let last = model.lastRegistration {
            Banner(icon: "checkmark.circle.fill", tint: .green, text: "Geregistreerd in Teamleader: \(last.label)") {
                Button("Ongedaan maken") { Task { await model.undoLastRegistration() } }
            }
        }
        if let error = model.error {
            Banner(icon: "exclamationmark.triangle.fill", tint: .orange, text: error)
        }
        if !teamleader.isConnected {
            Banner(icon: "link", tint: .blue,
                   text: "Verbind met Teamleader (Instellingen) om je registraties te zien en voorstellen te bevestigen.") {
                Button("Instellingen") { appModel.tab = 3 }
            }
        }
        if let limit = teamleader.historicLimitHours,
           let oldest = plan.proposals.map(\.start).min(),
           Date().timeIntervalSince1970 - oldest > limit * 3600 {
            Banner(icon: "clock.badge.exclamationmark", tint: .orange,
                   text: "Teamleader aanvaardt geen registraties die meer dan \(Int(limit)) uur teruggaan.")
        }
    }

    // MARK: Voorstellen

    @ViewBuilder
    private var proposalsSection: some View {
        let ready = plan.proposals.map(model.proposalToRegister).filter { $0.match.isAssigned }
        HStack(alignment: .firstTextBaseline) {
            Text("Voorstellen").font(.title2.weight(.semibold))
            if !plan.proposals.isEmpty {
                Text("\(plan.proposals.count)").font(.callout.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.18)))
            }
            Spacer()
            if ready.count > 1 {
                Button {
                    confirmAll = ready
                } label: {
                    Label("Alles registreren (\(formatDuration(ready.reduce(0) { $0 + Prefs.billed($1.seconds) })))",
                          systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canRegister)
                .confirmationDialog("Alles registreren in Teamleader?", isPresented: Binding(
                    get: { confirmAll != nil }, set: { if !$0 { confirmAll = nil } }), titleVisibility: .visible) {
                    Button("Registreer \(confirmAll?.count ?? 0) voorstellen") {
                        let all = confirmAll ?? []
                        confirmAll = nil
                        Task { await model.registerAll(all) }
                    }
                    Button("Annuleren", role: .cancel) { confirmAll = nil }
                } message: {
                    Text(RegisterAllSummary.text(confirmAll ?? []))
                }
            }
        }
        if plan.proposals.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: plan.worked < 60 ? "sun.max" : "checkmark.seal.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(plan.worked < 60 ? Color.secondary : Color.green)
                Text(plan.worked < 60 ? "Nog geen activiteit op deze dag." : "Alles staat in Teamleader.")
                    .font(.headline)
                Text(plan.worked < 60 ? "TimeTrack houdt bij waar je aan werkt; voorstellen verschijnen hier vanzelf."
                                      : "Mooi zo, er valt niets meer te registreren.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .card()
        } else {
            ForEach(plan.proposals) { proposal in
                ProposalCard(proposal: proposal, model: model)
            }
        }
        if model.dismissedCount > 0 {
            HStack {
                Image(systemName: "eye.slash").foregroundStyle(.secondary)
                Text("\(model.dismissedCount) genegeerd blok(ken) op deze dag.").foregroundStyle(.secondary)
                Button("Terugzetten") {
                    let (lo, hi) = Store.dayBounds(model.day)
                    Store.undismiss(from: lo, to: hi)
                    appModel.changed()
                }
                .buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    // MARK: Al in Teamleader

    @ViewBuilder
    private var registeredSection: some View {
        if !plan.registered.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                DisclosureGroup(isExpanded: $showRegistered) {
                    VStack(spacing: 0) {
                        ForEach(plan.registered.sorted { ($0.start ?? 0) < ($1.start ?? 0) }) { r in
                            HStack(spacing: 12) {
                                Avatar(name: r.companyName, size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.companyName).fontWeight(.medium)
                                    if !r.description.isEmpty {
                                        Text(r.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text(r.start.map { "\(formatTime($0))–\(formatTime($0 + r.duration))" } ?? "zonder tijdstip")
                                    .foregroundStyle(.secondary).monospacedDigit()
                                Text(formatDuration(r.duration)).fontWeight(.medium).monospacedDigit()
                                    .frame(width: 60, alignment: .trailing)
                                Button {
                                    deleting = r
                                } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.red)
                                    .disabled(!model.canRegister)
                                    .help("Verwijder deze registratie uit Teamleader")
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("Al in Teamleader · \(plan.registered.count) registratie(s) · \(formatDuration(plan.registeredSeconds))",
                          systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
            }
            .card()
            .confirmationDialog("Registratie verwijderen?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible,
                presenting: deleting) { r in
                Button("Verwijder uit Teamleader", role: .destructive) {
                    deleting = nil
                    Task { _ = await model.deleteRegistration(r) }
                }
                Button("Annuleren", role: .cancel) { deleting = nil }
            } message: { r in
                Text("\(r.companyName) · \(r.start.map { "\(formatTime($0))–\(formatTime($0 + r.duration))" } ?? "zonder tijdstip") · \(formatDuration(r.duration))\n\nDe registratie wordt ook in Teamleader verwijderd. De tijd verschijnt daarna opnieuw als voorstel.")
            }
        }
    }
}

/// Wat "Alles registreren" zal doen, om eerst te bevestigen.
enum RegisterAllSummary {
    static func text(_ proposals: [Proposal]) -> String {
        let lines = proposals.prefix(8).map {
            "• \($0.match.companyName) · \(formatDuration(Prefs.billed($0.seconds)))"
        }
        let more = proposals.count > 8 ? "\n… en nog \(proposals.count - 8)" : ""
        let total = proposals.reduce(0) { $0 + Prefs.billed($1.seconds) }
        return lines.joined(separator: "\n") + more + "\n\nTotaal \(formatDuration(total)). Controleer eerst of elke klant klopt."
    }
}

/// Melding bovenaan een scherm.
struct Banner<Action: View>: View {
    let icon: String
    let tint: Color
    let text: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).textSelection(.enabled)
            Spacer()
            action()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.1)))
    }
}

extension Banner where Action == EmptyView {
    init(icon: String, tint: Color, text: String) {
        self.init(icon: icon, tint: tint, text: text) { EmptyView() }
    }
}

// MARK: - Voorstelkaart

struct ProposalCard: View {
    @EnvironmentObject var teamleader: Teamleader
    let original: Proposal
    @ObservedObject var model: DayModel

    @State private var proposal: Proposal
    @State private var remember = false
    @State private var working = false
    @State private var error: String?
    @State private var showDetails = false
    @State private var assigningActivity: String?
    @State private var aiDescribed = false

    private var missingDescription: Bool { proposal.description.trimmingCharacters(in: .whitespaces).isEmpty }
    @State private var assigning: Proposal.Part?

    init(proposal: Proposal, model: DayModel) {
        original = proposal
        self.model = model
        _proposal = State(initialValue: model.edits[proposal.id] ?? proposal)
    }

    private var clientChanged: Bool { proposal.match.key != original.match.key }
    private var tint: Color { proposal.match.isAssigned ? Color.forName(proposal.match.companyName) : .orange }

    /// Enkel een klantspecifiek domein, programma of chattitel is een goede kandidaat om te onthouden;
    /// nooit een browser, mailprogramma of algemene site (Gmail, Google Docs, Canva…).
    private var learnable: Bool {
        let p = original.learnPattern
        return !p.isEmpty && p.count >= 3 && proposal.match.isAssigned && clientChanged
            && !Self.genericApps.contains(p) && !Matcher.isGeneric(p.lowercased())
    }
    private static let genericApps: Set<String> = [
        "Safari", "Google Chrome", "Microsoft Edge", "Brave Browser", "Arc", "Firefox", "Finder", "Mail",
        "Microsoft Outlook", "Slack", "Microsoft Teams", "zoom.us", "Notes", "Notities", "Terminal",
        "Microsoft Word", "Microsoft Excel", "Microsoft PowerPoint", "Preview", "Voorvertoning", "TimeTrack",
        "Claude", "ChatGPT", "Flow",
    ]

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2).fill(tint.gradient).frame(width: 4).padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 14) {
                topRow
                blocksRow
                editRow
                if splittable || showDetails {
                    VStack(alignment: .leading, spacing: 3) {
                        if splittable {
                            Text("Was een deel voor een andere klant? Klik bij die activiteit op ‘Klant…’.")
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(proposal.activities, id: \.self) { activityRow($0) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Banner(icon: "xmark.octagon.fill", tint: .red, text: error)
                }
            }
            .padding(.leading, 14)
        }
        .card()
        .onChange(of: proposal) { edited in
            // Bewaar aanpassingen in het model, zodat herladen of "Alles registreren" ze niet verliest.
            model.edits[original.id] = edited == original ? nil : edited
            if !learnable { remember = false }
            // Een vaste chatnaam is altijd specifiek: dan meteen onthouden.
            else if original.learnPattern.contains("-chat ") { remember = true }
        }
        .task(id: original.id) {
            // Omschrijving bijschaven met Apple Intelligence, zolang je ze zelf nog niet aanpaste.
            let base = original.description
            guard let better = await AIDescriber.improve(original), proposal.description == base else { return }
            proposal.description = better
            aiDescribed = true
        }
        .onChange(of: original) { fresh in
            // Nieuw berekend voorstel (bv. lopend blok werd langer): overnemen als er niets aangepast is.
            if model.edits[fresh.id] == nil { proposal = fresh }
        }
    }

    private var topRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Avatar(name: proposal.match.isAssigned ? proposal.match.companyName : "", size: 40)
            VStack(alignment: .leading, spacing: 6) {
                CompanyField(id: $proposal.match.companyId, name: $proposal.match.companyName, compact: true)
                    .font(.title3.weight(.semibold))
                Text(reasonText).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                Text(formatDuration(Prefs.billed(proposal.seconds)))
                    .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    .help("Naar boven afgerond op \(Prefs.billRoundTo) min voor Teamleader")
                if Prefs.billed(proposal.seconds) != proposal.seconds {
                    Text("\(formatDuration(proposal.seconds)) gewerkt").font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 8) {
                    Menu {
                        Button("Negeren (geen werk)") { model.dismiss(original) }
                        if let companyId = original.match.companyId, !clientChanged {
                            Button("\(original.match.companyName) is geen klant") {
                                Matcher.exclude(companyId: companyId)
                                AppModel.shared.changed()
                            }
                        }
                        Button(showDetails ? "Details verbergen" : "Details tonen") { showDetails.toggle() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Meer")
                    Button {
                        Task { await submit() }
                    } label: {
                        if working { ProgressView().controlSize(.small) } else { Label("Registreer", systemImage: "checkmark") }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canRegister || !proposal.match.isAssigned || working || missingDescription)
                    .help(!proposal.match.isAssigned ? "Kies eerst een klant"
                          : missingDescription ? "Vul een korte omschrijving in" : "Registreer in Teamleader")
                }
            }
        }
    }

    /// De werkblokken; klik op een blok om het aan een andere klant toe te wijzen.
    private var blocksRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").foregroundStyle(.secondary).font(.caption)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(proposal.parts) { part in
                        Button { assigning = part } label: { BlockChip(part: part, tint: tint) }
                            .buttonStyle(.plain)
                            .help("Klik om dit blok, of een deel ervan, aan een klant toe te wijzen")
                    }
                }
            }
        }
        .popover(item: $assigning) { part in
            BlockAssignView(part: part, current: proposal.match.companyName, pieces: proposal.pieces) {
                assigning = nil
                AppModel.shared.changed()
            }
        }
    }

    private var editRow: some View {
        HStack(spacing: 10) {
            TextField("Omschrijving voor de klant (verplicht)", text: $proposal.description)
                .textFieldStyle(.roundedBorder)
                .overlay(alignment: .trailing) {
                    if aiDescribed {
                        Image(systemName: "sparkles").foregroundStyle(.secondary).padding(.trailing, 6)
                            .help("Voorgesteld door Apple Intelligence op je Mac (er gaat niets naar buiten)")
                    }
                }
            WorkTypePicker(id: $proposal.match.workTypeId, name: $proposal.match.workTypeName)
                .labelsHidden()
                .frame(width: 160)
            Stepper("\(formatDuration(proposal.seconds)) gewerkt",
                    onIncrement: { proposal.seconds += 300 },
                    onDecrement: { if proposal.seconds > 300 { proposal.seconds -= 300 } })
                .monospacedDigit()
                .help("Duur aanpassen per 5 minuten")
            Toggle("Factureerbaar", isOn: $proposal.match.invoiceable)
            if learnable {
                Toggle("Onthoud", isOn: $remember)
                    .help("Voortaan ‘\(original.learnPattern)’ → \(proposal.match.companyName)")
            }
        }
        .font(.callout)
    }

    /// Meer dan één activiteit in dit voorstel: dan kan je per activiteit een klant kiezen.
    private var splittable: Bool { Set(original.pieces.map(\.label)).count > 1 }

    /// "Mail: Re: Offerte · 2 min" → "Mail: Re: Offerte"
    private static func activityLabel(_ line: String) -> String {
        guard let r = line.range(of: " · ", options: .backwards) else { return line }
        return String(line[..<r.lowerBound])
    }

    @ViewBuilder
    private func activityRow(_ line: String) -> some View {
        let label = Self.activityLabel(line)
        let pieces = original.pieces.filter { $0.label == label }
        HStack(spacing: 8) {
            Text("• \(line)").lineLimit(1).truncationMode(.middle)
            if splittable && !pieces.isEmpty {
                Button("Klant…") { assigningActivity = label }
                    .buttonStyle(.link)
                    .help("Enkel ‘\(label)’ aan een (andere) klant toewijzen")
                    .popover(isPresented: Binding(get: { assigningActivity == label },
                                                  set: { if !$0 { assigningActivity = nil } })) {
                        ActivityAssignView(label: label, pieces: pieces) {
                            assigningActivity = nil
                            AppModel.shared.changed()
                        }
                    }
            }
        }
    }

    private var reasonText: String {
        if clientChanged { return "Door jou gekozen" }
        if !proposal.match.isAssigned {
            return "Niet herkend · je werkte in " + proposal.activities.prefix(2).joined(separator: ", ")
        }
        return proposal.reasons.isEmpty ? "" : proposal.reasons.joined(separator: " · ")
    }

    private func submit() async {
        working = true
        defer { working = false }
        var rule: Rule?
        if remember && learnable {
            // "|" scheidt trefwoorden in een regel: niet uit een chattitel overnemen.
            rule = Rule(field: "any", pattern: original.learnPattern.replacingOccurrences(of: "|", with: " "),
                        companyId: proposal.match.companyId,
                        companyName: proposal.match.companyName, workTypeId: proposal.match.workTypeId,
                        workTypeName: proposal.match.workTypeName, invoiceable: proposal.match.invoiceable)
        }
        error = await model.register(proposal, learn: rule)
    }
}

extension Proposal.Part: Identifiable {
    var id: String { "\(Int(start))-\(Int(end))" }
}

// MARK: - Tijdlijn met drie lanen

struct DayTimeline: View {
    let plan: DayPlan
    let day: Date
    var onChange: () -> Void = {}
    @State private var assigning: Proposal.Part?
    @State private var assigningLabel = ""
    @State private var assigningPieces: [Proposal.Piece] = []

    private var range: (Double, Double) {
        let (lo, _) = Store.dayBounds(day)
        var times: [Double] = plan.activity.flatMap { [$0.start, $0.end] }
        times += plan.registered.compactMap { $0.start }
        times += plan.registered.compactMap { $0.end }
        times += plan.proposals.flatMap { [$0.start, $0.end] }
        let first = min(times.min() ?? lo + 8 * 3600, lo + 8 * 3600)
        let last = max(times.max() ?? lo + 18 * 3600, lo + 18 * 3600)
        return ((first / 3600).rounded(.down) * 3600, (last / 3600).rounded(.up) * 3600)
    }

    var body: some View {
        GeometryReader { geo in
            let (t0, t1) = range
            let labelWidth: CGFloat = 92
            let width = geo.size.width - labelWidth
            let x = { (t: Double) -> CGFloat in labelWidth + CGFloat((t - t0) / (t1 - t0)) * width }
            let laneHeight: CGFloat = 28
            let now = Date().timeIntervalSince1970

            ZStack(alignment: .topLeading) {
                ForEach(Array(stride(from: t0, through: t1, by: 3600)), id: \.self) { t in
                    Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1, height: laneHeight * 3 + 16)
                        .offset(x: x(t))
                    Text(Date(timeIntervalSince1970: t).formatted(.dateTime.hour(.twoDigits(amPM: .omitted))))
                        .font(.caption2).foregroundStyle(.secondary)
                        .offset(x: x(t) - 8, y: laneHeight * 3 + 20)
                }
                lane("Teamleader", icon: "checkmark.circle", row: 0, height: laneHeight)
                lane("Voorstel", icon: "tray", row: 1, height: laneHeight)
                lane("Activiteit", icon: "waveform", row: 2, height: laneHeight)

                ForEach(plan.registered.filter { $0.start != nil }) { r in
                    block(from: x(r.start!), to: x(r.end!), row: 0, height: laneHeight,
                          color: Color.forName(r.companyName), label: r.companyName,
                          help: "\(r.companyName)\n\(formatTime(r.start!))–\(formatTime(r.end!)) · \(r.description)")
                }
                ForEach(plan.proposals.flatMap { p in p.parts.map { (p, $0) } }, id: \.1) { item in
                    let (p, part) = item
                    Button {
                        assigningLabel = p.match.isAssigned ? p.match.companyName : ""
                        assigningPieces = p.pieces
                        assigning = part
                    } label: {
                        block(from: x(part.start), to: x(part.end), row: 1, height: laneHeight,
                              color: p.match.isAssigned ? Color.forName(p.match.companyName).opacity(0.55) : Color.orange.opacity(0.45),
                              label: p.match.isAssigned ? p.match.companyName : "?", dashed: true,
                              help: "Klik om toe te wijzen · \(p.match.isAssigned ? p.match.companyName : "niet herkend")\n\(formatTime(part.start))–\(formatTime(part.end))")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(plan.activity) { a in
                    block(from: x(a.start), to: x(a.end), row: 2, height: laneHeight,
                          color: a.kind == .assigned ? Color.forName(a.label).opacity(0.8)
                              : a.kind == .skipped ? Color.gray.opacity(0.25) : Color.gray.opacity(0.45),
                          label: nil, help: "\(a.label)\n\(formatTime(a.start))–\(formatTime(a.end))")
                }
                if now > t0 && now < t1 && Calendar.current.isDate(day, inSameDayAs: Date()) {
                    Rectangle().fill(Color.red).frame(width: 2, height: laneHeight * 3 + 12)
                        .offset(x: x(now) - 1, y: -2)
                        .help("Nu")
                }
            }
            .popover(item: $assigning) { part in
                BlockAssignView(part: part, current: assigningLabel, pieces: assigningPieces) {
                    assigning = nil
                    onChange()
                }
            }
        }
    }

    private func lane(_ title: String, icon: String, row: Int, height: CGFloat) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(height: height)
            .offset(y: CGFloat(row) * (height + 4))
    }

    private func block(from a: CGFloat, to b: CGFloat, row: Int, height: CGFloat, color: Color, label: String?,
                       dashed: Bool = false, help: String) -> some View {
        let w = max(3, b - a)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color)
            .overlay {
                if dashed {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(Color.primary.opacity(0.4))
                }
            }
            .overlay(alignment: .leading) {
                if let label, w > 56 {
                    Text(label).font(.caption2.weight(.semibold)).lineLimit(1).padding(.horizontal, 6)
                        .foregroundStyle(Color.black.opacity(0.75))
                }
            }
            .frame(width: w, height: height)
            .offset(x: a, y: CGFloat(row) * (height + 4))
            .help(help)
    }
}
