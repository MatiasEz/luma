import Foundation

enum TaskDependencyResolver {
    static func blockers(for taskID: UUID, in tasks: [LumaTask]) -> [LumaTask] {
        tasks.filter { task in
            !task.isCompleted && task.unlocksTaskID == taskID
        }
    }

    static func isBlocked(_ task: LumaTask, in tasks: [LumaTask]) -> Bool {
        !blockers(for: task.id, in: tasks).isEmpty
    }

    static func availableTargets(
        for sourceTaskID: UUID?,
        selectedTaskID: UUID?,
        in tasks: [LumaTask]
    ) -> [LumaTask] {
        tasks
            .filter { candidate in
                guard candidate.id != sourceTaskID else { return false }
                guard !candidate.isCompleted || candidate.id == selectedTaskID else { return false }
                guard let sourceTaskID else { return true }
                return !wouldCreateCycle(
                    sourceTaskID: sourceTaskID,
                    targetTaskID: candidate.id,
                    in: tasks
                )
            }
            .sorted {
                if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
                return $0.createdAt < $1.createdAt
            }
    }

    static func wouldCreateCycle(
        sourceTaskID: UUID,
        targetTaskID: UUID,
        in tasks: [LumaTask]
    ) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var visited: Set<UUID> = []
        var cursor: UUID? = targetTaskID

        while let current = cursor, visited.insert(current).inserted {
            if current == sourceTaskID { return true }
            cursor = byID[current]?.unlocksTaskID
        }
        return false
    }
}
