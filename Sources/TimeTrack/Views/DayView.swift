import SwiftUI

struct DayView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("roundTo") private var roundTo = 15

    @State private var day = Date()
    @State private var segments: [Segment] = []
    @State private var groups: [ActivityGroup] = []
    @State private var search = ""
    @State private var onlyUnassigned = false
    @State private var ruleDraft: Rule?
    @State private var message: String?

    private var worked: Double { segments.filter(\.counts).reduce(0) { $0 + $1.duration } }

    private struct Total: Identifiable {
        var id: String { label }
        let label: String
        let seconds: Double
    }

    private var totals: [Total] {
        var map: [String: Double] = [:]
        for s in segments where s.counts { map[s.label, default: 0] += s.duration }
        return map.sorted { $0.value > $1.value }.map { Total(label: $0.key, seconds: $0.value) }
    }

    private var visibleGroups: [ActivityGroup] {
        groups.filter { g in
            (!onlyUnassigned || g.rule == nil)
                && (search.isEmpty || "\(g.app) \(g.title)".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                DatePicker("Dag", selection: $day, displayedComponents: .date)
                    .labelsHidden()
                    .frame(width: 120)
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                Button("Vandaag") { day = Date() }
                Spacer()
                Text("Gewerkt: \(formatDuration(worked))").font(.headline)
                Button("Maak registraties voor deze dag") { generate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(segments.isEmpty)
            }

            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                TimelineBar(segments: Store.merged(segments)).frame(height: 32)
                if let first = segments.first, let last = segments.last {
                    HStack {
                        Text(formatTime(first.start))
                        Spacer()
                        Text(formatTime(last.end))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Geen activiteit op deze dag.").font(.caption).foregroundStyle(.secondary)
                }
            }

            if !totals.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(totals) { t in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(t.label == "Niet toegewezen" ? Color.gray : Color.forName(t.label))
                                    .frame(width: 10, height: 10)
                                Text(t.label)
                                Text(formatDuration(t.seconds)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }

            HStack {
                TextField("Zoek in programma of venstertitel", text: $search)
                    .textFieldStyle(.roundedBorder)
                Toggle("Enkel niet toegewezen", isOn: $onlyUnassigned)
            }

            Table(visibleGroups) {
                TableColumn("Venster") { g in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.title.isEmpty ? "(zonder titel)" : g.title).lineLimit(1).help(g.title)
                        Text(g.app).font(.caption).foregroundStyle(.secondary)
                    }
                }
                TableColumn("Toegewezen aan") { g in
                    if let rule = g.rule {
                        Text(rule.targetLabel).foregroundStyle(rule.skip ? .secondary : .primary)
                    } else {
                        Text("Niet toegewezen").foregroundStyle(.orange)
                    }
                }
                .width(min: 120, ideal: 180)
                TableColumn("Tijd") { g in
                    Text(formatDuration(g.seconds)).monospacedDigit()
                }
                .width(70)
                TableColumn("") { g in
                    Button(g.rule == nil ? "Toewijzen…" : "Nieuwe regel…") {
                        ruleDraft = Rule(field: "title", pattern: g.title.isEmpty ? g.app : g.title)
                    }
                }
                .width(110)
            }
        }
        .padding(16)
        .onAppear(perform: load)
        .onChange(of: day) { _ in load(); message = nil }
        .onChange(of: model.revision) { _ in load() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if Calendar.current.isDateInToday(day) { load() }
        }
        .sheet(item: $ruleDraft) { rule in
            RuleEditor(rule: rule) { model.changed() }
        }
    }

    private func shift(_ days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day) ?? day
    }

    private func load() {
        segments = Store.segments(day: day)
        groups = Store.groups(of: segments)
    }

    private func generate() {
        let result = Store.generateDrafts(day: day, roundTo: roundTo)
        var text = result.created == 0
            ? "Geen nieuwe registraties: alles is al voorbereid of verstuurd."
            : "\(result.created) registratie(s) klaargezet in het tabblad Registraties."
        if result.unassigned >= 60 {
            text += " Let op: \(formatDuration(result.unassigned)) is nog niet toegewezen."
        }
        message = text
        model.changed()
    }
}

struct TimelineBar: View {
    let segments: [Segment]

    var body: some View {
        GeometryReader { geo in
            let t0 = segments.first?.start ?? 0
            let span = max((segments.last?.end ?? 1) - t0, 1)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.secondary.opacity(0.12))
                ForEach(segments) { s in
                    Rectangle()
                        .fill(s.color)
                        .frame(width: max(1, s.duration / span * geo.size.width), height: geo.size.height)
                        .offset(x: (s.start - t0) / span * geo.size.width)
                        .help("\(s.label)\n\(formatTime(s.start)) – \(formatTime(s.end)) (\(formatDuration(s.duration)))")
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
