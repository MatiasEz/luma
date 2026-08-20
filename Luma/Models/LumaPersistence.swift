import Foundation
import SwiftData

enum EnergyPeak: String, Codable, CaseIterable, Identifiable {
    case morning
    case afternoon
    case evening

    var id: String { rawValue }

    var title: String {
        switch self {
        case .morning: "Mañana"
        case .afternoon: "Tarde"
        case .evening: "Noche"
        }
    }

    var detail: String {
        switch self {
        case .morning: "Me concentro mejor antes del mediodía"
        case .afternoon: "Mi mejor momento suele ser después de almorzar"
        case .evening: "Pienso mejor cuando baja el ritmo del día"
        }
    }

    var symbol: String {
        switch self {
        case .morning: "sunrise.fill"
        case .afternoon: "sun.max.fill"
        case .evening: "moon.stars.fill"
        }
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return switch self {
        case .morning: (6 ..< 12).contains(hour)
        case .afternoon: (12 ..< 18).contains(hour)
        case .evening: hour >= 18 || hour < 2
        }
    }
}

@Model
final class LumaProfile {
    @Attribute(.unique) var id: UUID
    var selectedAreasRaw: String
    var gentleWeekdaysRaw: String
    var energyPeakRaw: String
    var usualStartMinuteOfDay: Int
    var usualAvailableMinutes: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        selectedAreas: [LifeArea] = [.university, .home, .rest],
        gentleWeekdays: [Int] = [1],
        energyPeak: EnergyPeak = .afternoon,
        usualStartMinuteOfDay: Int = 17 * 60,
        usualAvailableMinutes: Int = 120,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        selectedAreasRaw = selectedAreas.map(\.rawValue).joined(separator: ",")
        gentleWeekdaysRaw = gentleWeekdays.map(String.init).joined(separator: ",")
        energyPeakRaw = energyPeak.rawValue
        self.usualStartMinuteOfDay = usualStartMinuteOfDay
        self.usualAvailableMinutes = usualAvailableMinutes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var selectedAreas: [LifeArea] {
        get {
            selectedAreasRaw
                .split(separator: ",")
                .compactMap { LifeArea(rawValue: String($0)) }
        }
        set { selectedAreasRaw = newValue.map(\.rawValue).joined(separator: ",") }
    }

    var gentleWeekdays: [Int] {
        get { gentleWeekdaysRaw.split(separator: ",").compactMap { Int($0) } }
        set { gentleWeekdaysRaw = newValue.map(String.init).joined(separator: ",") }
    }

    var energyPeak: EnergyPeak {
        get { EnergyPeak(rawValue: energyPeakRaw) ?? .afternoon }
        set { energyPeakRaw = newValue.rawValue }
    }
}

@Model
final class LumaChatRecord {
    @Attribute(.unique) var id: UUID
    var roleRaw: String
    var text: String
    var evidenceRaw: String
    var createdAt: Date
    var actionID: UUID?
    var actionKindRaw: String?
    var actionLabel: String?
    var actionTaskID: UUID?
    var actionEnergyRaw: String?
    var actionAvailableMinutes: Int?
    var actionDurationMinutes: Int?
    var appliedAt: Date?

    init(
        id: UUID = UUID(),
        role: LumaChatRole,
        text: String,
        evidence: [String] = [],
        suggestedAction: LumaChatSuggestedAction? = nil,
        createdAt: Date = .now,
        appliedAt: Date? = nil
    ) {
        self.id = id
        roleRaw = role.rawValue
        self.text = text
        evidenceRaw = evidence.joined(separator: "\n")
        self.createdAt = createdAt
        actionID = suggestedAction?.id
        actionKindRaw = suggestedAction?.kind.rawValue
        actionLabel = suggestedAction?.label
        actionTaskID = suggestedAction?.taskID
        actionEnergyRaw = suggestedAction?.energyPreference?.rawValue
        actionAvailableMinutes = suggestedAction?.availableMinutes
        actionDurationMinutes = suggestedAction?.durationMinutes
        self.appliedAt = appliedAt
    }

    var role: LumaChatRole { LumaChatRole(rawValue: roleRaw) ?? .assistant }
    var evidence: [String] { evidenceRaw.split(separator: "\n").map(String.init) }

