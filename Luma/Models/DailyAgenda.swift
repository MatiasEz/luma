import Foundation

struct AvailabilityWindow: Codable, Equatable, Identifiable {
    var id: UUID
    var startMinuteOfDay: Int
    var endMinuteOfDay: Int

    init(
        id: UUID = UUID(),
        startMinuteOfDay: Int,
        endMinuteOfDay: Int
    ) {
        self.id = id
        self.startMinuteOfDay = startMinuteOfDay
        self.endMinuteOfDay = endMinuteOfDay
    }

    var durationMinutes: Int {
        max(0, endMinuteOfDay - startMinuteOfDay)
    }
}

struct AgendaBlockSnapshot: Codable, Equatable, Identifiable {
    var taskID: UUID
    var startMinuteOfDay: Int
    var durationMinutes: Int

    var id: UUID { taskID }
    var endMinuteOfDay: Int { startMinuteOfDay + durationMinutes }
}

struct DailyAgendaSnapshot: Codable, Equatable {
    var day: Date
    var availableMinutes: Int
    var startMinuteOfDay: Int
    var availabilityWindows: [AvailabilityWindow]
    var availabilityConfirmed: Bool
    var blocks: [AgendaBlockSnapshot]

    init(
        day: Date,
        availableMinutes: Int,
        startMinuteOfDay: Int,
        availabilityWindows: [AvailabilityWindow],
        availabilityConfirmed: Bool,
        blocks: [AgendaBlockSnapshot]
    ) {
        self.day = day
        self.availableMinutes = availableMinutes
        self.startMinuteOfDay = startMinuteOfDay
        self.availabilityWindows = availabilityWindows
        self.availabilityConfirmed = availabilityConfirmed
        self.blocks = blocks
    }

    private enum CodingKeys: String, CodingKey {
        case day, availableMinutes, startMinuteOfDay, availabilityWindows, availabilityConfirmed, blocks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(Date.self, forKey: .day)
        availableMinutes = try container.decode(Int.self, forKey: .availableMinutes)
        startMinuteOfDay = try container.decode(Int.self, forKey: .startMinuteOfDay)
        blocks = try container.decode([AgendaBlockSnapshot].self, forKey: .blocks)
        availabilityWindows = try container.decodeIfPresent(
            [AvailabilityWindow].self,
            forKey: .availabilityWindows
        ) ?? (availableMinutes > 0
            ? [AvailabilityWindow(
                startMinuteOfDay: startMinuteOfDay,
                endMinuteOfDay: min(24 * 60, startMinuteOfDay + availableMinutes)
            )]
            : [])
        availabilityConfirmed = try container.decodeIfPresent(
            Bool.self,
            forKey: .availabilityConfirmed
        ) ?? true
    }
}

struct AgendaRequestDraft: Equatable {
    var availableMinutes: Int? = nil
    var startMinuteOfDay: Int? = nil
    var availabilityWindows: [AvailabilityWindow]? = nil
    var energyPreference: EnergyPreference? = nil
}

struct DailyScheduler {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func schedule(
        recommendations: [PlanRecommendation],
        availableMinutes: Int,
        startMinuteOfDay: Int,
        busyBlocks: [BusyTimeBlock] = [],
        reservedRestMinutes: Int? = nil
    ) -> [AgendaBlockSnapshot] {
        guard availableMinutes > 0 else { return [] }
        let start = min(23 * 60 + 45, max(0, startMinuteOfDay))
        let minimumMinutes = reservedRestMinutes == nil ? 15 : 1
        let end = min(24 * 60, start + min(600, max(minimumMinutes, availableMinutes)))
        return schedule(
            recommendations: recommendations,
            availabilityWindows: [
                AvailabilityWindow(startMinuteOfDay: start, endMinuteOfDay: end),
            ],
            busyBlocks: busyBlocks,
            reservedRestMinutes: reservedRestMinutes
        )
    }

