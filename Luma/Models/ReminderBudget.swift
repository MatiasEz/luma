import Foundation

struct ReminderBudget: Codable {
    var reservations: [String: Date] = [:]
    static let dailyLimit = 3

    mutating func cancelPending(now: Date) {
        let today = Calendar.current.startOfDay(for: now)
        reservations = reservations.filter { $0.value <= now && $0.value >= today }
    }

    mutating func reserve(id: String, date: Date, now: Date) -> Bool {
        guard date > now else { return false }
        let count = reservations.values.filter { Calendar.current.isDate($0, inSameDayAs: date) }.count
        guard count < Self.dailyLimit else { return false }
        reservations[id] = date
        return true
    }
}