    var suggestedAction: LumaChatSuggestedAction? {
        guard let actionKindRaw,
              let kind = LumaChatActionKind(rawValue: actionKindRaw),
              let label = actionLabel
        else { return nil }
        return LumaChatSuggestedAction(
            id: actionID ?? UUID(),
            kind: kind,
            label: label,
            taskID: actionTaskID,
            energyPreference: actionEnergyRaw.flatMap(EnergyPreference.init(rawValue:)),
            availableMinutes: actionAvailableMinutes,
            durationMinutes: actionDurationMinutes
        )
    }

    var message: LumaChatMessage {
        LumaChatMessage(
            id: id,
            role: role,
            text: role == .assistant ? LumaChatTextCleaner.finalAnswer(from: text) : text,
            suggestedAction: suggestedAction,
            createdAt: createdAt
        )
    }
}

enum LumaReplanSource: String {
    case dashboard
    case assistant
    case notification

    var title: String {
        switch self {
        case .dashboard: "Plan de hoy"
        case .assistant: "Chat de Luma"
        case .notification: "Aviso"
        }
    }
}

@Model
final class LumaReplanRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var sourceRaw: String
    var reason: String
    var beforeEnergyRaw: String
    var afterEnergyRaw: String
    var beforeAvailableMinutes: Int
    var afterAvailableMinutes: Int
    var beforeTaskIDsRaw: String
    var afterTaskIDsRaw: String
    var beforeAgendaData: Data
    var afterAgendaData: Data
    var changeSummaryRaw: String

    init(proposal: ReplanProposal, createdAt: Date = .now) {
        id = proposal.id
        self.createdAt = createdAt
        sourceRaw = proposal.source.rawValue
        reason = proposal.explanation
        beforeEnergyRaw = proposal.beforeEnergy.rawValue
        afterEnergyRaw = proposal.afterEnergy.rawValue
        beforeAvailableMinutes = proposal.beforeAvailableMinutes
        afterAvailableMinutes = proposal.afterAvailableMinutes
        beforeTaskIDsRaw = proposal.beforeTaskIDs.map(\.uuidString).joined(separator: ",")
        afterTaskIDsRaw = proposal.afterTaskIDs.map(\.uuidString).joined(separator: ",")
        beforeAgendaData = (try? JSONEncoder().encode(proposal.beforeBlocks)) ?? Data()
        afterAgendaData = (try? JSONEncoder().encode(proposal.afterBlocks)) ?? Data()
        changeSummaryRaw = proposal.changeSummary.joined(separator: "\n")
    }

    init(
        id: UUID,
        createdAt: Date,
        sourceRaw: String,
        reason: String,
        beforeEnergyRaw: String,
        afterEnergyRaw: String,
        beforeAvailableMinutes: Int,
        afterAvailableMinutes: Int,
        beforeTaskIDsRaw: String,
        afterTaskIDsRaw: String,
        beforeAgendaData: Data,
        afterAgendaData: Data,
        changeSummaryRaw: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceRaw = sourceRaw
        self.reason = reason
        self.beforeEnergyRaw = beforeEnergyRaw
        self.afterEnergyRaw = afterEnergyRaw
        self.beforeAvailableMinutes = beforeAvailableMinutes
        self.afterAvailableMinutes = afterAvailableMinutes
        self.beforeTaskIDsRaw = beforeTaskIDsRaw
        self.afterTaskIDsRaw = afterTaskIDsRaw
        self.beforeAgendaData = beforeAgendaData
        self.afterAgendaData = afterAgendaData
        self.changeSummaryRaw = changeSummaryRaw
    }
}

struct ReplanProposal: Identifiable, Equatable {
    var id = UUID()
    var source: LumaReplanSource
    var title: String
    var explanation: String
    var day: Date
    var beforeEnergy: EnergyPreference
    var afterEnergy: EnergyPreference
    var beforeAvailableMinutes: Int
    var afterAvailableMinutes: Int
    var startMinuteOfDay: Int
    var beforeTaskIDs: [UUID]
    var afterTaskIDs: [UUID]
    var beforeBlocks: [AgendaBlockSnapshot]
    var afterBlocks: [AgendaBlockSnapshot]
    var changeSummary: [String]

    var changesCurrentPlan: Bool {
        beforeEnergy != afterEnergy
            || beforeAvailableMinutes != afterAvailableMinutes
            || beforeTaskIDs != afterTaskIDs
            || beforeBlocks != afterBlocks
    }
}

