import SwiftUI

private let fieldLabels = ["title": "Venstertitel bevat", "app": "Programma bevat", "any": "Programma of titel bevat"]

struct RulesView: View {
    @EnvironmentObject var model: AppModel
    @State private var rules: [Rule] = []
    @State private var editing: Rule?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Regels koppelen activiteiten automatisch aan een klant. Ze gelden ook voor tijd die al geregistreerd is.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Nieuwe regel") { editing = Rule() }.buttonStyle(.borderedProminent)
            }
            Table(rules) {
                TableColumn("Voorwaarde") { r in Text(fieldLabels[r.field] ?? r.field).foregroundStyle(.secondary) }
                    .width(min: 140, ideal: 170)
                TableColumn("Trefwoorden") { r in Text(r.pattern).font(.body.monospaced()).lineLimit(1) }
                TableColumn("Klant") { r in Text(r.targetLabel).foregroundStyle(r.skip ? .secondary : .primary) }
                TableColumn("Werksoort") { r in Text(r.workTypeName.isEmpty ? "—" : r.workTypeName) }
                    .width(min: 80, ideal: 110)
                TableColumn("Omschrijving") { r in Text(r.description.isEmpty ? "(venstertitels)" : r.description).lineLimit(1) }
                TableColumn("") { r in Button("Bewerken…") { editing = r } }.width(90)
            }
            Text("Volgorde: titelregels gaan voor programmaregels; bij meerdere treffers wint het langste patroon.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .onAppear(perform: load)
        .onChange(of: model.revision) { _ in load() }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule) { model.changed() }
        }
    }

    private func load() { rules = Store.rules() }
}

struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rule: Rule
    let onSave: () -> Void

    init(rule: Rule, onSave: @escaping () -> Void) {
        _rule = State(initialValue: rule)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Voorwaarde", selection: $rule.field) {
                    ForEach(["title", "app", "any"], id: \.self) { Text(fieldLabels[$0]!).tag($0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Trefwoorden", text: $rule.pattern)
                    Text("Hoofdletters maken niet uit. Meerdere trefwoorden scheiden met | (bv. Janssen | JNS-2026). Maak het zo kort mogelijk, bv. enkel de klantnaam.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Negeren (privé, niet registreren)", isOn: $rule.skip)
                if !rule.skip {
                    CompanyField(id: $rule.companyId, name: $rule.companyName)
                    WorkTypePicker(id: $rule.workTypeId, name: $rule.workTypeName)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Vaste omschrijving (optioneel)", text: $rule.description)
                        Text("Leeg = de belangrijkste venstertitels worden de omschrijving.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if rule.id != 0 {
                    Button("Verwijderen", role: .destructive) {
                        Store.delete(rule: rule)
                        onSave()
                        dismiss()
                    }
                }
                Spacer()
                Button("Annuleren") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Opslaan") {
                    rule.pattern = rule.pattern.trimmingCharacters(in: .whitespaces)
                    Store.save(rule)
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rule.pattern.trimmingCharacters(in: .whitespaces).isEmpty
                          || (!rule.skip && rule.companyName.isEmpty))
            }
            .padding(16)
        }
        .frame(width: 540)
    }
}
