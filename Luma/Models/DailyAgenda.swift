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
        busyBlocks: [BusyTimeBlock] = []
    ) -> [AgendaBlockSnapshot] {
        let start = min(23 * 60 + 45, max(0, startMinuteOfDay))
        let end = min(24 * 60, start + min(480, max(15, availableMinutes)))
        return schedule(
            recommendations: recommendations,
            availabilityWindows: [
                AvailabilityWindow(startMinuteOfDay: start, endMinuteOfDay: end),
            ],
            busyBlocks: busyBlocks
        )
    }

    func schedule(
        recommendations: [PlanRecommendation],
        availabilityWindows: [AvailabilityWindow],
        busyBlocks: [BusyTimeBlock] = []
    ) -> [AgendaBlockSnapshot] {
        let freeWindows = freeAvailabilityWindows(
            in: availabilityWindows,
            busyBlocks: busyBlocks
        )
        let available = min(480, freeWindows.reduce(0) { $0 + $1.durationMinutes })
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

    func freeAvailabilityWindows(
        in availabilityWindows: [AvailabilityWindow],
        busyBlocks: [BusyTimeBlock]
    ) -> [AvailabilityWindow] {
        let normalized = availabilityWindows
            .map {
                AvailabilityWindow(
                    id: $0.id,
                    startMinuteOfDay: min(24 * 60, max(0, $0.startMinuteOfDay)),
                    endMinuteOfDay: min(24 * 60, max(0, $0.endMinuteOfDay))
                )
            }
            .filter { $0.durationMinutes >= 15 }
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
                    if busy.startMinuteOfDay - piece.startMinuteOfDay >= 15 {
                        remaining.append(AvailabilityWindow(
                            startMinuteOfDay: piece.startMinuteOfDay,
                            endMinuteOfDay: busy.startMinuteOfDay
                        ))
                    }
                    if piece.endMinuteOfDay - busy.endMinuteOfDay >= 15 {
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
