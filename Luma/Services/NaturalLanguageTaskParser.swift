import Foundation

struct NaturalLanguageTaskParser {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func parse(_ input: String, now: Date = .now) -> ParsedTaskDraft {
        let normalized = input.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        return ParsedTaskDraft(
            title: cleanedTitle(input),
            area: detectArea(normalized),
            deadline: detectDate(normalized, now: now),
            estimatedMinutes: detectDuration(normalized),
            energy: detectEnergy(normalized),
            impact: detectImpact(normalized),
            academicWeight: detectWeight(normalized),
            unlocksAnotherTask: normalized.contains("bloquea") || normalized.contains("antes de"),
            notes: input
        )
    }

    func shouldUseAI(for draft: ParsedTaskDraft) -> Bool {
        draft.area == .errands
            && draft.deadline == nil
            && draft.estimatedMinutes == 30
            && draft.energy == .medium
            && draft.impact == .general
            && draft.academicWeight == nil
    }

    private func cleanedTitle(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Nuevo pendiente" }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    private func detectArea(_ text: String) -> LifeArea {
        if containsAny(text, ["examen", "parcial", "final", "ensayo", "capitulo", "leer", "universidad", "facultad", "entrega"]) {
            return .university
        }
        if containsAny(text, ["lavar", "limpiar", "ordenar", "ropa", "cuarto", "cocinar", "casa"]) {
            return .home
        }
        if containsAny(text, ["freelance", "cotizacion", "cliente", "factura", "portfolio", "side hustle"]) {
            return .sideHustle
        }
        if containsAny(text, ["descansar", "dormir", "siesta", "meditar", "pausa"]) {
            return .rest
        }
        if containsAny(text, ["hobby", "pintar", "guitarra", "dibujar", "juego", "leer novela"]) {
            return .hobbies
        }
        return .errands
    }

    private func detectImpact(_ text: String) -> ImpactType {
        if containsAny(text, ["examen", "parcial", "entrega", "ensayo", "nota", "%"]) { return .grade }
        if containsAny(text, ["cotizacion", "cliente", "cobrar", "factura", "pagar"]) { return .money }
        if containsAny(text, ["salud", "descanso", "dormir", "gimnasio", "meditar"]) { return .wellbeing }
        if containsAny(text, ["urgente", "turno", "tramite", "vencido"]) { return .urgency }
        return .general
    }

    private func detectEnergy(_ text: String) -> EnergyLevel {
        if containsAny(text, ["facil", "rapido", "baja energia", "mecanico"]) { return .low }
        if containsAny(text, ["dificil", "concentracion", "estudiar", "examen", "alta energia"]) { return .high }
        return .medium
    }

    private func detectWeight(_ text: String) -> Double? {
        captureNumber(in: text, pattern: #"(\d{1,3}(?:[\.,]\d+)?)\s*%"#)
    }

    private func detectDuration(_ text: String) -> Int {
        if let hours = captureNumber(in: text, pattern: #"(\d+(?:[\.,]\d+)?)\s*(?:h|hora|horas)\b"#) {
            return max(5, Int(hours * 60))
        }
        if let minutes = captureNumber(in: text, pattern: #"(\d+)\s*(?:min|minuto|minutos)\b"#) {
            return max(5, Int(minutes))
        }
        return 30
    }

    private func detectDate(_ text: String, now: Date) -> Date? {
        let start = calendar.startOfDay(for: now)
        if text.contains("hoy") { return endOfDay(start) }
        if text.contains("manana") {
            return calendar.date(byAdding: .day, value: 1, to: start).map(endOfDay)
        }
        if text.contains("esta semana") {
            return calendar.date(byAdding: .day, value: 6, to: start).map(endOfDay)
        }

        let weekdayNames: [(String, Int)] = [
            ("domingo", 1), ("lunes", 2), ("martes", 3), ("miercoles", 4),
            ("jueves", 5), ("viernes", 6), ("sabado", 7),
        ]

        for (name, weekday) in weekdayNames where text.contains(name) {
            let current = calendar.component(.weekday, from: start)
            var offset = (weekday - current + 7) % 7
            if offset == 0 { offset = 7 }
            return calendar.date(byAdding: .day, value: offset, to: start).map(endOfDay)
        }

        return nil
    }

    private func endOfDay(_ date: Date) -> Date {
        calendar.date(bySettingHour: 20, minute: 0, second: 0, of: date) ?? date
    }

    private func containsAny(_ text: String, _ words: [String]) -> Bool {
        words.contains(where: text.contains)
    }

    private func captureNumber(in text: String, pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }

        return Double(text[range].replacingOccurrences(of: ",", with: "."))
    }
}

enum ParsedTaskValidator {
    /// Explicit dates, durations, weights and keywords are deterministic and win over
    /// a small model. DeepSeek only fills fields for which the local parser found no signal.
    static func merge(ai: ParsedTaskDraft, explicit: ParsedTaskDraft) -> ParsedTaskDraft {
        ParsedTaskDraft(
            title: explicit.title,
            area: explicit.area == .errands ? ai.area : explicit.area,
            deadline: explicit.deadline ?? ai.deadline,
            estimatedMinutes: explicit.estimatedMinutes == 30 ? ai.estimatedMinutes : explicit.estimatedMinutes,
            energy: explicit.energy == .medium ? ai.energy : explicit.energy,
            impact: explicit.impact == .general ? ai.impact : explicit.impact,
            academicWeight: explicit.academicWeight ?? ai.academicWeight,
            academicSubjectID: explicit.academicSubjectID ?? ai.academicSubjectID,
            subjectGradeItemID: explicit.subjectGradeItemID ?? ai.subjectGradeItemID,
            grade: explicit.grade ?? ai.grade,
            unlocksAnotherTask: explicit.unlocksAnotherTask || ai.unlocksAnotherTask,
            unlocksTaskID: explicit.unlocksTaskID ?? ai.unlocksTaskID,
            notes: explicit.notes
        )
    }
}

enum JSONExtractor {
    static func objectData(from text: String, requiringAny requiredKeys: Set<String> = []) -> Data? {
        let withoutThinking = text.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#,
            with: "",
            options: .regularExpression
        )

        return extractValidObject(from: withoutThinking, requiringAny: requiredKeys)
            ?? extractValidObject(from: text, requiringAny: requiredKeys)
    }

    private static func extractValidObject(
        from text: String,
        requiringAny requiredKeys: Set<String>
    ) -> Data? {
        var searchStart = text.startIndex

        while let openingBrace = text[searchStart...].firstIndex(of: "{") {
            if let object = balancedObject(in: text, startingAt: openingBrace),
               let data = object.data(using: .utf8),
               let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               requiredKeys.isEmpty || !requiredKeys.isDisjoint(with: dictionary.keys)
            {
                return data
            }
            searchStart = text.index(after: openingBrace)
        }
        return nil
    }

    private static func balancedObject(in text: String, startingAt start: String.Index) -> String? {
        var depth = 0
        var isInsideString = false
        var isEscaped = false

        for index in text.indices[start...] {
            let character = text[index]

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
                continue
            }

            if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start ... index])
                }
            }
        }

        return nil
    }
}
