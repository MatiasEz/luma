import Foundation

struct ActiveFocusSnapshot: Codable, Equatable {
    var id: UUID
    var taskID: UUID?
    var durationMinutes: Int
    var elapsedSeconds: Int
    var isRunning: Bool
    var startedAt: Date?
    var checkpointAt: Date
    var completed: Bool
    var plannedBlockID: UUID? = nil

    func elapsed(at date: Date) -> Int {
        let additional = isRunning && !completed ? max(0, Int(date.timeIntervalSince(checkpointAt))) : 0
        return min(durationMinutes * 60, max(0, elapsedSeconds + additional))
    }
}
