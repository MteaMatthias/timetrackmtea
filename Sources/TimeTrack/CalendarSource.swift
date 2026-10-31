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

    /// Agenda's die meetellen: geen abonnementen of verjaardagen, geen agenda's die de gebruiker uitzette.
    var calendars: [EKCalendar] {
        guard Self.isAuthorized else { return [] }
        return store.calendars(for: .event).filter { $0.type != .subscription && $0.type != .birthday }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var excludedCalendars: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "excludedCalendars") ?? []) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(Array(newValue), forKey: "excludedCalendars")
        }
    }

    /// Afspraken waarvoor je als "bezet" staat en die je zelf organiseerde of aanvaardde
    /// (geen onbeantwoorde of geweigerde uitnodigingen, geen hele-dag-items).
    func events(from lo: Double, to hi: Double) -> [CalendarEvent] {
        guard isEnabled else { return [] }
        let excluded = excludedCalendars
        let selected = calendars.filter { !excluded.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: Date(timeIntervalSince1970: lo),
                                                 end: Date(timeIntervalSince1970: hi), calendars: selected)
        return store.events(matching: predicate).compactMap { e -> CalendarEvent? in
            guard !e.isAllDay, e.availability != .free else { return nil }
            let attendees = e.attendees ?? []
            if !attendees.isEmpty {
                let organizer = e.organizer?.isCurrentUser ?? false
                let accepted = attendees.contains { $0.isCurrentUser && $0.participantStatus == .accepted }
                guard organizer || accepted else { return nil }
            }
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
