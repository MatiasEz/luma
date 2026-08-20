import Foundation
import SwiftData

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
        ignoredFromLearning: Bool = false
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
    }

    var area: LifeArea {
        get { LifeArea(rawValue: areaRaw) ?? .errands }
        set { areaRaw = newValue.rawValue }
    }

    var energyPreference: EnergyPreference {
        get { EnergyPreference(rawValue: energyPreferenceRaw) ?? .normal }
        set { energyPreferenceRaw = newValue.rawValue }
    }
}
