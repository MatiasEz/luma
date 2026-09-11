import Foundation
import Observation
import UserNotifications

enum LumaNotificationActionKind: String {
    case start
    case snooze
    case tired
    case replan
}

struct LumaNotificationAction: Identifiable, Equatable {
    var id = UUID()
    var kind: LumaNotificationActionKind
    var taskID: UUID?
}

@MainActor
@Observable
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private static let enabledKey = "lumaNotificationsEnabled"
    private var revision = 0
    private var budget: ReminderBudget = UserDefaults.standard.data(forKey: "lumaReminderBudget.v1").flatMap { try? JSONDecoder().decode(ReminderBudget.self, from: $0) } ?? ReminderBudget()
    private let center = UNUserNotificationCenter.current()

    private(set) var isAuthorized = false
    private(set) var lastError: String?
    private(set) var lastAction: LumaNotificationAction?
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey); if !isEnabled { clearAgendaNotifications() } }
    }

    override init() {
        isEnabled = !LumaDebugPreview.isEnabled && UserDefaults.standard.bool(forKey: Self.enabledKey)
        super.init()
        center.delegate = self
        registerActions()
        Task { await refreshAuthorization() }
    }

    func requestAuthorization() async {
        do {
            isAuthorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isEnabled = isAuthorized
            lastError = isAuthorized ? nil : "Las notificaciones siguen desactivadas en macOS."
        } catch {
            isAuthorized = false
            isEnabled = false
            lastError = error.localizedDescription
        }
    }

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        if !isAuthorized { isEnabled = false }
    }

    func scheduleAgenda(_ agenda: DailyAgendaSnapshot?, tasks: [LumaTask], now: Date = .now) async {
        revision += 1
        let generation = revision
        await cancelAllPending(now: now, generation: generation)
        guard generation == revision, isEnabled, isAuthorized, let agenda else { return }

        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let scheduler = DailyScheduler()
        for (index, block) in agenda.blocks.prefix(3).enumerated() {
            guard let task = tasksByID[block.taskID], !task.isCompleted else { continue }
            let startDate = scheduler.date(on: agenda.day, minuteOfDay: block.startMinuteOfDay)
            guard startDate > now.addingTimeInterval(5) else { continue }

            let content = UNMutableNotificationContent()
            content.title = index == 0 ? "Tu primer bloque está listo" : "Siguiente bloque de Luma"
            content.body = "\(task.title) · \(block.durationMinutes) min. Empezá cuando puedas."
            content.sound = .default
            content.categoryIdentifier = "LUMA_AGENDA"
            content.userInfo = ["taskID": task.id.uuidString]

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: startDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let id = "luma-agenda-\(UUID())"
            guard generation == revision, budget.reserve(id: id, date: startDate, now: now) else { continue }
            persistBudget()
            let request = UNNotificationRequest(
                identifier: id,
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
                if generation != revision { center.removePendingNotificationRequests(withIdentifiers: [id]) }
            } catch {
                budget.reservations.removeValue(forKey: id)
                persistBudget()
                lastError = error.localizedDescription
            }
        }
    }

    func clearAgendaNotifications() {
        revision += 1
        let generation = revision
        Task { await cancelAllPending(now: .now, generation: generation) }
    }

    private func cancelAllPending(now: Date, generation: Int) async {
        let requests = await center.pendingNotificationRequests()
        guard generation == revision else { return }
        center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix("luma-") })
        budget.cancelPending(now: now)
        persistBudget()
    }

    private func persistBudget() {
        if let data = try? JSONEncoder().encode(budget) { UserDefaults.standard.set(data, forKey: "lumaReminderBudget.v1") }
    }

    private func registerActions() {
        let start = UNNotificationAction(identifier: "LUMA_START", title: "Empezar", options: [.foreground])
        let snooze = UNNotificationAction(identifier: "LUMA_SNOOZE", title: "En 15 min")
        let tired = UNNotificationAction(identifier: "LUMA_TIRED", title: "Estoy cansada", options: [.foreground])
        let replan = UNNotificationAction(identifier: "LUMA_REPLAN", title: "Reacomodar", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "LUMA_AGENDA",
                actions: [start, snooze, tired, replan],
                intentIdentifiers: []
            ),
        ])
    }

    private func handle(actionIdentifier: String, taskID: UUID?, body: String) {
        switch actionIdentifier {
        case "LUMA_START", UNNotificationDefaultActionIdentifier:
            lastAction = LumaNotificationAction(kind: .start, taskID: taskID)
        case "LUMA_SNOOZE":
            Task { await scheduleSnooze(body: body, taskID: taskID) }
            lastAction = LumaNotificationAction(kind: .snooze, taskID: taskID)
        case "LUMA_TIRED":
            lastAction = LumaNotificationAction(kind: .tired, taskID: taskID)
        case "LUMA_REPLAN":
            lastAction = LumaNotificationAction(kind: .replan, taskID: taskID)
        default:
            break
        }
    }

    private func scheduleSnooze(body: String, taskID: UUID?) async {
        guard isEnabled, isAuthorized else { return }
        let generation = revision
        let id = "luma-snooze-\(UUID())"
        guard budget.reserve(id: id, date: .now.addingTimeInterval(900), now: .now) else { return }
        persistBudget()
        let content = UNMutableNotificationContent()
        content.title = "Cuando estés lista"
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "LUMA_AGENDA"
        if let taskID { content.userInfo = ["taskID": taskID.uuidString] }
        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 15 * 60, repeats: false)
        )
        do {
            try await center.add(request)
            if generation != revision { center.removePendingNotificationRequests(withIdentifiers: [id]) }
        } catch { budget.reservations.removeValue(forKey: id); persistBudget(); lastError = error.localizedDescription }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionIdentifier = response.actionIdentifier
        let body = response.notification.request.content.body
        let taskID = (response.notification.request.content.userInfo["taskID"] as? String).flatMap(UUID.init)
        await MainActor.run {
            self.handle(actionIdentifier: actionIdentifier, taskID: taskID, body: body)
        }
    }
}