    func schedule(
        recommendations: [PlanRecommendation],
        availabilityWindows: [AvailabilityWindow],
        busyBlocks: [BusyTimeBlock] = [],
        reservedRestMinutes: Int? = nil
    ) -> [AgendaBlockSnapshot] {
        let freeWindows = freeAvailabilityWindows(
            in: availabilityWindows,
            busyBlocks: busyBlocks,
            minimumDurationMinutes: reservedRestMinutes == nil ? 15 : 1
        )
        let available = min(600, freeWindows.reduce(0) { $0 + $1.durationMinutes })
        if let reservedRestMinutes {
            return scheduleAssignedBlocks(
                recommendations: recommendations,
                freeWindows: freeWindows,
                workBudget: max(0, available - max(0, reservedRestMinutes))
            )
        }
        guard available >= 15 else { return [] }

        let taskCount: Int

        switch available {
        case ..<45:
            taskCount = min(1, recommendations.count)
        case ..<90:
            taskCount = min(2, recommendations.count)
        default:
            taskCount = min(3, recommendations.count)
        }

        guard taskCount > 0 else { return [] }

        let selected = Array(recommendations.prefix(taskCount))
        let breakMinutes = taskCount > 1 ? (available >= 60 ? 10 : 5) : 0
        var cursors = freeWindows.map { window in
            (start: window.startMinuteOfDay, end: window.endMinuteOfDay)
        }
        var windowIndex = 0
        var blocks: [AgendaBlockSnapshot] = []

        for (index, recommendation) in selected.enumerated() {
            while windowIndex < cursors.count,
                  cursors[windowIndex].end - cursors[windowIndex].start < 15
            {
                windowIndex += 1
            }
            guard windowIndex < cursors.count else { break }

            let remainingTasks = taskCount - index - 1
            let remainingCapacity = cursors[windowIndex...].reduce(0) {
                $0 + max(0, $1.end - $1.start)
            }
            let reservedForRemaining = remainingTasks * (15 + breakMinutes)
            let maximumForThisTask = max(15, remainingCapacity - reservedForRemaining)
            let desired = max(15, recommendation.suggestedMinutes)
            let roomInWindow = cursors[windowIndex].end - cursors[windowIndex].start
            let duration = min(desired, maximumForThisTask, roomInWindow)
            guard duration >= 15 else { continue }
            let start = cursors[windowIndex].start

            blocks.append(
                AgendaBlockSnapshot(
                    taskID: recommendation.task.id,
                    startMinuteOfDay: start,
                    durationMinutes: duration
                )
            )

            cursors[windowIndex].start += duration
            if index < taskCount - 1 {
                if cursors[windowIndex].end - cursors[windowIndex].start >= breakMinutes + 15 {
                    cursors[windowIndex].start += breakMinutes
                } else {
                    windowIndex += 1
                }
            }
        }

        return blocks
    }

    /// Assigned minutes already account for rest. Leave its total free without
    /// inserting another pause between every pair of work blocks.
    private func scheduleAssignedBlocks(
        recommendations: [PlanRecommendation],
        freeWindows: [AvailabilityWindow],
        workBudget: Int
    ) -> [AgendaBlockSnapshot] {
        var remainingMinutes = workBudget
        var windows = freeWindows
        var blocks: [AgendaBlockSnapshot] = []
        var seen = Set<UUID>()

        for recommendation in recommendations.prefix(3) {
            guard remainingMinutes > 0 else { break }
            guard recommendation.task.academicSourceType != .rest,
                  seen.insert(recommendation.task.id).inserted
            else { continue }
            let desired = min(remainingMinutes, max(0, recommendation.suggestedMinutes))
            guard desired > 0 else { continue }

            let windowIndex = windows.firstIndex { $0.durationMinutes >= desired }
                ?? windows.indices.max { windows[$0].durationMinutes < windows[$1].durationMinutes }
            guard let windowIndex else { break }
            let duration = min(desired, windows[windowIndex].durationMinutes)
            guard duration > 0 else { break }

            blocks.append(AgendaBlockSnapshot(
                taskID: recommendation.task.id,
                startMinuteOfDay: windows[windowIndex].startMinuteOfDay,
                durationMinutes: duration
            ))
            windows[windowIndex].startMinuteOfDay += duration
            remainingMinutes -= duration
        }

        return blocks.sorted { $0.startMinuteOfDay < $1.startMinuteOfDay }
    }

