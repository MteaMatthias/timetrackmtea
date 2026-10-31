import EventKit
import Foundation

struct CalendarEvent {
    let start: Double
    let end: Double
    let title: String
    let attendeeEmails: [String]
}

/// Leest afspraken uit de agenda's op deze Mac (iCloud, Google, Microsoft 365, Exchange…).
/// Een vergadering telt als werk, ook als je ondertussen niets aanraakt.
final class CalendarSource: ObservableObject {
    static let shared = CalendarSource()
    private let store = EKEventStore()

    @Published private(set) var authorized = CalendarSource.isAuthorized

    static var isAuthorized: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14, *) { return status == .fullAccess }
        return status == .authorized
    }

    var isEnabled: Bool { Self.isAuthorized && !UserDefaults.standard.bool(forKey: "calendarDisabled") }

    func requestAccess() async {
        do {
            if #available(macOS 14, *) {
                _ = try await store.requestFullAccessToEvents()
            } else {
                _ = try await store.requestAccess(to: .event)
            }
        } catch {
            NSLog("Agenda-toegang: %@", error.localizedDescription)
        }
        await MainActor.run { self.authorized = Self.isAuthorized }
    }

    /// Afspraken die je niet geweigerd hebt en waarvoor je als "bezet" staat; geen hele-dag-items.
    func events(from lo: Double, to hi: Double) -> [CalendarEvent] {
        guard isEnabled else { return [] }
        let predicate = store.predicateForEvents(withStart: Date(timeIntervalSince1970: lo),
                                                 end: Date(timeIntervalSince1970: hi), calendars: nil)
        return store.events(matching: predicate).compactMap { e -> CalendarEvent? in
            guard !e.isAllDay, e.availability != .free else { return nil }
            let attendees = e.attendees ?? []
            if attendees.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) { return nil }
            let emails = attendees.filter { !$0.isCurrentUser }.compactMap { p -> String? in
                let s = p.url.absoluteString
                return s.lowercased().hasPrefix("mailto:") ? String(s.dropFirst(7)).lowercased() : nil
            }
            return CalendarEvent(start: max(e.startDate.timeIntervalSince1970, lo),
                                 end: min(e.endDate.timeIntervalSince1970, hi),
                                 title: e.title ?? "", attendeeEmails: emails)
        }
    }
}