@MainActor
enum ReplanProposalBuilder {
    static func make(
        source: LumaReplanSource,
        explanation: String,
        tasks: [LumaTask],
        currentPlan: DailyPlanSnapshot?,
        currentAgenda: DailyAgendaSnapshot?,
        currentEnergy: EnergyPreference,
        proposedEnergy: EnergyPreference,
        proposedAvailableMinutes: Int? = nil,
        planner: TaskPlanner,
        scheduler: DailyScheduler,
        busyBlocks: [BusyTimeBlock] = [],
        now: Date = .now
    ) -> ReplanProposal {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        let beforeIDs = currentPlan?.taskIDs
            ?? planner.recommendations(from: tasks, now: now, preference: currentEnergy).map(\.task.id)
        let afterRecommendations = planner.recommendations(
            from: tasks,
            now: now,
            preference: proposedEnergy
        )
        let afterIDs = afterRecommendations.map(\.task.id)
        let beforeMinutes = currentAgenda?.availableMinutes ?? 120
        let afterMinutes = min(480, max(15, proposedAvailableMinutes ?? beforeMinutes))
        let startMinute = currentAgenda?.startMinuteOfDay ?? scheduler.defaultStartMinute(now: now)
        let beforeBlocks = currentAgenda?.blocks ?? []
        let afterBlocks = scheduler.schedule(
            recommendations: afterRecommendations,
            availableMinutes: afterMinutes,
            startMinuteOfDay: startMinute,
            busyBlocks: busyBlocks
        )
        let taskNames = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.title) })
        let summary = changeSummary(
            beforeIDs: beforeIDs,
            afterIDs: afterIDs,
            beforeBlocks: beforeBlocks,
            afterBlocks: afterBlocks,
            taskNames: taskNames,
            beforeEnergy: currentEnergy,
            afterEnergy: proposedEnergy,
            beforeMinutes: beforeMinutes,
            afterMinutes: afterMinutes
        )

        return ReplanProposal(
            source: source,
            title: "Revisá el reacomodo",
            explanation: explanation,
            day: day,
            beforeEnergy: currentEnergy,
            afterEnergy: proposedEnergy,
            beforeAvailableMinutes: beforeMinutes,
            afterAvailableMinutes: afterMinutes,
            startMinuteOfDay: startMinute,
            beforeTaskIDs: beforeIDs,
            afterTaskIDs: afterIDs,
            beforeBlocks: beforeBlocks,
            afterBlocks: afterBlocks,
            changeSummary: summary
        )
    }

    private static func changeSummary(
        beforeIDs: [UUID],
        afterIDs: [UUID],
        beforeBlocks: [AgendaBlockSnapshot],
        afterBlocks: [AgendaBlockSnapshot],
        taskNames: [UUID: String],
        beforeEnergy: EnergyPreference,
        afterEnergy: EnergyPreference,
        beforeMinutes: Int,
        afterMinutes: Int
    ) -> [String] {
        var lines: [String] = []
        if beforeEnergy != afterEnergy {
            lines.append("El ritmo cambia de \(beforeEnergy.title.lowercased()) a \(afterEnergy.title.lowercased()).")
        }
        if beforeMinutes != afterMinutes {
            lines.append("La disponibilidad pasa de \(duration(beforeMinutes)) a \(duration(afterMinutes)).")
        }
        for id in beforeIDs where !afterIDs.contains(id) {
            lines.append("\(taskNames[id] ?? "Una tarea") sale de las tres prioridades de hoy.")
        }
        for id in afterIDs where !beforeIDs.contains(id) {
            lines.append("\(taskNames[id] ?? "Una tarea") entra en el plan de hoy.")
        }
        let oldBlocks = Dictionary(uniqueKeysWithValues: beforeBlocks.map { ($0.taskID, $0) })
        let newBlocks = Dictionary(uniqueKeysWithValues: afterBlocks.map { ($0.taskID, $0) })
        for id in afterIDs {
            guard let old = oldBlocks[id], let new = newBlocks[id], old != new else { continue }
            lines.append("\(taskNames[id] ?? "Una tarea") cambia de horario o duración.")
        }
        if lines.isEmpty {
            lines.append("Las prioridades se mantienen; Luma solo confirma que el plan sigue siendo posible.")
        }
        return Array(lines.prefix(4))
    }

    private static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) min" }
        if remainder == 0 { return hours == 1 ? "1 hora" : "\(hours) horas" }
        return "\(hours) h \(remainder) min"
    }
}
