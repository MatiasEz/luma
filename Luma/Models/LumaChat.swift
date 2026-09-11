import Foundation

enum LumaChatRole: String, Equatable {
    case user
    case assistant
}

struct LumaChatMessage: Identifiable, Equatable {
    var id = UUID()
    var role: LumaChatRole
    var text: String
    var suggestedAction: LumaChatSuggestedAction?
    var createdAt = Date()
}

enum LumaChatActionKind: String, Equatable {
    case replan
    case startFocus
    case completeTask
    case renameTask
    case changeDeadline
    case changeDuration
    case changeDueDate
    case prioritizeTask
    case rememberPreference
}

struct LumaChatSuggestedAction: Identifiable, Equatable {
    var id = UUID()
    var kind: LumaChatActionKind
    var label: String
    var taskID: UUID?
    var energyPreference: EnergyPreference?
    var availableMinutes: Int?
    var durationMinutes: Int?
    var dateValue: Date?
    var numericValue: Double?
}

struct LumaChatReply: Equatable {
    var message: String
    var suggestedAction: LumaChatSuggestedAction?
}

enum LumaChatTextCleaner {
    static func finalAnswer(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let closingTag = cleaned.range(
            of: "</think>",
            options: [.caseInsensitive, .backwards]
        ) {
            cleaned = String(cleaned[closingTag.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if cleaned.range(of: "<think>", options: .caseInsensitive) != nil {
            return ""
        }

        return cleaned
            .replacingOccurrences(of: "<think>", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "</think>", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
enum LumaAssistantContextBuilder {
    static func relevantTasks(_ tasks: [LumaTask], question: String, recommendations: [PlanRecommendation]) -> [LumaTask] {
        let query = question.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let words = Set(query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 })
        let planned = Set(recommendations.map(\.id))
        func relevance(_ task: LumaTask) -> Int {
            let title = task.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            let tokens = Set(title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            return words.intersection(tokens).count * 100 + (query.contains(title) ? 1000 : 0) + (planned.contains(task.id) ? 10 : 0)
        }
        return tasks.filter { $0.planningDetails.isRetired != true }.sorted {
            let lhs = relevance($0), rhs = relevance($1)
            if lhs != rhs { return lhs > rhs }
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            return ($0.dueDate ?? $0.deadline ?? .distantFuture) < ($1.dueDate ?? $1.deadline ?? .distantFuture)
        }
    }

    static func makeContext(
        tasks: [LumaTask],
        subjects: [AcademicSubject] = [],
        classMeetings: [SubjectClassMeeting] = [],
        recommendations: [PlanRecommendation],
        agenda: DailyAgendaSnapshot?,
        commitments: [CalendarCommitment],
        energyPreference: EnergyPreference,
        workload: WorkloadLevel,
        profile: LumaProfile? = nil,
        remainingAvailableMinutes: Int? = nil,
        question: String = "",
        rememberedPreferences: [String] = [],
        now: Date = .now
    ) -> String {
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "es_AR")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "es_AR")
        timeFormatter.dateFormat = "HH:mm"
        let activeSubjects = subjects.filter { !$0.isArchived }
        let subjectNamesByID = Dictionary(
            uniqueKeysWithValues: activeSubjects.map { ($0.id, $0.name) }
        )
        let pending = tasks
            .filter { !$0.isCompleted }
            .sorted {
                switch ($0.deadline, $1.deadline) {
                case let (left?, right?): left < right
                case (.some, .none): true
                case (.none, .some): false
                case (.none, .none): $0.createdAt < $1.createdAt
                }
            }
        let relevantTasks = relevantTasks(tasks, question: question, recommendations: recommendations)
        let taskLines = relevantTasks.prefix(40).map { task in
            let deadline = task.dueDate.map(dateFormatter.string(from:)) ?? "sin fecha de entrega"
            let scheduled = task.deadline.map { "\(dateFormatter.string(from: $0)) \(timeFormatter.string(from: $0))" } ?? "sin horario elegido"
            let subject = task.academicSubjectID
                .flatMap { subjectNamesByID[$0] }
                .map { " · materia \($0)" } ?? ""
            let unlock = task.unlocksTaskID.flatMap { targetID in
                tasks.first { $0.id == targetID }?.title
            }.map { " · al completarse desbloquea \($0)" }
                ?? (task.unlocksAnotherTask ? " · desbloquea otra tarea" : "")
            let blockerNames = TaskDependencyResolver.blockers(for: task.id, in: tasks).map(\.title)
            let blocked = blockerNames.isEmpty ? "" : " · BLOQUEADA por \(blockerNames.joined(separator: ", "))"
            return "- id=\(task.id.uuidString) · \(task.title) · \(task.area.title)\(subject) · entrega \(deadline) · programada \(scheduled) · duración estimada \(task.estimatedMinutes) min · quedan \(task.remainingEstimatedMinutes) min · energía \(task.energy.title.lowercased()) · impacto \(task.impact.title.lowercased()) · postergada \(task.postponementCount) veces\(unlock)\(blocked)"
        }.joined(separator: "\n")

        let subjectLines = activeSubjects.map { subject in
            let pendingCount = pending.filter { $0.academicSubjectID == subject.id }.count
            return "- id=\(subject.id.uuidString) · \(subject.name) · \(pendingCount) pendientes"
        }.joined(separator: "\n")

        let classMeetingLines = classMeetings
            .filter { subjectNamesByID[$0.subjectID] != nil }
            .sorted {
                $0.weekday == $1.weekday
                    ? $0.startMinuteOfDay < $1.startMinuteOfDay
                    : $0.weekday < $1.weekday
            }
            .map { meeting in
                let subject = subjectNamesByID[meeting.subjectID] ?? "Materia"
                let start = minuteOfDayTitle(meeting.startMinuteOfDay)
                let end = minuteOfDayTitle(meeting.endMinuteOfDay)
                let location = meeting.location.trimmingCharacters(in: .whitespacesAndNewlines)
                let locationText = location.isEmpty ? "" : " · \(location)"
                return "- \(subject) · \(weekdayTitle(meeting.weekday)) \(start)–\(end)\(locationText)"
            }
            .joined(separator: "\n")

        let recommendationLines = recommendations.enumerated().map { index, item in
            "\(index + 1). id=\(item.task.id.uuidString) · \(item.task.title) · bloque sugerido \(item.suggestedMinutes) min · \(item.reason)"
        }.joined(separator: "\n")

        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let agendaLines = agenda?.blocks.compactMap { block -> String? in
            guard let task = tasksByID[block.taskID], !task.isCompleted else { return nil }
            let start = DailyScheduler(calendar: calendar).date(on: agenda?.day ?? now, minuteOfDay: block.startMinuteOfDay)
            return "- \(timeFormatter.string(from: start)) · \(task.title) · \(block.durationMinutes) min · id=\(task.id.uuidString)"
        }.joined(separator: "\n") ?? ""

        let commitmentLines = commitments.prefix(12).map { event in
            "- \(timeFormatter.string(from: event.start))–\(timeFormatter.string(from: event.end)) · \(event.title)"
        }.joined(separator: "\n")

        let areaCounts = Dictionary(grouping: pending, by: \.area)
            .map { "\($0.key.title): \($0.value.count)" }
            .sorted()
            .joined(separator: " · ")
        let completedThisWeek = tasks.filter { task in
            guard task.isCompleted, let completedAt = task.completedAt else { return false }
            return completedAt >= (calendar.date(byAdding: .day, value: -7, to: now) ?? now)
        }.count
        let preferredAreas = profile?.selectedAreas.map(\.title).joined(separator: ", ") ?? "sin preferencias"
        let gentleDays = profile?.gentleWeekdays.map(weekdayTitle).joined(separator: ", ") ?? "ninguno"
        let energyPeak = profile?.energyPeak.title.lowercased() ?? "sin definir"

        return """
        Preferencias que la usuaria confirmó: \(rememberedPreferences.joined(separator: "; "))
        Las fechas de entrega y los horarios de trabajo son datos distintos. Si faltan datos, pedilos; no inventes temas ni compromisos.

        Fecha y hora local: \(dateFormatter.string(from: now)) \(timeFormatter.string(from: now))
        Energía declarada: \(energyPreference.title)
        Tiempo que queda disponible hoy: \(remainingAvailableMinutes.map(durationTitle) ?? "sin confirmar")
        Carga semanal calculada: \(workload.title)
        Pendientes por área: \(areaCounts.isEmpty ? "ninguno" : areaCounts)
        Tareas completadas en los últimos 7 días: \(completedThisWeek)
        Áreas que la usuaria quiere cuidar: \(preferredAreas)
        Momento de mejor energía: \(energyPeak)
        Días protegidos: \(gentleDays)

        PLAN RECOMENDADO DE HOY:
        \(recommendationLines.isEmpty ? "Sin prioridades pendientes." : recommendationLines)

        AGENDA DE HOY:
        \(agendaLines.isEmpty ? "Sin bloques programados." : agendaLines)

        COMPROMISOS DEL CALENDARIO:
        \(commitmentLines.isEmpty ? "Sin compromisos compartidos con Luma." : commitmentLines)

        MATERIAS:
        \(subjectLines.isEmpty ? "Sin materias cargadas." : subjectLines)

        HORARIOS SEMANALES DE CLASE:
        \(classMeetingLines.isEmpty ? "Sin horarios de clase cargados." : classMeetingLines)

        PENDIENTES DISPONIBLES:
        \(taskLines.isEmpty ? "No hay pendientes." : taskLines)
        """
    }

    static func makeEvidence(
        tasks: [LumaTask],
        recommendations: [PlanRecommendation],
        agenda: DailyAgendaSnapshot?,
        commitments: [CalendarCommitment],
        energyPreference: EnergyPreference,
        profile: LumaProfile?,
        remainingAvailableMinutes: Int? = nil,
        now: Date = .now
    ) -> [String] {
        var evidence = ["Energía actual: \(energyPreference.title.lowercased())"]
        if let first = recommendations.first {
            evidence.append("Primera prioridad: \(first.task.title) · \(first.reason)")
        } else {
            evidence.append("No hay prioridades pendientes para hoy")
        }
        if let minutes = remainingAvailableMinutes ?? agenda?.availableMinutes {
            evidence.append(minutes == 0
                ? "No queda tiempo disponible confirmado"
                : "Tiempo que te queda: \(durationTitle(minutes))")
        }
        if !commitments.isEmpty {
            evidence.append("Calendario: \(commitments.count) compromisos respetados")
        } else if let profile {
            evidence.append("Mejor momento personal: \(profile.energyPeak.title.lowercased())")
        }
        let riskyCount = tasks.filter { task in
            guard !task.isCompleted else { return false }
            if task.postponementCount > 0 { return true }
            guard let deadline = task.deadline else { return false }
            return deadline <= (Calendar.current.date(byAdding: .day, value: 3, to: now) ?? now)
        }.count
        if riskyCount > 0 { evidence.append("Pendientes en riesgo: \(riskyCount)") }
        return Array(evidence.prefix(4))
    }

    private static func weekdayTitle(_ weekday: Int) -> String {
        let symbols = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"]
        guard symbols.indices.contains(weekday - 1) else { return "día" }
        return symbols[weekday - 1]
    }

    private static func minuteOfDayTitle(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private static func durationTitle(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) min" }
        if remainder == 0 { return hours == 1 ? "1 hora" : "\(hours) horas" }
        return "\(hours) h \(remainder) min"
    }
}
