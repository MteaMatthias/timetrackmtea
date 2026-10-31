import SwiftUI

/// Week in één oogopslag: per dag wat al in Teamleader staat en wat nog open is.
struct WeekView: View {
    @EnvironmentObject var dayModel: DayModel
    @EnvironmentObject var teamleader: Teamleader
    @EnvironmentObject var appModel: AppModel
    @Binding var tab: Int

    @State private var weekStart = Date().startOfWeek
    @State private var days: [Summary] = []
    @State private var loading = false
    @State private var error: String?

    struct Summary: Identifiable {
        let id: Date
        let worked: Double
        let registered: Double
        let proposed: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                Button { shift(-7) } label: { Image(systemName: "chevron.left") }
                Text("Week van \(weekStart.formatted(.dateTime.day().month(.wide)))").font(.title2.weight(.semibold))
                Button { shift(7) } label: { Image(systemName: "chevron.right") }
                Button("Deze week") { weekStart = Date().startOfWeek }
                Spacer()
                Stat(label: "Gewerkt", value: formatDuration(days.reduce(0) { $0 + $1.worked }))
                Stat(label: "In Teamleader", value: formatDuration(days.reduce(0) { $0 + $1.registered }), color: .green)
                Stat(label: "Nog te registreren", value: formatDuration(days.reduce(0) { $0 + $1.proposed }), color: .orange)
                if loading { ProgressView().controlSize(.small) }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }

            let maxHours = max(9, (days.map { max($0.worked, $0.registered + $0.proposed) }.max() ?? 0) / 3600)
            HStack(alignment: .bottom, spacing: 18) {
                ForEach(days) { d in
                    Button {
                        dayModel.day = d.id
                        tab = 0
                    } label: {
                        VStack(spacing: 6) {
                            Text(formatDuration(d.registered + d.proposed)).font(.caption).monospacedDigit()
                            GeometryReader { geo in
                                let scale = geo.size.height / CGFloat(maxHours * 3600)
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.6))
                                        .frame(height: CGFloat(d.proposed) * scale)
                                    RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.8))
                                        .frame(height: CGFloat(d.registered) * scale)
                                }
                            }
                            .frame(height: 220)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))
                            Text(d.id.formatted(.dateTime.weekday(.abbreviated).day()))
                                .fontWeight(Calendar.current.isDateInToday(d.id) ? .bold : .regular)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Klik om deze dag te bekijken")
                }
            }
            HStack(spacing: 16) {
                Label("In Teamleader", systemImage: "square.fill").foregroundStyle(.green)
                Label("Nog te registreren", systemImage: "square.fill").foregroundStyle(.orange)
                Spacer()
                Text("Klik op een dag om de voorstellen te bevestigen.").foregroundStyle(.secondary)
            }
            .font(.callout)
            Spacer()
        }
        .padding(20)
        .task(id: weekStart) { await load() }
        .onChange(of: appModel.revision) { _ in Task { await load() } }
    }

    private func shift(_ n: Int) {
        weekStart = Calendar.current.date(byAdding: .day, value: n, to: weekStart) ?? weekStart
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let dates = (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: weekStart) }
        let (lo, _) = Store.dayBounds(dates.first ?? weekStart)
        let (_, hi) = Store.dayBounds(dates.last ?? weekStart)
        var registered: [Registered] = []
        if teamleader.isConnected {
            do {
                registered = try await teamleader.registered(from: lo, to: hi)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
        let matcher = Matcher(ownDomain: UserDefaults.standard.string(forKey: "tlOwnDomain"))
        days = dates.map { d in
            let (a, b) = Store.dayBounds(d)
            let mine = registered.filter { r in
                guard let s = r.start else { return false }
                return s >= a && s < b
            }
            let plan = Planner.plan(day: d, registered: mine, matcher: matcher, roundTo: Prefs.roundTo)
            return Summary(id: d, worked: plan.worked, registered: plan.registeredSeconds, proposed: plan.proposedSeconds)
        }
    }
}
