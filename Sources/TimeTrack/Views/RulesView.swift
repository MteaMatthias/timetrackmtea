import SwiftUI

private let fieldLabels = ["any": "Programma, titel of website bevat", "title": "Titel of website bevat", "app": "Programma bevat"]

struct RulesView: View {
    @EnvironmentObject var model: AppModel
    @State private var rules: [Rule] = []
    @State private var editing: Rule?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Klanten worden automatisch herkend via Teamleader (naam, website, e-maildomein). Hier corrigeer je wat verkeerd of niet herkend wordt, of negeer je privé-activiteit.")
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
                TableColumn("Factureerbaar") { r in Image(systemName: r.invoiceable && !r.skip ? "checkmark" : "minus") }.width(90)
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
                    ForEach(["any", "title", "app"], id: \.self) { Text(fieldLabels[$0]!).tag($0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Trefwoorden", text: $rule.pattern)
                    Text("Bv. een domein (klantx.be), een projectcode of een naam. Hoofdletters maken niet uit; meerdere trefwoorden scheiden met |.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Negeren (privé, niet registreren)", isOn: $rule.skip)
                if !rule.skip {
                    CompanyField(id: $rule.companyId, name: $rule.companyName)
                    WorkTypePicker(id: $rule.workTypeId, name: $rule.workTypeName)
                    TextField("Vaste omschrijving (optioneel)", text: $rule.description)
                    Toggle("Factureerbaar", isOn: $rule.invoiceable)
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
