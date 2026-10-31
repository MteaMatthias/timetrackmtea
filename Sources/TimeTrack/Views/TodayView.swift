import SwiftUI

/// Houdt het dagplan bij (activiteit + registraties uit Teamleader + voorstellen).
@MainActor
final class DayModel: ObservableObject {
    static let shared = DayModel()

    @Published var day = Date()
    @Published private(set) var plan = DayPlan()
    @Published private(set) var loading = false
    /// False als de registraties uit Teamleader niet opgehaald konden worden: dan niets registreren.
    @Published private(set) var registeredLoaded = false
    @Published var error: String?
    /// Aanpassingen op kaartjes (klant, omschrijving, tijden…), per voorstel-id; overleven het herladen.
    @Published var edits: [String: Proposal] = [:]

    var dismissedCount: Int {
        let (lo, hi) = Store.dayBounds(day)
        return Store.dismissed(from: lo, to: hi).count
    }

    func proposalToRegister(_ p: Proposal) -> Proposal { edits[p.id] ?? p }

    func reload() async {
        let (lo, hi) = Store.dayBounds(day)
        loading = true
        defer { loading = false }
        var registered: [Registered] = []
        registeredLoaded = false
        if Teamleader.shared.isConnected {
            do {
                try? await Teamleader.shared.syncCompanies(force: false)
                registered = try await Teamleader.shared.registered(from: lo, to: hi)
                registeredLoaded = true
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
        let matcher = Matcher.current()
        plan = Planner.plan(day: day, registered: registered, matcher: matcher, roundTo: Prefs.roundTo)
        let ids = Set(plan.proposals.map(\.id))
        edits = edits.filter { ids.contains($0.key) }
    }
}

enum Prefs {
    static var roundTo: Int {
        let v = UserDefaults.standard.integer(forKey: "roundTo")
        return v > 0 ? v : 5
    }
}

struct TodayView: View {
    @EnvironmentObject var model: DayModel
    @EnvironmentObject var teamleader: Teamleader
    @EnvironmentObject var appModel: AppModel
    @State private var busy = false
    @State private var showRegistered = false

    private var canRegister: Bool { teamleader.isConnected && model.registeredLoaded && !busy }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if !teamleader.isConnected {
                    Label("Verbind met Teamleader (Instellingen) om je registraties te zien en voorstellen te bevestigen.",
                          systemImage: "link")
                        .foregroundStyle(.orange)
                }
                timelineCard
                proposalsSection
                registeredSection
            }
            .padding(20)
        }
        .task(id: model.day) {
            model.edits = [:]
            await model.reload()
        }
        .onChange(of: appModel.revision) { _ in Task { await model.reload() } }
        .onReceive(Timer.publish(every: 120, on: .main, in: .common).autoconnect()) { _ in
            // Niet herladen terwijl iemand een voorstel aan het aanpassen is.
            if Calendar.current.isDateInToday(model.day), !busy, model.edits.isEmpty { Task { await model.reload() } }
        }
    }

    // MARK: Kop

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            HStack(spacing: 6) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                DatePicker("Dag", selection: $model.day, displayedComponents: .date)
                    .labelsHidden()
                    .frame(width: 120)
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                Button("Vandaag") { model.day = Date() }
                    .disabled(Calendar.current.isDateInToday(model.day))
            }
            Spacer()
            Stat(label: "Gewerkt", value: formatDuration(model.plan.worked))
            Stat(label: "In Teamleader", value: formatDuration(model.plan.registeredSeconds), color: .green)
            Stat(label: "Nog te registreren", value: formatDuration(model.plan.proposedSeconds),
                 color: model.plan.proposals.isEmpty ? .secondary : .orange)
            Button { Task { await model.reload() } } label: {
                if model.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .help("Vernieuwen")
        }
    }

    private func shift(_ days: Int) {
        model.day = Calendar.current.date(byAdding: .day, value: days, to: model.day) ?? model.day
    }

    // MARK: Tijdlijn

    private var timelineCard: some View {
        GroupBox {
            DayTimeline(plan: model.plan, day: model.day)
                .frame(height: 132)
                .padding(.vertical, 4)
        }
    }

    // MARK: Voorstellen

    @ViewBuilder
    private var proposalsSection: some View {
        let ready = model.plan.proposals.map(model.proposalToRegister).filter { $0.match.isAssigned }
        HStack {
            Text("Voorstellen").font(.title2.weight(.semibold))
            Spacer()
            if ready.count > 1 {
                Button("Registreer alle \(ready.count) met klant (\(formatDuration(ready.reduce(0) { $0 + $1.duration })))") {
                    Task { await registerAll(ready) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRegister)
            }
        }
        if model.plan.proposals.isEmpty {
            Text(model.plan.worked < 60
                 ? "Nog geen activiteit op deze dag."
                 : "Alles staat in Teamleader. 🎉")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            ForEach(model.plan.proposals) { proposal in
                ProposalCard(proposal: proposal, canRegister: canRegister) { edited, learn in
                    await register(edited, learn: learn)
                } onDismiss: {
                    Store.dismiss(start: proposal.start, end: proposal.end)
                    model.edits[proposal.id] = nil
                    Task { await model.reload() }
                }
            }
        }
        if model.dismissedCount > 0 {
            HStack {
                Text("\(model.dismissedCount) genegeerd voorstel(len) op deze dag.").foregroundStyle(.secondary)
                Button("Terugzetten") {
                    let (lo, hi) = Store.dayBounds(model.day)
                    Store.undismiss(from: lo, to: hi)
                    Task { await model.reload() }
                }
                .buttonStyle(.link)
            }
            .font(.callout)
        }
        if let limit = teamleader.historicLimitHours,
           let oldest = model.plan.proposals.map(\.start).min(),
           Date().timeIntervalSince1970 - oldest > limit * 3600 {
            Label("Teamleader aanvaardt geen registraties die meer dan \(Int(limit)) uur teruggaan.",
                  systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
        }
    }

    private func register(_ p: Proposal, learn: Rule?) async -> String? {
        busy = true
        defer { busy = false }
        do {
            _ = try await teamleader.addTime(start: p.start, end: p.end, match: p.match, description: p.description,
                                             invoiceable: p.match.invoiceable)
            if let learn { Store.save(learn) }
            model.edits[p.id] = nil
            await model.reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func registerAll(_ proposals: [Proposal]) async {
        busy = true
        defer { busy = false }
        var failed = 0
        for p in proposals {
            do {
                _ = try await teamleader.addTime(start: p.start, end: p.end, match: p.match, description: p.description,
                                                 invoiceable: p.match.invoiceable)
                model.edits[p.id] = nil
            } catch {
                failed += 1
                model.error = error.localizedDescription
            }
        }
        await model.reload()
        if failed > 0 { model.error = "\(failed) registratie(s) mislukt: \(model.error ?? "")" }
    }

    // MARK: Al in Teamleader

    @ViewBuilder
    private var registeredSection: some View {
        if !model.plan.registered.isEmpty {
            DisclosureGroup(isExpanded: $showRegistered) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.plan.registered.sorted { ($0.start ?? 0) < ($1.start ?? 0) }) { r in
                        HStack(spacing: 10) {
                            Text(r.start.map { "\(formatTime($0))–\(formatTime($0 + r.duration))" } ?? "zonder tijdstip")
                                .monospacedDigit()
                                .frame(width: 110, alignment: .leading)
                            RoundedRectangle(cornerRadius: 3).fill(Color.forName(r.companyName)).frame(width: 10, height: 10)
                            Text(r.companyName).fontWeight(.medium)
                            Text(r.description).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text(formatDuration(r.duration)).monospacedDigit()
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Al in Teamleader (\(model.plan.registered.count) · \(formatDuration(model.plan.registeredSeconds)))")
                    .font(.headline)
            }
        }
    }
}

// MARK: - Voorstelkaart

struct ProposalCard: View {
    @EnvironmentObject var teamleader: Teamleader
    let original: Proposal
    let canRegister: Bool
    let onRegister: (Proposal, Rule?) async -> String?
    let onDismiss: () -> Void

    @State private var proposal: Proposal
    @State private var remember = false
    @State private var working = false
    @State private var error: String?
    @State private var showDetails = false

    init(proposal: Proposal, canRegister: Bool,
         onRegister: @escaping (Proposal, Rule?) async -> String?, onDismiss: @escaping () -> Void) {
        original = proposal
        self.canRegister = canRegister
        self.onRegister = onRegister
        self.onDismiss = onDismiss
        _proposal = State(initialValue: DayModel.shared.edits[proposal.id] ?? proposal)
    }

    private var clientChanged: Bool { proposal.match.key != original.match.key }
    /// Enkel een klantspecifiek domein, programma of afspraaktitel is een goede kandidaat om te onthouden;
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
    ]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(formatTime(proposal.start)) – \(formatTime(proposal.end))")
                            .font(.title3.weight(.semibold)).monospacedDigit()
                        Text(formatDuration(proposal.duration)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .frame(width: 130, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        CompanyField(id: $proposal.match.companyId, name: $proposal.match.companyName, compact: true)
                        if proposal.match.isAssigned {
                            Text(reasonText).font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text("Niet herkend. Je werkte in: \(proposal.activities.prefix(2).joined(separator: ", "))")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        if let companyId = original.match.companyId, !clientChanged {
                            Button("Geen klant?") {
                                Matcher.exclude(companyId: companyId)
                                AppModel.shared.changed()
                            }
                            .buttonStyle(.link)
                            .help("\(original.match.companyName) is een leverancier of tool, geen klant: niet meer automatisch herkennen.")
                        }
                        Button(working ? "Bezig…" : "Registreer") {
                            Task { await submit() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRegister || !proposal.match.isAssigned || working)
                        Button("Negeer") { onDismiss() }
                            .buttonStyle(.link)
                            .help("Dit was geen werk (of je registreert het anders). Het voorstel verdwijnt.")
                    }
                }

                HStack(spacing: 10) {
                    TextField("Omschrijving (optioneel)", text: $proposal.description)
                        .textFieldStyle(.roundedBorder)
                    WorkTypePicker(id: $proposal.match.workTypeId, name: $proposal.match.workTypeName)
                        .labelsHidden()
                        .frame(width: 170)
                    Toggle("Factureerbaar", isOn: $proposal.match.invoiceable)
                }

                HStack {
                    Stepper("Start \(formatTime(proposal.start))", onIncrement: { move(start: 300) },
                            onDecrement: { move(start: -300) })
                    Stepper("Einde \(formatTime(proposal.end))", onIncrement: { move(end: 300) },
                            onDecrement: { move(end: -300) })
                    Spacer()
                    if learnable {
                        Toggle("Onthoud: ‘\(original.learnPattern)’ → \(proposal.match.companyName)", isOn: $remember)
                    }
                    Button(showDetails ? "Verberg details" : "Details") { showDetails.toggle() }.buttonStyle(.link)
                }
                .font(.callout)

                if showDetails {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(proposal.activities, id: \.self) { Text("• \($0)") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                }
            }
            .padding(6)
        }
        .onChange(of: proposal) { edited in
            // Bewaar aanpassingen in het model, zodat herladen of "Registreer alle" ze niet verliest.
            DayModel.shared.edits[original.id] = edited == original ? nil : edited
            if !learnable { remember = false }
        }
        .onChange(of: original) { fresh in
            // Nieuw berekend voorstel (bv. lopend blok werd langer): overnemen als er niets aangepast is.
            if DayModel.shared.edits[fresh.id] == nil { proposal = fresh }
        }
    }

    private var reasonText: String {
        if clientChanged { return "Door jou gekozen" }
        return proposal.reasons.isEmpty ? "" : "Omdat: " + proposal.reasons.joined(separator: " en ")
    }

    private func move(start delta: Double = 0, end deltaEnd: Double = 0) {
        let newStart = proposal.start + delta, newEnd = proposal.end + deltaEnd
        guard newEnd - newStart >= 300 else { return }
        proposal.start = newStart
        proposal.end = newEnd
    }

    private func submit() async {
        working = true
        defer { working = false }
        var rule: Rule?
        if remember && learnable {
            rule = Rule(field: "any", pattern: original.learnPattern, companyId: proposal.match.companyId,
                        companyName: proposal.match.companyName, workTypeId: proposal.match.workTypeId,
                        workTypeName: proposal.match.workTypeName, invoiceable: proposal.match.invoiceable)
        }
        error = await onRegister(proposal, rule)
    }
}

// MARK: - Tijdlijn met drie lanen

struct DayTimeline: View {
    let plan: DayPlan
    let day: Date

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
            let laneHeight: CGFloat = 26

            ZStack(alignment: .topLeading) {
                // Uurlijnen
                ForEach(Array(stride(from: t0, through: t1, by: 3600)), id: \.self) { t in
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 1, height: laneHeight * 3 + 16)
                        .offset(x: x(t))
                    Text(Date(timeIntervalSince1970: t).formatted(.dateTime.hour(.twoDigits(amPM: .omitted))))
                        .font(.caption2).foregroundStyle(.secondary)
                        .offset(x: x(t) - 8, y: laneHeight * 3 + 18)
                }
                lane("Teamleader", row: 0, height: laneHeight)
                lane("Voorstel", row: 1, height: laneHeight)
                lane("Activiteit", row: 2, height: laneHeight)

                ForEach(plan.registered.filter { $0.start != nil }) { r in
                    block(from: x(r.start!), to: x(r.end!), row: 0, height: laneHeight,
                          color: Color.forName(r.companyName), label: r.companyName,
                          help: "\(r.companyName)\n\(formatTime(r.start!))–\(formatTime(r.end!)) · \(r.description)")
                }
                ForEach(plan.proposals) { p in
                    block(from: x(p.start), to: x(p.end), row: 1, height: laneHeight,
                          color: p.match.isAssigned ? Color.forName(p.match.companyName).opacity(0.55) : Color.orange.opacity(0.45),
                          label: p.match.isAssigned ? p.match.companyName : "?", dashed: true,
                          help: "Voorstel: \(p.match.isAssigned ? p.match.companyName : "niet herkend")\n\(formatTime(p.start))–\(formatTime(p.end))")
                }
                ForEach(plan.activity) { a in
                    block(from: x(a.start), to: x(a.end), row: 2, height: laneHeight,
                          color: a.kind == .assigned ? Color.forName(a.label).opacity(0.8)
                              : a.kind == .skipped ? Color.gray.opacity(0.25) : Color.gray.opacity(0.55),
                          label: nil, help: "\(a.label)\n\(formatTime(a.start))–\(formatTime(a.end))")
                }
            }
        }
    }

    private func lane(_ title: String, row: Int, height: CGFloat) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(height: height)
            .offset(y: CGFloat(row) * (height + 4))
    }

    private func block(from a: CGFloat, to b: CGFloat, row: Int, height: CGFloat, color: Color, label: String?,
                       dashed: Bool = false, help: String) -> some View {
        let w = max(2, b - a)
        return RoundedRectangle(cornerRadius: 4)
            .fill(color)
            .overlay {
                if dashed {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(Color.primary.opacity(0.5))
                }
            }
            .overlay(alignment: .leading) {
                if let label, w > 50 {
                    Text(label).font(.caption2.weight(.semibold)).lineLimit(1).padding(.horizontal, 5)
                        .foregroundStyle(Color.black.opacity(0.75))
                }
            }
            .frame(width: w, height: height)
            .offset(x: a, y: CGFloat(row) * (height + 4))
            .help(help)
    }
}
