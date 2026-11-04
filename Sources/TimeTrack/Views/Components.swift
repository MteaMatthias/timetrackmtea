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
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(results) { item in
                            Button(item.name) { pick(item.id, item.name) }.buttonStyle(.link)
                        }
                        Button(internalLabel) { pick(nil, internalLabel) }
                            .buttonStyle(.link)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 130)
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

// MARK: - Vormgeving

extension View {
    /// Afgeronde kaart met zachte rand en schaduw (de basis van elk scherm).
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

/// Ronde badge met initialen in de vaste kleur van de klant.
struct Avatar: View {
    let name: String
    var size: CGFloat = 34

    private var initials: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var body: some View {
        Circle()
            .fill(name.isEmpty ? Color.orange.gradient : Color.forName(name).gradient)
            .frame(width: size, height: size)
            .overlay(Text(name.isEmpty ? "?" : initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white))
    }
}

/// Grote tegel met een cijfer (Gewerkt, In Teamleader, Te registreren).
struct MetricTile: View {
    let icon: String
    let title: String
    let value: String
    var tint: Color = .accentColor
    var footnote: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                if let footnote {
                    Text(footnote).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
    }
}

/// Klein label met een tijdsblok; klikbaar om het blok aan een andere klant toe te wijzen.
struct BlockChip: View {
    let part: Proposal.Part
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Text("\(formatTime(part.start))–\(formatTime(part.end))").monospacedDigit()
            Text(formatDuration(part.end - part.start)).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.25)))
        .contentShape(Capsule())
    }
}

/// Popover om een blok (of een deel ervan) aan een klant toe te wijzen of te negeren.
struct BlockAssignView: View {
    @EnvironmentObject var teamleader: Teamleader
    let part: Proposal.Part
    let current: String
    var pieces: [Proposal.Piece] = []
    let onDone: () -> Void
    @State private var companyId: String?
    @State private var companyName = ""
    @State private var openPiece: String?
    @State private var pieceCompanyId: String?
    @State private var pieceCompanyName = ""

    /// De delen binnen dit blok (enkel tonen als er meer dan één soort activiteit was).
    private var inside: [Proposal.Piece] {
        pieces.filter { $0.end > part.start && $0.start < part.end }
            .map { Proposal.Piece(start: max($0.start, part.start), end: min($0.end, part.end), label: $0.label) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(formatTime(part.start)) – \(formatTime(part.end))").font(.headline).monospacedDigit()
                Text(formatDuration(part.end - part.start)).foregroundStyle(.secondary)
                Spacer()
                Text(current.isEmpty ? "niet toegewezen" : current).font(.callout).foregroundStyle(.secondary)
            }
            Text("Hele blok").font(.subheadline.weight(.semibold))
            HStack(alignment: .top) {
                CompanyField(id: $companyId, name: $companyName, compact: true)
                Button("Toewijzen") {
                    Store.assign(start: part.start, end: part.end, to: Match(companyId: companyId, companyName: companyName))
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .disabled(companyName.isEmpty)
                Button("Geen werk") {
                    Store.dismiss(start: part.start, end: part.end)
                    onDone()
                }
            }
            if inside.count > 1 {
                Divider()
                Text("Of per deel").font(.subheadline.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(inside) { piece in pieceRow(piece) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 560, height: inside.count > 1 ? 460 : 260, alignment: .topLeading)
    }

    @ViewBuilder
    private func pieceRow(_ piece: Proposal.Piece) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(formatTime(piece.start))–\(formatTime(piece.end))").monospacedDigit().frame(width: 96, alignment: .leading)
                Text(piece.label).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(formatDuration(piece.end - piece.start)).foregroundStyle(.secondary).monospacedDigit()
                Button(openPiece == piece.id ? "Sluiten" : "Klant…") {
                    openPiece = openPiece == piece.id ? nil : piece.id
                    pieceCompanyId = nil
                    pieceCompanyName = ""
                }
                .buttonStyle(.link)
            }
            if openPiece == piece.id {
                HStack(alignment: .top) {
                    CompanyField(id: $pieceCompanyId, name: $pieceCompanyName, compact: true)
                    Button("Toewijzen") {
                        Store.assign(start: piece.start, end: piece.end,
                                     to: Match(companyId: pieceCompanyId, companyName: pieceCompanyName))
                        onDone()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pieceCompanyName.isEmpty)
                    Button("Geen werk") {
                        Store.dismiss(start: piece.start, end: piece.end)
                        onDone()
                    }
                }
                .padding(.leading, 104)
            }
        }
        .font(.callout)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

/// Eén activiteit binnen een voorstel (bv. één mail) aan een klant toewijzen, met de keuze om dat te onthouden.
struct ActivityAssignView: View {
    @EnvironmentObject var teamleader: Teamleader
    let label: String
    let pieces: [Proposal.Piece]
    let onDone: () -> Void
    @State private var companyId: String?
    @State private var companyName = ""
    @State private var remember = false

    /// Wat onthouden kan worden: het onderwerp of de titel zonder "Re:", "Fwd:"… (nooit een algemene site).
    static func learnPattern(_ label: String) -> String? {
        guard let colon = label.range(of: ": ") else { return nil }
        var text = String(label[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        while let r = text.range(of: #"^(re|fw|fwd|tr|antw|doorst|aw|wg)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(r)
        }
        text = text.replacingOccurrences(of: "|", with: " ").trimmingCharacters(in: .whitespaces).lowercased()
        guard text.count >= 6, !Matcher.isGeneric(text), !text.hasPrefix("alle inkomende"),
              !text.contains("ongelezen") else { return nil }
        return text
    }

    private var total: Double { pieces.reduce(0) { $0 + $1.end - $1.start } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label).font(.headline).lineLimit(2)
            Text(pieces.map { "\(formatTime($0.start))–\(formatTime($0.end))" }.joined(separator: ", ")
                 + " · " + formatDuration(total))
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            HStack(alignment: .top) {
                CompanyField(id: $companyId, name: $companyName, compact: true)
                Button("Toewijzen") {
                    let match = Match(companyId: companyId, companyName: companyName)
                    for p in pieces { Store.assign(start: p.start, end: p.end, to: match) }
                    if remember, let pattern = Self.learnPattern(label) {
                        Store.save(Rule(field: "title", pattern: pattern, companyId: companyId, companyName: companyName))
                    }
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .disabled(companyName.isEmpty)
                Button("Geen werk") {
                    for p in pieces { Store.dismiss(start: p.start, end: p.end) }
                    onDone()
                }
            }
            if let pattern = Self.learnPattern(label) {
                Toggle("Onthoud: voortaan ‘\(pattern)’ → \(companyName.isEmpty ? "deze klant" : companyName)", isOn: $remember)
                    .font(.callout).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 520, height: 300, alignment: .topLeading)
    }
}
