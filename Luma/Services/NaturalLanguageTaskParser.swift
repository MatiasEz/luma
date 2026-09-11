import Foundation

struct NaturalLanguageTaskParser {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func parse(_ input: String, now: Date = .now) -> ParsedTaskDraft {
        let normalized = input.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let detectedDate = detectDate(normalized, now: now)
        let describesDelivery = containsAny(
            normalized,
            ["entrego", "entregar", "entrega", "vence", "vencimiento", "fecha limite"]
        )

        return ParsedTaskDraft(
            title: cleanedTitle(input),
            area: detectArea(normalized),
            dueDate: describesDelivery ? detectedDate : nil,
            deadline: describesDelivery ? nil : detectedDate,
            estimatedMinutes: detectDuration(normalized),
            energy: detectEnergy(normalized),
            impact: detectImpact(normalized),
            academicWeight: detectWeight(normalized),
            unlocksAnotherTask: normalized.contains("bloquea") || normalized.contains("antes de"),
            notes: input
        )
    }

    private func detectWeight(_ text: String) -> Double? {
        guard let range = text.range(of: #"\b\d{1,3}(?:[.,]\d+)?\s*%"#, options: .regularExpression) else { return nil }
        let number = text[range].replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let value = Double(number), (0...100).contains(value) else { return nil }
        return value
    }

    func shouldUseAI(for draft: ParsedTaskDraft) -> Bool {
        draft.area == .errands
            && draft.dueDate == nil
            && draft.deadline == nil
            && draft.estimatedMinutes == 30
            && draft.energy == .medium
            && draft.impact == .general
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
        if containsAny(text, ["examen", "parcial", "entrega", "ensayo"]) { return .grade }
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

struct AcademicCaptureParser {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func parseMany(
        _ input: String,
        subjects: [AcademicSubject],
        now: Date = .now,
        limit: Int = 5
    ) -> [AcademicCaptureDraft] {
        let segments = Array(splitActivities(in: input).prefix(max(1, limit)))
        var lastSubjectID: UUID?
        var lastProposedSubjectName: String?
        return segments.map { segment in
            var draft = parse(segment, subjects: subjects, now: now)
            if draft.kind != .subject,
               draft.subjectID == nil,
               draft.proposedSubjectName == nil,
               continuesPreviousActivity(segment)
            {
                draft.subjectID = lastSubjectID
                draft.proposedSubjectName = lastProposedSubjectName
            }
            if let subjectID = draft.subjectID {
                lastSubjectID = subjectID
                lastProposedSubjectName = nil
            } else if let proposed = draft.proposedSubjectName {
                lastSubjectID = nil
                lastProposedSubjectName = proposed
            }
            return draft
        }
    }

    func parse(
        _ input: String,
        subjects: [AcademicSubject],
        now: Date = .now
    ) -> AcademicCaptureDraft {
        let normalized = normalizedSpanish(input)
        let weekday = detectWeekday(in: normalized)
        let kind = detectKind(in: normalized, hasWeekday: weekday != nil)
        let subject = bestSubjectMatch(in: normalized, subjects: subjects)
        let duration = detectDuration(in: normalized) ?? defaultDuration(for: kind)
        let detectedDate = detectDate(in: normalized, now: now)
        let minuteOfDay = detectTime(in: normalized)
        let explicitRecurrence = detectsRecurrence(in: normalized)
        let isRecurring = kind == .routine || kind == .classMeeting || explicitRecurrence
        let title = suggestedTitle(from: input, kind: kind, subject: subject)
        let inferredDate = detectedDate ?? {
            guard minuteOfDay != nil, kind == .task || kind == .study else { return nil }
            return calendar.startOfDay(for: now)
        }()
        let date = inferredDate.map { day in
            guard let minuteOfDay else { return day }
            return calendar.date(
                bySettingHour: minuteOfDay / 60,
                minute: minuteOfDay % 60,
                second: 0,
                of: day
            ) ?? day
        }

        return AcademicCaptureDraft(
            originalText: input,
            kind: kind,
            title: title,
            subjectID: kind == .subject ? nil : subject?.id,
            proposedSubjectName: kind == .subject ? title : nil,
            date: isRecurring || kind == .subject ? nil : date,
            weekday: kind == .subject ? nil : weekday,
            minuteOfDay: minuteOfDay,
            estimatedMinutes: duration,
            energy: detectEnergy(in: normalized, kind: kind),
            importance: detectImportance(in: normalized),
            activityType: detectActivity(in: normalized, kind: kind),
            topicsRaw: detectTopics(in: input, kind: kind),
            isRecurring: isRecurring
        )
    }

    private func splitActivities(in input: String) -> [String] {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let separator = "\n"
        let separatorPatterns = [
            #"\s+\d+[\.)]\s+(?=[A-Za-zÁÉÍÓÚÜÑáéíóúüñ])"#,
            #"[;\n]+"#,
            #"\.\s+(?=[A-ZÁÉÍÓÚÜÑ])"#,
            #"\s+(?:y\s+)?(?:además|ademas|también|tambien|después|despues|luego)\s*[:,]?\s+"#,
            #",\s*(?=(?:hoy|mañana|pasado\s+mañana|el\s+)?(?:lunes|martes|miércoles|miercoles|jueves|viernes|sábado|sabado|domingo)\b)"#,
            #"\s+y\s+(?=(?:(?:hoy|mañana|pasado\s+mañana|el\s+)?(?:lunes|martes|miércoles|miercoles|jueves|viernes|sábado|sabado|domingo)\b))"#,
            #"\s+y\s+(?=(?:crea(?:r)?|creame|créame|agrega(?:r)?|agregame|agrégame|anota(?:me)?|anótame|agenda(?:me)?|agendame|poneme|recordame|recuérdame|tengo\s+que|debo|necesito)\b)"#,
            #"\s+y\s+(?=(?:a\s+las?\s+(?:\d{1,2}(?::\d{2})?|una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|once|doce)\s+)?(?:quiero\s+)?(?:agregar|agrega(?:me)?|crear|crea(?:me)?|poner|poneme|anotar|anotame)\s+(?:otra?|una?)\b)"#,
        ]
        for pattern in separatorPatterns {
            text = text.replacingOccurrences(
                of: pattern,
                with: separator,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return text
            .components(separatedBy: .newlines)
            .map {
                $0.replacingOccurrences(
                    of: #"^\s*(?:[-•*]|\d+[\.)])\s*"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            }
            .filter { !$0.isEmpty }
    }

    private func continuesPreviousActivity(_ segment: String) -> Bool {
        let text = normalizedSpanish(segment)
        return containsAny(text, [
            " otra ", " otro ", "otra tarea", "otro pendiente", "una mas", "uno mas",
            "tambien", "ademas", "la segunda", "el segundo",
        ]) || text.hasPrefix("otra ") || text.hasPrefix("otro ")
    }

    private func detectKind(in text: String, hasWeekday: Bool) -> AcademicCaptureKind {
        if containsAny(text, [
            "crea una materia", "crear una materia", "crea la materia", "crear la materia",
            "agrega una materia", "agregar una materia", "nueva materia llamada",
            "crea una asignatura", "agrega una asignatura", "nueva asignatura",
        ]) { return .subject }
        if containsAny(text, [
            "clase de", "tengo clase", "cursada", "teorico de", "practico de", "comision de",
        ]) { return .classMeeting }
        if detectsRecurrence(in: text) { return .routine }
        if text.contains("laboratorio"), hasWeekday { return .routine }
        if containsAny(text, [
            "estudiar", "estudio ", "repasar", "practicar", "memorizar", "hacer ejercicios",
            "resolver ejercicios", "prepararme para", "preparar el examen", "preparar el parcial",
        ]) { return .study }
        if containsAny(text, [
            "examen", "parcial", "final", "rindo", "rendir", "prueba", "evaluacion",
            "recuperatorio", "coloquio", "mesa de examen",
        ]) { return .exam }
        return .task
    }

    private func detectActivity(in text: String, kind: AcademicCaptureKind) -> AcademicActivityType {
        if containsAny(text, ["laboratorio", "practica de laboratorio", "lab de"]) { return .laboratory }
        if containsAny(text, ["leer", "lectura", "capitulo", "apunte", "acordeon", "resumen de texto"]) { return .reading }
        if kind == .classMeeting || containsAny(text, ["clase", "cursada", "teorico", "practico"]) { return .classMeeting }
        if kind == .study || containsAny(text, ["estudiar", "repasar", "practicar", "memorizar", "ejercicios"]) { return .study }
        return .assignment
    }

    private func detectDate(in text: String, now: Date) -> Date? {
        let start = calendar.startOfDay(for: now)
        if text.contains("pasado manana") {
            return calendar.date(byAdding: .day, value: 2, to: start).map(atDefaultTime)
        }
        if text.contains("hoy") { return atDefaultTime(start) }
        if text.contains("manana") {
            return calendar.date(byAdding: .day, value: 1, to: start).map(atDefaultTime)
        }
        if let relativeDays = relativeDayOffset(in: text) {
            return calendar.date(byAdding: .day, value: relativeDays, to: start).map(atDefaultTime)
        }
        if containsAny(text, ["la semana que viene", "semana proxima", "proxima semana"]) {
            return calendar.date(byAdding: .day, value: 7, to: start).map(atDefaultTime)
        }
        if containsAny(text, ["fin de semana", "el finde", "para el finde"]) {
            return nextWeekday(7, from: start, allowToday: false).map(atDefaultTime)
        }
        if containsAny(text, ["fin de mes", "a fin de mes", "ultimo dia del mes"]) {
            return calendar.dateInterval(of: .month, for: start)
                .flatMap { calendar.date(byAdding: .day, value: -1, to: $0.end) }
                .map(atDefaultTime)
        }

        if let numericDate = detectNumericDate(in: text, now: now) {
            return numericDate
        }

        let months: [String: Int] = [
            "enero": 1, "febrero": 2, "marzo": 3, "abril": 4, "mayo": 5, "junio": 6,
            "julio": 7, "agosto": 8, "septiembre": 9, "setiembre": 9, "sep": 9, "sept": 9,
            "octubre": 10, "noviembre": 11, "diciembre": 12,
        ]
        if let regex = try? NSRegularExpression(pattern: #"\b(?:el\s+)?(\d{1,2})\s+(?:de\s+)?([a-z]+)(?:\s+de\s+(\d{4}))?"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let dayRange = Range(match.range(at: 1), in: text),
           let monthRange = Range(match.range(at: 2), in: text),
           let day = Int(text[dayRange]),
           let month = months[String(text[monthRange])]
        {
            let providedYear: Int? = match.range(at: 3).location == NSNotFound
                ? nil
                : Range(match.range(at: 3), in: text).flatMap { Int(text[$0]) }
            var year = providedYear ?? calendar.component(.year, from: now)
            var components = DateComponents(year: year, month: month, day: day, hour: 20)
            if providedYear == nil, let candidate = calendar.date(from: components), candidate < start {
                year += 1
                components.year = year
            }
            return calendar.date(from: components)
        }

        if let day = captureInteger(in: text, pattern: #"\b(?:el|para el)\s+(\d{1,2})(?![\d/:])"#),
           (1 ... 31).contains(day)
        {
            var components = calendar.dateComponents([.year, .month], from: start)
            components.day = day
            components.hour = 20
            if let candidate = calendar.date(from: components) {
                if candidate >= start { return candidate }
                return calendar.date(byAdding: .month, value: 1, to: candidate)
            }
        }

        guard let weekday = detectWeekday(in: text) else { return nil }
        let allowToday = containsAny(text, ["este ", "hoy "])
        return nextWeekday(weekday, from: start, allowToday: allowToday).map(atDefaultTime)
    }

    private func detectWeekday(in text: String) -> Int? {
        [
            ("domingo", 1), ("lunes", 2), ("martes", 3), ("miercoles", 4),
            ("jueves", 5), ("viernes", 6), ("sabado", 7),
        ].first { text.contains($0.0) }?.1
    }

    private func detectTime(in text: String) -> Int? {
        if text.contains("medianoche") { return 0 }
        if text.contains("mediodia") { return 12 * 60 }

        let dayPartPattern = #"\b(\d{1,2})\s+(?:de|por)\s+la\s+(manana|tarde|noche)\b"#
        if let hour = captureInteger(in: text, pattern: dayPartPattern),
           let dayPart = captureString(in: text, pattern: dayPartPattern, group: 2),
           (1 ... 12).contains(hour)
        {
            var adjustedHour = hour
            if dayPart != "manana", adjustedHour < 12 { adjustedHour += 12 }
            if dayPart == "manana", adjustedHour == 12 { adjustedHour = 0 }
            return adjustedHour * 60
        }

        let wordHourPattern = #"\b(?:a\s+las?|tipo(?:\s+las)?)\s+(una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|once|doce)(?:\s+y\s+(media|cuarto))?(?:\s+(?:de|por)\s+la\s+(manana|tarde|noche))?\b"#
        if let hourWord = captureString(in: text, pattern: wordHourPattern, group: 1),
           var hour = spanishHourValue(hourWord)
        {
            let fraction = captureString(in: text, pattern: wordHourPattern, group: 2)
            let dayPart = captureString(in: text, pattern: wordHourPattern, group: 3)
            if dayPart != nil, dayPart != "manana", hour < 12 { hour += 12 }
            if dayPart == "manana", hour == 12 { hour = 0 }
            if dayPart == nil, (1 ... 7).contains(hour) { hour += 12 }
            return hour * 60 + (fraction == "media" ? 30 : fraction == "cuarto" ? 15 : 0)
        }

        let patterns = [
            #"\b(?:a\s+las|a\s+la|tipo|tipo\s+las|alrededor\s+de\s+las|a\s+eso\s+de\s+las|cerca\s+de\s+las)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.|hs?|h)?"#,
            #"\b(\d{1,2}):(\d{2})\s*(am|pm|a\.m\.|p\.m\.)?"#,
            #"\b(\d{1,2})h(\d{2})\b"#,
        ]
        guard let match = patterns.compactMap({ pattern -> NSTextCheckingResult? in
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            else { return nil }
            return match
        }).first else { return nil }
        guard
              let hourRange = Range(match.range(at: 1), in: text),
              var hour = Int(text[hourRange]), hour <= 23
        else { return nil }
        let minute = match.range(at: 2).location == NSNotFound
            ? 0
            : Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
        let meridiem = match.range(at: 3).location == NSNotFound
            ? ""
            : Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? ""
        if meridiem.contains("p"), hour < 12 { hour += 12 }
        if meridiem.contains("a"), hour == 12 { hour = 0 }
        if meridiem.isEmpty, (1 ... 7).contains(hour) { hour += 12 }
        return hour * 60 + min(59, minute)
    }

    private func detectDuration(in text: String) -> Int? {
        if let hours = captureInteger(in: text, pattern: #"\b(\d{1,2})\s*h\s*(\d{1,2})\b"#),
           let minutes = captureInteger(in: text, pattern: #"\b\d{1,2}\s*h\s*(\d{1,2})\b"#)
        {
            return min(900, max(5, hours * 60 + minutes))
        }
        if containsAny(text, ["una hora y media", "hora y media"]) { return 90 }
        if text.contains("media hora") { return 30 }
        if containsAny(text, ["un cuarto de hora", "cuarto de hora"]) { return 15 }
        if containsAny(text, ["un par de horas", "par de horas"]) { return 120 }
        if let value = captureNumber(in: text, pattern: #"(\d+(?:[\.,]\d+)?)\s*(?:h|hora|horas)\b"#) {
            return max(5, Int(value * 60))
        }
        if let value = captureNumber(in: text, pattern: #"(\d+)\s*(?:min|minuto|minutos)\b"#) {
            return max(5, Int(value))
        }
        if let value = spanishDurationNumber(in: text, unit: "hora") {
            return max(5, value * 60)
        }
        if let value = spanishDurationNumber(in: text, unit: "minuto") {
            return max(5, value)
        }
        return nil
    }

    private func defaultDuration(for kind: AcademicCaptureKind) -> Int {
        switch kind {
        case .subject: 30
        case .exam: 300
        case .classMeeting: 90
        case .routine: 40
        case .study: 45
        case .task: 30
        }
    }

    private func detectEnergy(in text: String, kind: AcademicCaptureKind) -> EnergyLevel {
        if containsAny(text, [
            "facil", "corto", "baja energia", "sin pensar mucho", "tranqui", "tranquilo",
            "simple", "liviano", "mecanico", "rapidito",
        ]) { return .low }
        if kind == .exam || containsAny(text, [
            "dificil", "intenso", "alta energia", "mucha concentracion", "pesado", "complejo",
            "complicado", "demandante",
        ]) { return .high }
        return .medium
    }

    private func detectImportance(in text: String) -> ExamImportance {
        if containsAny(text, [
            "muy importante", "final", "critico", "urgente", "prioridad maxima", "clave", "si o si",
        ]) { return .critical }
        if containsAny(text, ["importante", "parcial", "examen", "prioridad", "evaluacion", "prueba"]) { return .important }
        return .normal
    }

    private func detectTopics(in input: String, kind: AcademicCaptureKind) -> String {
        guard kind == .exam || kind == .subject else { return "" }
        let patterns = [
            #"(?i)\b(?:sobre|temas?|temario|incluye|entra(?:n)?|abarca)\s*:?\s+(.+)$"#,
            #"(?i)\bcon\s+(?:los\s+)?temas?\s+(.+)$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
                  let range = Range(match.range(at: 1), in: input)
            else { continue }
            return input[range]
                .replacingOccurrences(of: " y ", with: ", ")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        return ""
    }

    private func suggestedTitle(from input: String, kind: AcademicCaptureKind, subject: AcademicSubject?) -> String {
        if let explicitTitle = AcademicCaptureTitleExtractor.explicitTitle(from: input) {
            return explicitTitle
        }

        let subjectName = subject?.name ?? "la materia"
        switch kind {
        case .subject:
            let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = normalized.replacingOccurrences(
                of: #"(?i)^\s*(?:crea(?:r)?|agrega(?:r)?)\s+(?:una|la)?\s*materia\s+"#,
                with: "",
                options: .regularExpression
            )
            return stripped.isEmpty ? "Nueva materia" : String(stripped.prefix(180))
        case .exam: return "Examen de \(subjectName)"
        case .classMeeting: return "Clase de \(subjectName)"
        case .routine where fold(input).contains("laboratorio"): return "Laboratorio de \(subjectName)"
        default:
            if let inferred = AcademicCaptureTitleExtractor.inferredActionTitle(from: input) {
                return inferred
            }
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Nueva actividad" : String(trimmed.prefix(180))
        }
    }

}

enum AcademicCaptureTitleExtractor {
    static func explicitTitle(from input: String) -> String? {
        let patterns = [
            #"(?i)\b(?:llamada|llamado|titulada|titulado|que\s+se\s+llame|que\s+sea|que\s+diga|con\s+el\s+nombre\s+de|de\s+nombre)\s+[\"“”]?(.+?)[\"“”]?(?=\s+(?:para\s+hoy|para\s+mañana|para\s+pasado\s+mañana|para\s+el|hoy\b|mañana\b|el\s+(?:lunes|martes|miércoles|miercoles|jueves|viernes|sábado|sabado|domingo)|a\s+las?|todos\s+los|todas\s+las|cada\s+)|$)"#,
            #"(?i)\b(?:nombre|titulo)\s*:\s*[\"“”]?(.+?)[\"“”]?(?=\s+(?:para|hoy|mañana|el\s+|a\s+las?|todos|cada)|$)"#,
        ]
        return firstCapturedTitle(in: input, patterns: patterns)
    }

    static func inferredActionTitle(from input: String) -> String? {
        let patterns = [
            #"(?i)^\s*(?:crea(?:r)?|creame|créame|agrega(?:r)?|agregame|agrégame|carga(?:r)?|cargame|cárgame)\s+(?:(?:una?|la)\s+)?(?:tarea|pendiente|recordatorio|actividad|rutina|bloque\s+de\s+estudio)?\s*(.+)$"#,
            #"(?i)^\s*(?:recordame|recuérdame|acordate\s+de|anota(?:me)?|anótame|agenda(?:me)?|agendame|agéndame|poneme|poné|apunta(?:me)?|apuntame)\s+(?:que\s+)?(.+)$"#,
            #"(?i)^\s*(?:tengo\s+que|debo|necesito|quiero)\s+(.+)$"#,
            #"(?i)^\s*(?:(?:todos?|todas?|cada|los|las)\s+(?:[a-z]{0,2})?(?:los|las)?\s*)?(?:lunes|martes|miércoles|miercoles|jueves|viernes|sábado|sabado|domingo)s?\s*[:,]?\s*(.+)$"#,
            #"(?i)^\s*(?:hoy|mañana|pasado\s+mañana)\s*[:,]?\s*(.+)$"#,
        ]
        guard let captured = firstCapturedTitle(in: input, patterns: patterns) else { return nil }
        return cleanedActionTitle(captured)
    }

    private static func firstCapturedTitle(in input: String, patterns: [String]) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
                  let range = Range(match.range(at: 1), in: input)
            else { continue }
            let title = cleanedActionTitle(String(input[range]))
            if !title.isEmpty { return title }
        }
        return nil
    }

    private static func cleanedActionTitle(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let trailingPatterns = [
            #"(?i)\s+(?:para\s+)?(?:hoy|mañana|pasado\s+mañana|esta\s+noche|esta\s+tarde)\b.*$"#,
            #"(?i)\s+(?:para\s+)?(?:el|este|esta|próximo|proximo|la\s+próxima|la\s+proxima)\s+(?:lunes|martes|miércoles|miercoles|jueves|viernes|sábado|sabado|domingo|semana|finde|fin\s+de\s+semana)\b.*$"#,
            #"(?i)\s+(?:todos?|todas?|cada|los|las)\s+(?:[a-z]{0,2})?(?:los|las)?\s*(?:lunes|martes|miércoles|miercoles|jueves|viernes|sábado|sabado|domingo)s?\b.*$"#,
            #"(?i)\s+(?:a\s+las?|tipo(?:\s+las)?|alrededor\s+de\s+las|a\s+eso\s+de\s+las)\s+\d{1,2}(?::\d{2})?.*$"#,
            #"(?i)\s+(?:durante|por)\s+(?:\d+(?:[\.,]\d+)?|una?|dos|tres|cuatro|cinco|seis)\s*(?:h|hs|horas?|min(?:utos?)?)\b.*$"#,
            #"(?i)\s+en\s+\d+\s+(?:dias?|semanas?)\b.*$"#,
        ]
        for pattern in trailingPatterns {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        value = value
            .replacingOccurrences(of: #"(?i)^\s*(?:una?|la|el)\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !value.isEmpty else { return "" }
        return String(value.prefix(1).uppercased() + value.dropFirst()).prefix(180).description
    }
}

private extension AcademicCaptureParser {
    func normalizedSpanish(_ text: String) -> String {
        fold(text)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "finde", with: "fin de semana")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func bestSubjectMatch(in text: String, subjects: [AcademicSubject]) -> AcademicSubject? {
        let activeSubjects = subjects.filter { !$0.isArchived }
        if let exact = activeSubjects
            .sorted(by: { $0.name.count > $1.name.count })
            .first(where: { text.contains(normalizedSpanish($0.name)) })
        {
            return exact
        }

        let inputWords = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 || Int($0) != nil }
        let scored = activeSubjects.compactMap { subject -> (AcademicSubject, Int)? in
            let subjectWords = normalizedSpanish(subject.name)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 || Int($0) != nil }
            guard !subjectWords.isEmpty else { return nil }
            let score = subjectWords.reduce(0) { total, subjectWord in
                let best = inputWords.reduce(0) { current, inputWord in
                    if inputWord == subjectWord { return max(current, 4) }
                    if canonicalSubjectWord(inputWord) == canonicalSubjectWord(subjectWord) {
                        return max(current, 4)
                    }
                    if min(inputWord.count, subjectWord.count) >= 5,
                       inputWord.hasPrefix(subjectWord) || subjectWord.hasPrefix(inputWord)
                    {
                        return max(current, 3)
                    }
                    if min(inputWord.count, subjectWord.count) >= 5,
                       isWithinOneEdit(inputWord, of: subjectWord)
                    {
                        return max(current, 2)
                    }
                    return current
                }
                return total + best
            }
            return score >= 3 ? (subject, score) : nil
        }
        return scored.max { $0.1 < $1.1 }?.0
    }

    func canonicalSubjectWord(_ word: String) -> String {
        if word.count > 5, word.hasSuffix("itos") { return String(word.dropLast(4)) + "os" }
        if word.count > 5, word.hasSuffix("itas") { return String(word.dropLast(4)) + "as" }
        if word.count > 4, word.hasSuffix("ito") { return String(word.dropLast(3)) + "o" }
        if word.count > 4, word.hasSuffix("ita") { return String(word.dropLast(3)) + "a" }
        return word
    }

    func relativeDayOffset(in text: String) -> Int? {
        let patterns: [(String, Int)] = [
            (#"\b(?:en|dentro\s+de)\s+(\d+)\s+dias?\b"#, 1),
            (#"\b(?:en|dentro\s+de)\s+(\d+)\s+semanas?\b"#, 7),
        ]
        for (pattern, multiplier) in patterns {
            if let value = captureInteger(in: text, pattern: pattern) {
                return min(365, max(0, value * multiplier))
            }
        }

        if let word = captureString(
            in: text,
            pattern: #"\b(?:en|dentro\s+de)\s+(un|una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|quince)\s+(dias?|semanas?)\b"#,
            group: 1
        ), let unit = captureString(
            in: text,
            pattern: #"\b(?:en|dentro\s+de)\s+(?:un|una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|quince)\s+(dias?|semanas?)\b"#,
            group: 1
        ) {
            let multiplier = unit.hasPrefix("semana") ? 7 : 1
            return spanishNumberValue(word).map { $0 * multiplier }
        }
        return nil
    }

    func detectNumericDate(in text: String, now: Date) -> Date? {
        let patterns = [
            #"\b(\d{4})[-/](\d{1,2})[-/](\d{1,2})\b"#,
            #"\b(\d{1,2})[/-](\d{1,2})(?:[/-](\d{2,4}))?\b"#,
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            else { continue }

            let first = integer(in: text, match: match, group: 1)
            let second = integer(in: text, match: match, group: 2)
            let third = integer(in: text, match: match, group: 3)
            let currentYear = calendar.component(.year, from: now)
            var year: Int
            let month: Int
            let day: Int
            if index == 0 {
                year = first ?? currentYear
                month = second ?? 0
                day = third ?? 0
            } else {
                day = first ?? 0
                month = second ?? 0
                year = third ?? currentYear
                if year < 100 { year += 2_000 }
            }
            guard (1 ... 31).contains(day), (1 ... 12).contains(month) else { continue }
            var components = DateComponents(year: year, month: month, day: day, hour: 20)
            guard var candidate = calendar.date(from: components) else { continue }
            if third == nil, candidate < calendar.startOfDay(for: now) {
                components.year = year + 1
                candidate = calendar.date(from: components) ?? candidate
            }
            return candidate
        }
        return nil
    }

    func nextWeekday(_ weekday: Int, from start: Date, allowToday: Bool) -> Date? {
        let current = calendar.component(.weekday, from: start)
        var offset = (weekday - current + 7) % 7
        if offset == 0, !allowToday { offset = 7 }
        return calendar.date(byAdding: .day, value: offset, to: start)
    }

    func spanishDurationNumber(in text: String, unit: String) -> Int? {
        let pattern = #"\b(un|una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|quince|veinte|veinticinco|treinta|cuarenta|cuarenta\s+y\s+cinco|cincuenta|sesenta|noventa)\s+"#
            + unit + #"s?\b"#
        return captureString(in: text, pattern: pattern, group: 1).flatMap(spanishNumberValue)
    }

    func spanishNumberValue(_ value: String) -> Int? {
        [
            "un": 1, "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5,
            "seis": 6, "siete": 7, "ocho": 8, "nueve": 9, "diez": 10,
            "quince": 15, "veinte": 20, "veinticinco": 25, "treinta": 30,
            "cuarenta": 40, "cuarenta y cinco": 45, "cincuenta": 50,
            "sesenta": 60, "noventa": 90,
        ][value]
    }

    func spanishHourValue(_ value: String) -> Int? {
        if value == "once" { return 11 }
        if value == "doce" { return 12 }
        return spanishNumberValue(value)
    }

    func detectsRecurrence(in text: String) -> Bool {
        if containsAny(text, [
            "todos los", "todas las", "cada ", "semanalmente", "semanal ",
            "todas las semanas", "cada semana", "de lunes a viernes",
        ]) { return true }

        let pluralWeekdayPattern = #"\b(?:los|las)\s+(?:lunes|martes|miercoles|jueves|viernes|sabados|domingos)\b"#
        if text.range(of: pluralWeekdayPattern, options: .regularExpression) != nil { return true }

        let words = text
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        let weekdays = ["domingo", "lunes", "martes", "miercoles", "jueves", "viernes", "sabado"]

        for index in words.indices {
            let word = words[index]
            let isEvery = isWithinOneEdit(word, of: "todos")
                || isWithinOneEdit(word, of: "todas")
                || isWithinOneEdit(word, of: "cada")
            guard isEvery else { continue }

            let end = min(words.count, index + 4)
            let following = words[(index + 1) ..< end]
            let hasWeekday = following.contains { candidate in
                weekdays.contains { candidate.hasPrefix($0) || isWithinOneEdit(candidate, of: $0) }
            }
            let hasArticle = following.prefix(2).contains {
                isWithinOneEdit($0, of: "los") || isWithinOneEdit($0, of: "las")
            }
            if hasWeekday, word == "cada" || hasArticle || following.first.map({ candidate in
                weekdays.contains { candidate.hasPrefix($0) }
            }) == true {
                return true
            }
        }
        return false
    }

    func isWithinOneEdit(_ source: String, of target: String) -> Bool {
        if source == target { return true }
        let left = Array(source)
        let right = Array(target)
        guard abs(left.count - right.count) <= 1 else { return false }

        var leftIndex = 0
        var rightIndex = 0
        var edits = 0
        while leftIndex < left.count, rightIndex < right.count {
            if left[leftIndex] == right[rightIndex] {
                leftIndex += 1
                rightIndex += 1
                continue
            }
            edits += 1
            guard edits <= 1 else { return false }
            if left.count > right.count {
                leftIndex += 1
            } else if right.count > left.count {
                rightIndex += 1
            } else {
                leftIndex += 1
                rightIndex += 1
            }
        }
        if leftIndex < left.count || rightIndex < right.count { edits += 1 }
        return edits <= 1
    }

    func atDefaultTime(_ day: Date) -> Date {
        calendar.date(bySettingHour: 20, minute: 0, second: 0, of: day) ?? day
    }

    func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
    }

    func containsAny(_ text: String, _ values: [String]) -> Bool {
        values.contains(where: text.contains)
    }

    func captureNumber(in text: String, pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Double(text[range].replacingOccurrences(of: ",", with: "."))
    }

    func captureInteger(in text: String, pattern: String) -> Int? {
        captureString(in: text, pattern: pattern, group: 1).flatMap(Int.init)
    }

    func captureString(in text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > group,
              match.range(at: group).location != NSNotFound,
              let range = Range(match.range(at: group), in: text)
        else { return nil }
        return String(text[range])
    }

    func integer(in text: String, match: NSTextCheckingResult, group: Int) -> Int? {
        guard match.numberOfRanges > group,
              match.range(at: group).location != NSNotFound,
              let range = Range(match.range(at: group), in: text)
        else { return nil }
        return Int(text[range])
    }
}

enum AcademicCaptureInterpretationValidator {
    static func reinforcingExplicitSignals(
        in result: AcademicCaptureInterpretationResult,
        with explicitDrafts: [AcademicCaptureDraft]
    ) -> AcademicCaptureInterpretationResult {
        if explicitDrafts.count > result.drafts.count {
            return AcademicCaptureInterpretationResult(
                drafts: explicitDrafts,
                notice: result.notice
            )
        }
        guard result.drafts.count == explicitDrafts.count else { return result }
        let reinforced = zip(result.drafts, explicitDrafts).map { pair in
            reinforce(ai: pair.0, explicit: pair.1)
        }
        return AcademicCaptureInterpretationResult(drafts: reinforced, notice: result.notice)
    }

    static func reinforcingExplicitSignals(
        in result: AcademicCaptureInterpretationResult,
        with explicit: AcademicCaptureDraft
    ) -> AcademicCaptureInterpretationResult {
        guard result.drafts.count == 1 else { return result }
        return AcademicCaptureInterpretationResult(
            drafts: [reinforce(ai: result.drafts[0], explicit: explicit)],
            notice: result.notice
        )
    }

    private static func reinforce(
        ai: AcademicCaptureDraft,
        explicit: AcademicCaptureDraft
    ) -> AcademicCaptureDraft {
        var reinforced = ai

        if explicit.kind != .task || explicit.isRecurring {
            reinforced.kind = explicit.kind
        }
        if let title = AcademicCaptureTitleExtractor.explicitTitle(from: explicit.originalText) {
            reinforced.title = title
        }
        if let subjectID = explicit.subjectID {
            reinforced.subjectID = subjectID
            reinforced.proposedSubjectName = nil
        }
        if let date = explicit.date { reinforced.date = date }
        if let weekday = explicit.weekday { reinforced.weekday = weekday }
        if let minuteOfDay = explicit.minuteOfDay { reinforced.minuteOfDay = minuteOfDay }

        if explicit.isRecurring {
            reinforced.isRecurring = true
            reinforced.date = nil
        }
        if explicit.kind == .subject {
            reinforced.proposedSubjectName = reinforced.title
            reinforced.subjectID = nil
            reinforced.date = nil
        }

        return reinforced
    }
}

enum AcademicCaptureClarificationEngine {
    static func next(
        in drafts: [AcademicCaptureDraft],
        subjects: [AcademicSubject]
    ) -> AcademicCaptureClarification? {
        for draft in drafts {
            if titleNeedsClarification(draft) {
                return clarification(draftID: draft.id, field: .title, draft: draft, subjects: subjects)
            }

            if draft.kind != .subject,
               draft.subjectID == nil,
               let proposed = clean(draft.proposedSubjectName),
               !hasSubjectProposal(named: proposed, in: drafts)
            {
                return clarification(
                    draftID: draft.id,
                    field: .subjectConfirmation,
                    draft: draft,
                    subjects: subjects
                )
            }

            let requiresSubject = draft.kind == .exam || draft.kind == .classMeeting || draft.kind == .study
            if requiresSubject, draft.subjectID == nil {
                if draft.proposedSubjectName == nil {
                    return clarification(draftID: draft.id, field: .subject, draft: draft, subjects: subjects)
                }
            }

            if draft.kind == .exam, draft.date == nil {
                return clarification(draftID: draft.id, field: .date, draft: draft, subjects: subjects)
            }
            if draft.kind == .routine || draft.kind == .classMeeting, draft.weekday == nil {
                return clarification(draftID: draft.id, field: .weekday, draft: draft, subjects: subjects)
            }
            if draft.kind == .classMeeting, draft.minuteOfDay == nil {
                return clarification(draftID: draft.id, field: .time, draft: draft, subjects: subjects)
            }
        }
        return nil
    }

    static func apply(
        answer: String,
        to clarification: AcademicCaptureClarification,
        drafts: inout [AcademicCaptureDraft],
        subjects: [AcademicSubject],
        now: Date = .now
    ) {
        guard let draftIndex = drafts.firstIndex(where: { $0.id == clarification.draftID }) else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch clarification.field {
        case .title:
            drafts[draftIndex].title = answerTitle(from: trimmed)
            if drafts[draftIndex].kind == .subject {
                drafts[draftIndex].proposedSubjectName = drafts[draftIndex].title
            }

        case .subject:
            resolveSubject(
                from: trimmed,
                draftIndex: draftIndex,
                drafts: &drafts,
                subjects: subjects
            )

        case .subjectConfirmation:
            if isAffirmative(trimmed),
               let proposed = clean(drafts[draftIndex].proposedSubjectName)
            {
                if !hasSubjectProposal(named: proposed, in: drafts) {
                    drafts.append(AcademicCaptureDraft(
                        originalText: "Crear la materia \(proposed)",
                        kind: .subject,
                        title: proposed,
                        proposedSubjectName: proposed
                    ))
                }
            } else if isNegative(trimmed) {
                drafts[draftIndex].proposedSubjectName = nil
            } else {
                drafts[draftIndex].proposedSubjectName = nil
                resolveSubject(
                    from: trimmed,
                    draftIndex: draftIndex,
                    drafts: &drafts,
                    subjects: subjects
                )
            }

        case .date:
            let parsed = AcademicCaptureParser().parse(trimmed, subjects: subjects, now: now)
            if let date = parsed.date {
                drafts[draftIndex].date = date
            }
            if let minute = parsed.minuteOfDay {
                drafts[draftIndex].minuteOfDay = minute
            }

        case .weekday:
            let parsed = AcademicCaptureParser().parse(trimmed, subjects: subjects, now: now)
            if let weekday = parsed.weekday {
                drafts[draftIndex].weekday = weekday
            }
            if let minute = parsed.minuteOfDay {
                drafts[draftIndex].minuteOfDay = minute
            }

        case .time:
            let parsed = AcademicCaptureParser().parse("hoy \(trimmed)", subjects: subjects, now: now)
            if let minute = parsed.minuteOfDay {
                drafts[draftIndex].minuteOfDay = minute
            }
        }

        refreshGeneratedTitle(at: draftIndex, drafts: &drafts, subjects: subjects)
    }

    static func merge(
        _ interpreted: AcademicCaptureDraft,
        into existing: AcademicCaptureDraft,
        resolving field: AcademicCaptureMissingField
    ) -> AcademicCaptureDraft {
        var merged = existing
        switch field {
        case .title:
            if !titleNeedsClarification(interpreted) { merged.title = interpreted.title }
        case .subject:
            if let subjectID = interpreted.subjectID {
                merged.subjectID = subjectID
                merged.proposedSubjectName = nil
            } else if let proposed = clean(interpreted.proposedSubjectName) {
                merged.proposedSubjectName = proposed
            }
        case .subjectConfirmation:
            break
        case .date:
            merged.date = interpreted.date ?? merged.date
            merged.minuteOfDay = interpreted.minuteOfDay ?? merged.minuteOfDay
        case .weekday:
            merged.weekday = interpreted.weekday ?? merged.weekday
            merged.minuteOfDay = interpreted.minuteOfDay ?? merged.minuteOfDay
        case .time:
            merged.minuteOfDay = interpreted.minuteOfDay ?? merged.minuteOfDay
        }
        return merged
    }

    private static func clarification(
        draftID: UUID,
        field: AcademicCaptureMissingField,
        draft: AcademicCaptureDraft,
        subjects: [AcademicSubject]
    ) -> AcademicCaptureClarification {
        let item = displayName(for: draft)
        let question: String
        switch field {
        case .title:
            question = "¿Cómo querés llamar a esta \(draft.kind.title.lowercased())?"
        case .subject:
            let names = subjects.filter { !$0.isArchived }.prefix(4).map(\.name)
            let options = names.isEmpty ? "" : " Tenés: \(names.joined(separator: ", "))."
            question = "¿A qué materia corresponde \(item)?\(options)"
        case .subjectConfirmation:
            let name = clean(draft.proposedSubjectName) ?? "esa materia"
            question = "No encuentro “\(name)” entre tus materias. ¿Querés que también la cree?"
        case .date:
            question = "¿Qué día es \(item)? Podés decirme, por ejemplo, ‘el 12 de septiembre’."
        case .weekday:
            question = "¿Qué día de la semana se repite \(item)?"
        case .time:
            question = "¿A qué hora empieza \(item)?"
        }
        return AcademicCaptureClarification(draftID: draftID, field: field, question: question)
    }

    private static func resolveSubject(
        from answer: String,
        draftIndex: Int,
        drafts: inout [AcademicCaptureDraft],
        subjects: [AcademicSubject]
    ) {
        let requested = subjectName(from: answer)
        guard !requested.isEmpty else { return }
        if let subject = bestSubject(named: requested, in: subjects) {
            drafts[draftIndex].subjectID = subject.id
            drafts[draftIndex].proposedSubjectName = nil
        } else {
            drafts[draftIndex].subjectID = nil
            drafts[draftIndex].proposedSubjectName = requested
        }
    }

    private static func bestSubject(named value: String, in subjects: [AcademicSubject]) -> AcademicSubject? {
        let requested = folded(value)
        return subjects
            .filter { !$0.isArchived }
            .sorted { $0.name.count > $1.name.count }
            .first { subject in
                let candidate = folded(subject.name)
                return candidate == requested || candidate.contains(requested) || requested.contains(candidate)
            }
    }

    private static func refreshGeneratedTitle(
        at index: Int,
        drafts: inout [AcademicCaptureDraft],
        subjects: [AcademicSubject]
    ) {
        guard drafts.indices.contains(index) else { return }
        let draft = drafts[index]
        guard generatedTitle(draft.title) else { return }
        let subjectName = draft.subjectID.flatMap { id in subjects.first { $0.id == id }?.name }
            ?? clean(draft.proposedSubjectName)
        guard let subjectName else { return }
        drafts[index].title = switch draft.kind {
        case .exam: "Examen de \(subjectName)"
        case .classMeeting: "Clase de \(subjectName)"
        case .study: "Estudiar \(subjectName)"
        case .routine: "Rutina de \(subjectName)"
        default: draft.title
        }
    }

    private static func titleNeedsClarification(_ draft: AcademicCaptureDraft) -> Bool {
        let title = folded(draft.title)
        if title.isEmpty || generatedTitle(title) { return true }
        let emptyCommands: Set<String> = [
            "crea una tarea", "crear una tarea", "agrega una tarea", "crear tarea", "crea tarea",
            "crea una rutina", "crear una rutina", "crea un examen", "crear un examen",
            "crea una materia", "crear una materia", "nueva tarea", "nueva actividad", "nueva materia",
        ]
        return emptyCommands.contains(title)
    }

    private static func generatedTitle(_ value: String) -> Bool {
        let title = folded(value)
        return [
            "nueva tarea", "nueva actividad", "nueva materia", "examen de la materia",
            "clase de la materia", "estudiar la materia", "rutina de la materia",
        ].contains(title)
    }

    private static func displayName(for draft: AcademicCaptureDraft) -> String {
        titleNeedsClarification(draft) ? "esta \(draft.kind.title.lowercased())" : "“\(draft.title)”"
    }

    private static func hasSubjectProposal(named name: String, in drafts: [AcademicCaptureDraft]) -> Bool {
        let target = folded(name)
        return drafts.contains { $0.kind == .subject && folded($0.title) == target }
    }

    private static func answerTitle(from answer: String) -> String {
        if let explicit = AcademicCaptureTitleExtractor.explicitTitle(from: answer) { return explicit }
        let stripped = answer.replacingOccurrences(
            of: #"(?i)^\s*(?:se\s+llama|llamala|llámala|ponele|ponéle|el\s+nombre\s+es|que\s+sea)\s+"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return stripped.isEmpty ? answer : String(stripped.prefix(180))
    }

    private static func subjectName(from answer: String) -> String {
        let stripped = answer.replacingOccurrences(
            of: #"(?i)^\s*(?:es|de|la\s+materia|materia|asignatura|una\s+nueva\s+materia|nueva\s*:?)\s+"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return String((stripped.isEmpty ? answer : stripped).prefix(120))
    }

    private static func isAffirmative(_ value: String) -> Bool {
        let answer = folded(value)
        return ["si", "sí", "dale", "ok", "okay", "bueno", "creala", "crearla", "agregala"].contains {
            answer == folded($0) || answer.hasPrefix("\(folded($0)) ")
        }
    }

    private static func isNegative(_ value: String) -> Bool {
        let answer = folded(value)
        return answer == "no" || answer.hasPrefix("no ") || answer.contains("otra materia")
    }

    private static func clean(_ value: String?) -> String? {
        let result = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return result.isEmpty ? nil : result
    }

    private static func folded(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}

enum ParsedTaskValidator {
    /// Explicit dates, durations and keywords are deterministic and win over
    /// a small model. DeepSeek only fills fields for which the local parser found no signal.
    static func merge(ai: ParsedTaskDraft, explicit: ParsedTaskDraft) -> ParsedTaskDraft {
        ParsedTaskDraft(
            title: explicit.title,
            area: explicit.area == .errands ? ai.area : explicit.area,
            dueDate: explicit.dueDate ?? ai.dueDate,
            deadline: explicit.deadline ?? ai.deadline,
            estimatedMinutes: explicit.estimatedMinutes == 30 ? ai.estimatedMinutes : explicit.estimatedMinutes,
            energy: explicit.energy == .medium ? ai.energy : explicit.energy,
            impact: explicit.impact == .general ? ai.impact : explicit.impact,
            academicWeight: explicit.academicWeight ?? ai.academicWeight,
            academicSubjectID: explicit.academicSubjectID ?? ai.academicSubjectID,
            subjectGradeItemID: nil,
            grade: nil,
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
        let afterThinking = text.range(of: "</think>", options: .backwards).map {
            String(text[$0.upperBound...])
        } ?? withoutThinking
        let candidates = [
            withoutThinking,
            afterThinking,
            text,
            normalizedJSONLike(withoutThinking),
            normalizedJSONLike(afterThinking),
            normalizedJSONLike(text),
        ]

        for candidate in candidates {
            if let data = extractValidObject(from: candidate, requiringAny: requiredKeys) {
                return data
            }
        }
        return nil
    }

    private static func normalizedJSONLike(_ text: String) -> String {
        var normalized = text
            .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"\bNone\b"#, with: "null", options: .regularExpression)
            .replacingOccurrences(of: #"\bTrue\b"#, with: "true", options: .regularExpression)
            .replacingOccurrences(of: #"\bFalse\b"#, with: "false", options: .regularExpression)

        normalized = normalized.replacingOccurrences(
            of: #"([\{\[,]\s*)'([^'\n]+)'\s*:"#,
            with: #"$1"$2":"#,
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #":\s*'([^'\n]*)'(?=\s*[,\}])"#,
            with: #": "$1""#,
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"([\[,]\s*)'([^'\n]*)'(?=\s*[,\]])"#,
            with: #"$1"$2""#,
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #",\s*([\}\]])"#,
            with: "$1",
            options: .regularExpression
        )
        return normalized
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
