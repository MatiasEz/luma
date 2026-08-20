import Foundation

struct DayAvailability: Codable, Equatable, Identifiable {
    var weekday: Int
    var isEnabled: Bool
    var startMinuteOfDay: Int
    var availableMinutes: Int

    var id: Int { weekday }

    var shortTitle: String {
        let symbols = ["Dom", "Lun", "Mar", "Mié", "Jue", "Vie", "Sáb"]
        guard symbols.indices.contains(weekday - 1) else { return "Día" }
        return symbols[weekday - 1]
    }

    static var standardWeek: [DayAvailability] {
        (1 ... 7).map { weekday in
            DayAvailability(
                weekday: weekday,
                isEnabled: true,
                startMinuteOfDay: weekday == 1 || weekday == 7 ? 11 * 60 : 17 * 60,
                availableMinutes: weekday == 1 || weekday == 7 ? 90 : 120
            )
        }
    }
}

struct BusyTimeBlock: Equatable, Identifiable {
    var title: String
    var startMinuteOfDay: Int
    var endMinuteOfDay: Int

    var id: String { "\(title)-\(startMinuteOfDay)-\(endMinuteOfDay)" }
}
