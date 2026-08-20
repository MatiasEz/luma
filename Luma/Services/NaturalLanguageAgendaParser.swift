import Foundation

struct NaturalLanguageAgendaParser {
    func parse(_ input: String) -> AgendaRequestDraft {
        let normalized = input.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: .current
        )
        let windows = detectAvailabilityWindows(normalized)

        return AgendaRequestDraft(
            availableMinutes: windows.isEmpty
                ? detectAvailableMinutes(normalized)
                : min(480, windows.reduce(0) { $0 + $1.durationMinutes }),
            startMinuteOfDay: windows.first?.startMinuteOfDay ?? detectStartMinute(normalized),
            availabilityWindows: windows.isEmpty ? nil : windows,
            energyPreference: detectEnergy(normalized)
        )
    }

    private func detectAvailabilityWindows(_ text: String) -> [AvailabilityWindow] {
        let pattern = #"(?:\bde|\bdesde)\s+(?:las\s+)?(\d{1,2})(?::(\d{2}))?\s*(?:a|hasta)\s+(?:las\s+)?(\d{1,2})(?::(\d{2}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        return matches.compactMap { match in
            guard let startHour = integer(in: text, match: match, rangeIndex: 1),
                  let endHour = integer(in: text, match: match, rangeIndex: 3),
                  (0 ... 23).contains(startHour),
                  (0 ... 24).contains(endHour)
            else { return nil }

            let startMinute = integer(in: text, match: match, rangeIndex: 2) ?? 0
            let endMinute = integer(in: text, match: match, rangeIndex: 4) ?? 0
            guard (0 ... 59).contains(startMinute),
                  (0 ... 59).contains(endMinute)
            else { return nil }

            let start = startHour * 60 + startMinute
            let end = endHour * 60 + endMinute
            guard end - start >= 15 else { return nil }
            return AvailabilityWindow(startMinuteOfDay: start, endMinuteOfDay: end)
        }
        .sorted { $0.startMinuteOfDay < $1.startMinuteOfDay }
    }

    private func detectAvailableMinutes(_ text: String) -> Int? {
        if let hours = captureNumber(
            in: text,
            pattern: #"(\d+(?:[\.,]\d+)?)\s*(?:h|hora|horas)\b"#
        ) {
            return clampMinutes(Int(hours * 60))
        }

        if let minutes = captureNumber(
            in: text,
            pattern: #"(\d+)\s*(?:min|minuto|minutos)\b"#
        ) {
            return clampMinutes(Int(minutes))
        }

        let writtenHours: [(String, Int)] = [
            ("media hora", 30),
            ("una hora", 60),
            ("un hora", 60),
            ("dos horas", 120),
            ("tres horas", 180),
            ("cuatro horas", 240),
        ]
        return writtenHours.first(where: { text.contains($0.0) })?.1
    }

    private func detectStartMinute(_ text: String) -> Int? {
        let patterns = [
            #"(?:desde|a partir de|arranco|empiezo)(?:\s+a)?(?:\s+las)?\s+(\d{1,2})(?::(\d{2}))?"#,
            #"(?:a las)\s+(\d{1,2})(?::(\d{2}))?"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let hourRange = Range(match.range(at: 1), in: text),
                  let hour = Int(text[hourRange]),
                  (0 ... 23).contains(hour)
            else { continue }

            var minute = 0
            if match.numberOfRanges > 2,
               match.range(at: 2).location != NSNotFound,
               let minuteRange = Range(match.range(at: 2), in: text),
               let parsedMinute = Int(text[minuteRange]),
               (0 ... 59).contains(parsedMinute)
            {
                minute = parsedMinute
            }
            return hour * 60 + minute
        }

        return nil
    }

    private func detectEnergy(_ text: String) -> EnergyPreference? {
        if containsAny(text, ["cansada", "cansado", "sin energia", "poca energia", "agotada", "agotado"]) {
            return .tired
        }
        if containsAny(text, ["con energia", "mucha energia", "motivada", "motivado", "concentrada", "concentrado"]) {
            return .energized
        }
        return nil
    }

    private func clampMinutes(_ minutes: Int) -> Int {
        min(480, max(15, minutes))
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

    private func integer(
        in text: String,
        match: NSTextCheckingResult,
        rangeIndex: Int
    ) -> Int? {
        guard rangeIndex < match.numberOfRanges,
              match.range(at: rangeIndex).location != NSNotFound,
              let range = Range(match.range(at: rangeIndex), in: text)
        else { return nil }
        return Int(text[range])
    }
}

enum AgendaRequestValidator {
    static func merge(ai: AgendaRequestDraft, explicit: AgendaRequestDraft) -> AgendaRequestDraft {
        AgendaRequestDraft(
            availableMinutes: explicit.availableMinutes ?? ai.availableMinutes,
            startMinuteOfDay: explicit.startMinuteOfDay ?? ai.startMinuteOfDay,
            availabilityWindows: explicit.availabilityWindows ?? ai.availabilityWindows,
            energyPreference: explicit.energyPreference ?? ai.energyPreference
        )
    }
}
