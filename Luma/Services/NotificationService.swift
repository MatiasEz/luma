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
    private let center = UNUserNotificationCenter.current()

    private(set) var isAuthorized = false
    private(set) var lastError: String?
    private(set) var lastAction: LumaNotificationAction?
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    override init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
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
        center.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
        guard isEnabled, isAuthorized, let agenda else { return }

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
            let request = UNNotificationRequest(
                identifier: "luma-agenda-\(index)",
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func clearAgendaNotifications() {
        center.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
    }

    private var pendingIdentifiers: [String] {
        (0 ..< 3).map { "luma-agenda-\($0)" }
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
            scheduleSnooze(body: body, taskID: taskID)
            lastAction = LumaNotificationAction(kind: .snooze, taskID: taskID)
        case "LUMA_TIRED":
            lastAction = LumaNotificationAction(kind: .tired, taskID: taskID)
        case "LUMA_REPLAN":
            lastAction = LumaNotificationAction(kind: .replan, taskID: taskID)
        default:
            break
        }
    }

    private func scheduleSnooze(body: String, taskID: UUID?) {
        let content = UNMutableNotificationContent()
        content.title = "Cuando estés lista"
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "LUMA_AGENDA"
        if let taskID { content.userInfo = ["taskID": taskID.uuidString] }
        let request = UNNotificationRequest(
            identifier: "luma-snooze-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 15 * 60, repeats: false)
        )
        center.add(request)
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
