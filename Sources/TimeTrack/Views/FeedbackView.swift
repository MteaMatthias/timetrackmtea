import SwiftUI

/// Feedback van medewerkers: komt per mail bij MTEA toe (met je naam), zonder je activiteit.
struct FeedbackView: View {
    @EnvironmentObject var teamleader: Teamleader
    @State private var category = "idee"
    @State private var message = ""
    @State private var sending = false
    @State private var sent = false
    @State private var error: String?

    private static let categories: [(tag: String, label: String, icon: String)] = [
        ("idee", "Idee", "lightbulb"), ("fout", "Fout", "ladybug"), ("vraag", "Vraag", "questionmark.bubble"),
        ("anders", "Anders", "ellipsis.bubble"),
    ]
    private static let mailAddress = "info@mtea.be"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Feedback").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Iets dat beter kan, een fout of een vraag? Laat het ons weten, zo wordt TimeTrack beter voor iedereen.")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Soort", selection: $category) {
                        ForEach(Self.categories, id: \.tag) { c in Label(c.label, systemImage: c.icon).tag(c.tag) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $message)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                        if message.isEmpty {
                            Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: 200)
                    HStack(spacing: 12) {
                        Label("Je feedback gaat met je naam naar MTEA. Je activiteit wordt niet meegestuurd.",
                              systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await send() }
                        } label: {
                            if sending { ProgressView().controlSize(.small) } else { Label("Verstuur", systemImage: "paperplane.fill") }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(trimmed.isEmpty || sending)
                    }
                }
                .card()
                if sent {
                    Banner(icon: "checkmark.circle.fill", tint: .green, text: "Bedankt! Je feedback is verstuurd.")
                }
                if let error {
                    Banner(icon: "exclamationmark.triangle.fill", tint: .orange, text: error) {
                        Button("Via mail sturen") { openMail() }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var placeholder: String {
        switch category {
        case "fout": return "Wat deed je, wat gebeurde er en wat had je verwacht?"
        case "vraag": return "Wat wil je weten?"
        default: return "Wat zou TimeTrack voor jou handiger maken?"
        }
    }

    private func send() async {
        sending = true
        sent = false
        error = nil
        defer { sending = false }
        guard teamleader.isConnected else {
            error = "Verbind eerst met Teamleader (Instellingen), of stuur je feedback via mail."
            return
        }
        do {
            try await teamleader.sendFeedback(trimmed, category: category)
            sent = true
            message = ""
        } catch {
            self.error = "Versturen lukte niet (\(error.localizedDescription)). Stuur je feedback via mail."
        }
    }

    private func openMail() {
        let label = Self.categories.first { $0.tag == category }?.label ?? "Feedback"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.mailAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: "TimeTrack-feedback (\(label))"),
            URLQueryItem(name: "body", value: trimmed + "\n\n— TimeTrack \(Updater.shared.current)"),
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
