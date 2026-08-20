import SwiftUI

enum LifeArea: String, Codable, CaseIterable, Identifiable {
    case university
    case home
    case errands
    case rest
    case hobbies
    case sideHustle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .university: "Uni"
        case .home: "Casa"
        case .errands: "Trámites"
        case .rest: "Descanso"
        case .hobbies: "Hobbies"
        case .sideHustle: "Side hustle"
        }
    }

    var symbol: String {
        switch self {
        case .university: "graduationcap.fill"
        case .home: "house.fill"
        case .errands: "doc.text.fill"
        case .rest: "moon.stars.fill"
        case .hobbies: "paintpalette.fill"
        case .sideHustle: "briefcase.fill"
        }
    }

    var color: Color {
        switch self {
        case .university: LumaPalette.indigo
        case .home: LumaPalette.terracotta
        case .errands: LumaPalette.mustard
        case .rest: LumaPalette.lavender
        case .hobbies: LumaPalette.rose
        case .sideHustle: LumaPalette.sage
        }
    }
}

enum EnergyLevel: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "Baja"
        case .medium: "Media"
        case .high: "Alta"
        }
    }

    var symbol: String {
        switch self {
        case .low: "battery.25percent"
        case .medium: "battery.50percent"
        case .high: "battery.100percent"
        }
    }
}

enum ImpactType: String, Codable, CaseIterable, Identifiable {
    case grade
    case money
    case urgency
    case wellbeing
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grade: "Calificación"
        case .money: "Dinero"
        case .urgency: "Urgencia"
        case .wellbeing: "Bienestar"
        case .general: "General"
        }
    }
}

enum TaskStatus: String, Codable {
    case pending
    case completed
}

enum EnergyPreference: String, Codable, CaseIterable, Identifiable {
    case normal
    case tired
    case energized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "Ritmo normal"
        case .tired: "Estoy cansada"
        case .energized: "Tengo más tiempo"
        }
    }
}
