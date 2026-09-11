import Foundation
import SwiftData

enum FocusSessionOrigin: String, Codable { case focus, manual, rest }

@Model
final class FocusSession {
    @Attribute(.unique) var id: UUID
    var taskID: UUID
    var taskTitle: String
    var areaRaw: String
    var plannedMinutes: Int
    var actualMinutes: Int
    var startedAt: Date
    var endedAt: Date
    var energyPreferenceRaw: String
    var completedTask: Bool
    var ignoredFromLearning: Bool
    var originRaw: String?
    var updatedAt: Date?

    init(
        id: UUID = UUID(),
        taskID: UUID,
        taskTitle: String,
        area: LifeArea,
        plannedMinutes: Int,
        actualMinutes: Int,
        startedAt: Date,
        endedAt: Date = .now,
        energyPreference: EnergyPreference,
        completedTask: Bool = false,
        ignoredFromLearning: Bool = false,
        origin: FocusSessionOrigin = .focus,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.taskTitle = taskTitle
        areaRaw = area.rawValue
        self.plannedMinutes = plannedMinutes
        self.actualMinutes = actualMinutes
        self.startedAt = startedAt
        self.endedAt = endedAt
        energyPreferenceRaw = energyPreference.rawValue
        self.completedTask = completedTask
        self.ignoredFromLearning = ignoredFromLearning
        originRaw = origin.rawValue
        self.updatedAt = updatedAt ?? endedAt
    }

    var origin: FocusSessionOrigin { originRaw.flatMap(FocusSessionOrigin.init(rawValue:)) ?? (area == .rest ? .rest : .focus) }

    var area: LifeArea {
        get { LifeArea(rawValue: areaRaw) ?? .errands }
        set { areaRaw = newValue.rawValue }
    }

    var energyPreference: EnergyPreference {
        get { EnergyPreference(rawValue: energyPreferenceRaw) ?? .normal }
        set { energyPreferenceRaw = newValue.rawValue }
    }
}
