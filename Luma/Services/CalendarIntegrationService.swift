import EventKit
import Foundation
import Observation

struct CalendarCommitment: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
}

struct CalendarDestination: Identifiable, Equatable {
    let id: String
    let title: String
    let accountName: String
    let isGoogle: Bool

    var displayName: String {
        isGoogle ? "Google · \(title)" : "\(title) · \(accountName)"
    }
}

@MainActor
@Observable
final class CalendarIntegrationService {
    private static let enabledKey = "lumaCalendarIntegrationEnabled"
    private static let automaticTasksKey = "lumaCalendarAutomaticTasksEnabled"
    private static let selectedCalendarKey = "lumaSelectedCalendarIdentifier"
    private static let eventIdentifierPrefix = "lumaCalendarEventIdentifier."
    private let store = EKEventStore()
    private let defaults = UserDefaults.standard

    private(set) var isAuthorized = false
    private(set) var commitments: [CalendarCommitment] = []
    private(set) var availableCalendars: [CalendarDestination] = []
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }
    var autoSyncTasks: Bool {
        didSet { defaults.set(autoSyncTasks, forKey: Self.automaticTasksKey) }
    }
    var selectedCalendarIdentifier: String? {
        didSet {
            defaults.set(selectedCalendarIdentifier, forKey: Self.selectedCalendarKey)
            lastError = nil
        }
    }

    init() {
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        autoSyncTasks = defaults.object(forKey: Self.automaticTasksKey) as? Bool ?? true
        selectedCalendarIdentifier = defaults.string(forKey: Self.selectedCalendarKey)
        refreshAuthorizationStatus()
    }

    var statusTitle: String {
        if isAuthorized, isEnabled {
            return selectedDestination.map { "Conectado · \($0.displayName)" } ?? "Calendario conectado"
        }
        if isAuthorized { return "Permiso concedido · sincronización pausada" }
        return "Sin acceso al Calendario"
    }

    func requestAccess() async {
        do {
            isAuthorized = try await store.requestFullAccessToEvents()
            isEnabled = isAuthorized
            lastError = nil
            if isAuthorized {
                refreshCalendars()
                refreshCommitments()
            }
        } catch {
            isAuthorized = false
            isEnabled = false
            lastError = error.localizedDescription
        }
    }

    func refreshAuthorizationStatus() {
        let status = EKEventStore.authorizationStatus(for: .event)
        isAuthorized = status == .fullAccess
        if isAuthorized {
            refreshCalendars()
        } else {
            isEnabled = false
            availableCalendars = []
        }
    }

    var selectedDestination: CalendarDestination? {
        availableCalendars.first { $0.id == selectedCalendarIdentifier }
    }

    func refreshCalendars() {
        guard isAuthorized else {
            availableCalendars = []
            return
        }

        let editable = store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .sorted {
                let leftGoogle = Self.isGoogleCalendar($0)
                let rightGoogle = Self.isGoogleCalendar($1)
                if leftGoogle != rightGoogle { return leftGoogle }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }

        availableCalendars = editable.map {
            CalendarDestination(
                id: $0.calendarIdentifier,
                title: $0.title,
                accountName: $0.source.title,
                isGoogle: Self.isGoogleCalendar($0)
            )
        }

        if !availableCalendars.contains(where: { $0.id == selectedCalendarIdentifier }) {
            let defaultIdentifier = store.defaultCalendarForNewEvents?.calendarIdentifier
            selectedCalendarIdentifier = availableCalendars.first(where: \.isGoogle)?.id
                ?? availableCalendars.first(where: { $0.id == defaultIdentifier })?.id
                ?? availableCalendars.first?.id
        }
    }

    func refreshCommitments(for day: Date = .now) {
        guard isAuthorized, isEnabled else {
            commitments = []
            return
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        commitments = store.events(matching: predicate)
            .filter { !$0.isAllDay && !$0.title.hasPrefix("Luma ·") }
            .map {
                CalendarCommitment(
                    id: $0.eventIdentifier ?? UUID().uuidString,
                    title: $0.title ?? "Ocupado",
                    start: $0.startDate,
                    end: $0.endDate
                )
            }
            .sorted { $0.start < $1.start }
    }

    func busyBlocks(for day: Date = .now) -> [BusyTimeBlock] {
        let calendar = Calendar.current
        return commitments.compactMap { event in
            guard calendar.isDate(event.start, inSameDayAs: day) || calendar.isDate(event.end, inSameDayAs: day) else {
                return nil
            }
            return BusyTimeBlock(
                title: event.title,
                startMinuteOfDay: calendar.component(.hour, from: event.start) * 60 + calendar.component(.minute, from: event.start),
                endMinuteOfDay: calendar.component(.hour, from: event.end) * 60 + calendar.component(.minute, from: event.end)
            )
        }
    }

    func syncAgenda(_ agenda: DailyAgendaSnapshot?, tasks: [LumaTask]) throws {
        guard isAuthorized, isEnabled, let agenda else { return }
        guard let calendarTarget = targetCalendar else {
            lastError = "macOS no encontró un calendario editable."
            return
        }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: agenda.day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let existing = store.events(matching: store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil))
        let byMarker = Dictionary(uniqueKeysWithValues: existing.compactMap { event -> (String, EKEvent)? in
            guard let notes = event.notes,
                  let marker = notes.split(separator: "\n").first(where: { $0.hasPrefix("LUMA-TASK-ID:") })
            else { return nil }
            return (String(marker), event)
        })
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let scheduler = DailyScheduler()

        for block in agenda.blocks {
            guard let task = tasksByID[block.taskID], !task.isCompleted else { continue }
            let marker = "LUMA-TASK-ID:\(task.id.uuidString)"
            let event = byMarker[marker] ?? EKEvent(eventStore: store)
            event.calendar = calendarTarget
            event.title = "Luma · \(task.title)"
            event.startDate = scheduler.date(on: agenda.day, minuteOfDay: block.startMinuteOfDay)
            event.endDate = scheduler.date(on: agenda.day, minuteOfDay: block.endMinuteOfDay)
            event.notes = "\(marker)\nBloque creado por Luma. Podés moverlo sin afectar la tarea."
            try store.save(event, span: .thisEvent, commit: false)
        }
        try store.commit()
        lastSync = .now
        lastError = nil
        refreshCommitments(for: agenda.day)
    }

    func syncTask(_ task: LumaTask) throws {
        guard isAuthorized, isEnabled, autoSyncTasks else { return }
        guard let deadline = task.deadline else {
            try removeTaskEvent(for: task.id)
            return
        }
        guard let targetCalendar else {
            lastError = "Elegí un calendario editable en Ajustes."
            return
        }

        do {
            let event = trackedEvent(for: task.id) ?? EKEvent(eventStore: store)
            let dayStart = Calendar.current.startOfDay(for: deadline)
            event.calendar = targetCalendar
            event.title = task.isCompleted ? "✓ Luma · \(task.title)" : "Luma · \(task.title)"
            event.isAllDay = true
            event.startDate = dayStart
            event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            event.notes = "\(marker(for: task.id))\nTarea sincronizada automáticamente por Luma."
            try store.save(event, span: .thisEvent, commit: true)
            if let identifier = event.eventIdentifier {
                defaults.set(identifier, forKey: eventIdentifierKey(for: task.id))
            }
            lastSync = .now
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func removeTaskEvent(for taskID: UUID) throws {
        guard isAuthorized, let event = trackedEvent(for: taskID) else {
            defaults.removeObject(forKey: eventIdentifierKey(for: taskID))
            return
        }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
            defaults.removeObject(forKey: eventIdentifierKey(for: taskID))
            lastSync = .now
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func isTaskSynced(_ taskID: UUID) -> Bool {
        guard isAuthorized, isEnabled else { return false }
        return trackedEvent(for: taskID) != nil
    }

    private var targetCalendar: EKCalendar? {
        if let selectedCalendarIdentifier,
           let selected = store.calendar(withIdentifier: selectedCalendarIdentifier),
           selected.allowsContentModifications {
            return selected
        }
        return store.defaultCalendarForNewEvents
    }

    private func trackedEvent(for taskID: UUID) -> EKEvent? {
        guard let identifier = defaults.string(forKey: eventIdentifierKey(for: taskID)) else { return nil }
        return store.event(withIdentifier: identifier)
    }

    private func eventIdentifierKey(for taskID: UUID) -> String {
        Self.eventIdentifierPrefix + taskID.uuidString
    }

    private func marker(for taskID: UUID) -> String {
        "LUMA-AUTO-TASK-ID:\(taskID.uuidString)"
    }

    private static func isGoogleCalendar(_ calendar: EKCalendar) -> Bool {
        calendar.source.title.localizedCaseInsensitiveContains("google")
            || calendar.source.title.localizedCaseInsensitiveContains("gmail")
    }
}
