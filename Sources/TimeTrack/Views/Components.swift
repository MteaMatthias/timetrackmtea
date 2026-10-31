import SwiftUI

/// Naam voor werk zonder klant in Teamleader (registratie zonder onderwerp).
let internalLabel = "Intern (geen klant)"

/// Zoekt en kiest een bedrijf uit Teamleader, of "intern".
struct CompanyField: View {
    @EnvironmentObject var teamleader: Teamleader
    @Binding var id: String?
    @Binding var name: String
    var compact = false
    @State private var query = ""
    @State private var results: [TLItem] = []
    @State private var searchError: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if !compact { Text("Klant") }
                if name.isEmpty {
                    TextField("Zoek klant…", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .frame(minWidth: 180)
                } else {
                    Label(name, systemImage: id == nil ? "building.2" : "building.2.fill")
                        .labelStyle(.titleAndIcon)
                        .fontWeight(.semibold)
                    Button { id = nil; name = ""; focused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Andere klant kiezen")
                }
                Spacer(minLength: 0)
            }
            if name.isEmpty && (!results.isEmpty || query.count >= 2) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(results) { item in
                        Button(item.name) { pick(item.id, item.name) }.buttonStyle(.link)
                    }
                    Button(internalLabel) { pick(nil, internalLabel) }
                        .buttonStyle(.link)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, compact ? 0 : 44)
            }
            if let searchError {
                Text(searchError).font(.caption).foregroundStyle(.red)
            }
        }
        .task(id: query) {
            guard query.count >= 2 else { results = []; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                results = try await teamleader.searchCompanies(query)
                searchError = nil
            } catch {
                searchError = error.localizedDescription
            }
        }
    }

    private func pick(_ newId: String?, _ newName: String) {
        id = newId
        name = newName
        query = ""
        results = []
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

/// Kleine samenvatting: label met grote waarde.
struct Stat: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
        }
    }
}

/// Status van een toestemming of koppeling, met een knop om ze in orde te brengen.
struct CheckRow<Action: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            action()
        }
        .padding(.vertical, 6)
    }
}