    func freeAvailabilityWindows(
        in availabilityWindows: [AvailabilityWindow],
        busyBlocks: [BusyTimeBlock],
        minimumDurationMinutes: Int = 15
    ) -> [AvailabilityWindow] {
        let minimumMinutes = max(1, minimumDurationMinutes)
        let normalized = availabilityWindows
            .map {
                AvailabilityWindow(
                    id: $0.id,
                    startMinuteOfDay: min(24 * 60, max(0, $0.startMinuteOfDay)),
                    endMinuteOfDay: min(24 * 60, max(0, $0.endMinuteOfDay))
                )
            }
            .filter { $0.durationMinutes >= minimumMinutes }
            .sorted { $0.startMinuteOfDay < $1.startMinuteOfDay }
        let merged = normalized.reduce(into: [AvailabilityWindow]()) { result, window in
            guard var last = result.last,
                  window.startMinuteOfDay <= last.endMinuteOfDay
            else {
                result.append(window)
                return
            }
            last.endMinuteOfDay = max(last.endMinuteOfDay, window.endMinuteOfDay)
            result[result.count - 1] = last
        }
        let sorted = busyBlocks.sorted { $0.startMinuteOfDay < $1.startMinuteOfDay }
        var result: [AvailabilityWindow] = []

        for window in merged {
            var pieces = [window]
            for busy in sorted {
                pieces = pieces.flatMap { piece in
                    guard busy.startMinuteOfDay < piece.endMinuteOfDay,
                          busy.endMinuteOfDay > piece.startMinuteOfDay
                    else { return [piece] }

                    var remaining: [AvailabilityWindow] = []
                    if busy.startMinuteOfDay - piece.startMinuteOfDay >= minimumMinutes {
                        remaining.append(AvailabilityWindow(
                            startMinuteOfDay: piece.startMinuteOfDay,
                            endMinuteOfDay: busy.startMinuteOfDay
                        ))
                    }
                    if piece.endMinuteOfDay - busy.endMinuteOfDay >= minimumMinutes {
                        remaining.append(AvailabilityWindow(
                            startMinuteOfDay: busy.endMinuteOfDay,
                            endMinuteOfDay: piece.endMinuteOfDay
                        ))
                    }
                    return remaining
                }
            }
            result.append(contentsOf: pieces)
        }

        return result.sorted { $0.startMinuteOfDay < $1.startMinuteOfDay }
    }

    func movedBlocks(
        _ blocks: [AgendaBlockSnapshot],
        taskID: UUID,
        proposedStartMinute: Int,
        availabilityWindows: [AvailabilityWindow],
        busyBlocks: [BusyTimeBlock]
    ) -> [AgendaBlockSnapshot] {
        guard let moving = blocks.first(where: { $0.taskID == taskID }) else { return blocks }
        let freeWindows = freeAvailabilityWindows(
            in: availabilityWindows,
            busyBlocks: busyBlocks,
            minimumDurationMinutes: min(15, blocks.map(\.durationMinutes).min() ?? 15)
        )
        let movingCandidates = candidateStarts(duration: moving.durationMinutes, in: freeWindows)
        guard let movingStart = movingCandidates.min(by: {
            abs($0 - proposedStartMinute) < abs($1 - proposedStartMinute)
        }) else { return blocks }

        var placed = [AgendaBlockSnapshot(
            taskID: moving.taskID,
            startMinuteOfDay: movingStart,
            durationMinutes: moving.durationMinutes
        )]

        for block in blocks.filter({ $0.taskID != taskID }).sorted(by: {
            $0.startMinuteOfDay < $1.startMinuteOfDay
        }) {
            let candidates = candidateStarts(duration: block.durationMinutes, in: freeWindows)
                .filter { start in
                    let end = start + block.durationMinutes
                    return !placed.contains { existing in
                        start < existing.endMinuteOfDay && end > existing.startMinuteOfDay
                    }
                }
            let start = candidates.first(where: { $0 >= block.startMinuteOfDay })
                ?? candidates.first
            guard let start else { continue }
            placed.append(AgendaBlockSnapshot(
                taskID: block.taskID,
                startMinuteOfDay: start,
                durationMinutes: block.durationMinutes
            ))
        }

        return placed.sorted { $0.startMinuteOfDay < $1.startMinuteOfDay }
    }

    private func candidateStarts(
        duration: Int,
        in windows: [AvailabilityWindow]
    ) -> [Int] {
        windows.flatMap { window in
            guard window.durationMinutes >= duration else { return [Int]() }
            return Array(stride(
                from: window.startMinuteOfDay,
                through: window.endMinuteOfDay - duration,
                by: 5
            ))
        }
    }

    func defaultStartMinute(now: Date = .now) -> Int {
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let roundedMinute = ((minute + 4) / 5) * 5
        return min(23 * 60 + 45, hour * 60 + roundedMinute)
    }

    func date(on day: Date, minuteOfDay: Int) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .minute, value: minuteOfDay, to: start) ?? start
    }
}
