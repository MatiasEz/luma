import Foundation

enum PostponementReason: String, Codable, CaseIterable, Identifiable {
    case time, energy, unclear, waiting, lessImportant
    var id: String { rawValue }
    var title: String {
        switch self {
        case .time: "No alcanzó el tiempo"
        case .energy: "Me faltó energía"
        case .unclear: "No sabía por dónde empezar"
        case .waiting: "Estoy esperando algo"
        case .lessImportant: "Ya no es tan importante"
        }
    }
}

/// Optional, additive metadata keeps older local databases and backups readable.
struct TaskPlanningDetails: Codable, Equatable {
    var startDate: Date?
    var deferredUntil: Date?
    var postponementReason: PostponementReason?
    var studyOrder: Int?
    var preparesForClass: Bool?
    var nextStep: String?
    var isRetired: Bool?
}
