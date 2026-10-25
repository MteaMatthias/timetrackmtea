import SwiftUI

struct EntriesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var teamleader: Teamleader

    @State private var weekStart = Date().startOfWeek
    @State private var entries: [Entry] = []
    @State private var selection = Set<Int64>()
    @State private var editing: Entry?
    @State private var pushing = false
    @State private var status: String?

    private var weekEnd: Date { Calendar.current.date(byAdding: .day, value: 6, to: weekStart)! }

    /// Te versturen: de selectie, of anders alles wat klaar staat in deze week.
    private var toPush: [Entry] {
        let candidates = selection.isEmpty ? entries : entries.filter { selection.contains($0.id) }
        return candidates.filter(\.isReady)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { shift(-7) } label: { Image(systemName: "chevron.left") }
                Text("Week van \(weekStart.formatted(date: .abbreviated, time: .omitted)) t/m \(weekEnd.formatted(date: .abbreviated, time: .omitted))")
                    .font(.headline)
                Button { shift(7) } label: { Image(systemName: "chevron.right") }
                Button("Deze week") { weekStart = Date().startOfWeek }
                Spacer()
                Button("Nieuwe registratie") {
                    let nine = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
                    editing = Entry(start: nine.timeIntervalSince1970)
                }
                Button(pushing ? "Bezig met versturen…" : "Verstuur naar Teamleader (\(toPush.count))") {
                    Task { await push() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pushing || toPush.isEmpty || !teamleader.isConnected)
            }

            if !teamleader.isConnected {
                Label("Niet verbonden met Teamleader. Verbind eerst via Instellingen.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let status {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }

            Table(entries, selection: $selection) {
                TableColumn("Datum") { e in
                    Text(e.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                }
                .width(90)
                TableColumn("Start") { e in Text(formatTime(e.start)).monospacedDigit() }.width(50)
                TableColumn("Duur") { e in Text(formatMinutes(e.minutes)).monospacedDigit() }.width(60)
                TableColumn("Klant") { e in
                    Text(e.companyName.isEmpty ? "—" : e.companyName)
                        .foregroundStyle(e.companyId == nil ? Color.orange : Color.primary)
                }
                TableColumn("Werksoort") { e in Text(e.workTypeName.isEmpty ? "—" : e.workTypeName) }
                    .width(min: 80, ideal: 110)
                TableColumn("Omschrijving") { e in Text(e.description).lineLimit(1).help(e.description) }
                TableColumn("Fact.") { e in Image(systemName: e.invoiceable ? "checkmark" : "minus") }.width(36)
                TableColumn("Status") { e in StatusLabel(entry: e) }.width(min: 110, ideal: 140)
            }
            .contextMenu(forSelectionType: Int64.self) { ids in
                if ids.count == 1, let entry = entries.first(where: { $0.id == ids.first }), !entry.isPushed {
                    Button("Bewerken…") { editing = entry }
                }
                Button("Verwijderen (enkel in TimeTrack)", role: .destructive) {
                    ids.forEach(Store.delete(entryId:))
                    model.changed()
                }
            } primaryAction: { ids in
                if let entry = entries.first(where: { $0.id == ids.first }), !entry.isPushed { editing = entry }
            }

            HStack {
                let total = entries.reduce(0) { $0 + $1.minutes }
                let sent = entries.filter(\.isPushed).reduce(0) { $0 + $1.minutes }
                Text("Totaal week: \(formatMinutes(total)) · verstuurd: \(formatMinutes(sent))")
                Spacer()
                Text("Dubbelklik om te bewerken. Zonder selectie wordt alles wat klaarstaat verstuurd.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(16)
        .onAppear(perform: load)
        .onChange(of: weekStart) { _ in load() }
        .onChange(of: model.revision) { _ in load() }
        .sheet(item: $editing) { entry in
            EntryEditor(entry: entry) { model.changed() }
        }
    }

    private func shift(_ days: Int) {
        weekStart = Calendar.current.date(byAdding: .day, value: days, to: weekStart) ?? weekStart
    }

    private func load() {
        entries = Store.entries(from: weekStart, to: weekEnd)
        selection = selection.filter { id in entries.contains { $0.id == id } }
    }

    private func push() async {
        pushing = true
        var ok = 0, failed = 0
        for entry in toPush {
            do {
                let id = try await teamleader.addTime(entry)
                Store.markPushed(entry.id, teamleaderId: id)
                ok += 1
            } catch {
                Store.markError(entry.id, error.localizedDescription)
                failed += 1
            }
        }
        pushing = false
        status = failed == 0 ? "\(ok) registratie(s) verstuurd naar Teamleader."
                             : "\(ok) verstuurd, \(failed) mislukt. Zie de kolom Status."
        model.changed()
    }
}

struct StatusLabel: View {
    let entry: Entry

    var body: some View {
        if entry.isPushed {
            Label("Verstuurd", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if let error = entry.error {
            Label("Fout", systemImage: "xmark.octagon.fill").foregroundStyle(.red).help(error)
        } else if entry.companyId == nil {
            Label("Klant ontbreekt", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        } else {
            Label("Klaar", systemImage: "circle").foregroundStyle(.secondary)
        }
    }
}

struct EntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entry: Entry
    @State private var start: Date
    let onSave: () -> Void

    init(entry: Entry, onSave: @escaping () -> Void) {
        _entry = State(initialValue: entry)
        _start = State(initialValue: entry.startDate)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                DatePicker("Start", selection: $start)
                HStack {
                    TextField("Duur (minuten)", value: $entry.minutes, format: .number)
                    Stepper("", value: $entry.minutes, in: 0...1440, step: 15).labelsHidden()
                    Text(formatMinutes(entry.minutes)).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                }
                CompanyField(id: $entry.companyId, name: $entry.companyName)
                WorkTypePicker(id: $entry.workTypeId, name: $entry.workTypeName)
                TextField("Omschrijving", text: $entry.description, axis: .vertical)
                    .lineLimit(2...6)
                Toggle("Factureerbaar", isOn: $entry.invoiceable)
            }
            .formStyle(.grouped)

            HStack {
                if entry.id != 0 {
                    Button("Verwijderen", role: .destructive) {
                        Store.delete(entryId: entry.id)
                        onSave()
                        dismiss()
                    }
                }
                Spacer()
                Button("Annuleren") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Opslaan") {
                    entry.start = start.timeIntervalSince1970
                    entry.auto = false
                    Store.save(entry)
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entry.minutes <= 0)
            }
            .padding(16)
        }
        .frame(width: 520)
    }
}

/// Zoekt en kiest een bedrijf uit Teamleader.
struct CompanyField: View {
    @EnvironmentObject var teamleader: Teamleader
    @Binding var id: String?
    @Binding var name: String
    @State private var query = ""
    @State private var results: [TLItem] = []
    @State private var searchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Klant")
                Spacer()
                if name.isEmpty {
                    Text("geen").foregroundStyle(.secondary)
                } else {
                    Text(name).bold()
                    if id == nil { Text("(niet gekoppeld)").foregroundStyle(.orange) }
                    Button { id = nil; name = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            if teamleader.isConnected {
                TextField("Zoek bedrijf in Teamleader…", text: $query)
                ForEach(results) { item in
                    Button(item.name) {
                        id = item.id
                        name = item.name
                        query = ""
                        results = []
                    }
                    .buttonStyle(.link)
                }
            } else {
                Text("Verbind met Teamleader om een klant te kiezen.").font(.caption).foregroundStyle(.secondary)
            }
            if let searchError {
                Text(searchError).font(.caption).foregroundStyle(.red)
            }
        }
        .task(id: query) {
            guard query.count >= 2 else { results = []; return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            do {
                results = try await teamleader.searchCompanies(query)
                searchError = results.isEmpty ? "Geen bedrijven gevonden." : nil
            } catch {
                searchError = error.localizedDescription
            }
        }
    }
}

struct WorkTypePicker: View {
    @EnvironmentObject var teamleader: Teamleader
    @Binding var id: String?
    @Binding var name: String

    var body: some View {
        Picker("Werksoort", selection: Binding(
            get: { id ?? "" },
            set: { newId in
                id = newId.isEmpty ? nil : newId
                name = teamleader.workTypes.first { $0.id == newId }?.name ?? ""
            }
        )) {
            Text("—").tag("")
            ForEach(teamleader.workTypes) { Text($0.name).tag($0.id) }
            if let id, !teamleader.workTypes.contains(where: { $0.id == id }) {
                Text(name.isEmpty ? id : name).tag(id)
            }
        }
    }
}
