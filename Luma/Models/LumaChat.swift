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
    case setGrade
    case changeDuration
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
    static func makeContext(
        tasks: [LumaTask],
        subjects: [AcademicSubject] = [],
        subjectGradeItems: [SubjectGradeItem] = [],
        recommendations: [PlanRecommendation],
        agenda: DailyAgendaSnapshot?,
        commitments: [CalendarCommitment],
        energyPreference: EnergyPreference,
        workload: WorkloadLevel,
        profile: LumaProfile? = nil,
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
        let activeGradeItems = subjectGradeItems.filter { !$0.isArchived }
        let gradeItemNamesByID = Dictionary(
            uniqueKeysWithValues: activeGradeItems.map { ($0.id, $0.title) }
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
        let relevantTasks = tasks
            .filter { !$0.isCompleted || $0.academicEvaluationStatus == .awaitingGrade }
            .sorted {
                switch ($0.deadline, $1.deadline) {
                case let (left?, right?): left < right
                case (.some, .none): true
                case (.none, .some): false
                case (.none, .none): $0.createdAt < $1.createdAt
                }
            }
        let taskLines = relevantTasks.prefix(40).map { task in
            let deadline = task.deadline.map(dateFormatter.string(from:)) ?? "sin fecha"
            let weight = task.academicWeight.map { " · ponderación \(Int($0))%" } ?? ""
            let subject = task.academicSubjectID
                .flatMap { subjectNamesByID[$0] }
                .map { " · materia \($0)" } ?? ""
            let category = task.subjectGradeItemID
                .flatMap { gradeItemNamesByID[$0] }
                .map { " · categoría \($0)" } ?? ""
            let evaluation = task.academicEvaluationStatus.map { " · estado \($0.title.lowercased())" } ?? ""
            let grade = task.grade.map { " · nota \($0.formatted(.number.precision(.fractionLength(0 ... 2))))/10" } ?? ""
            let unlock = task.unlocksTaskID.flatMap { targetID in
                tasks.first { $0.id == targetID }?.title
            }.map { " · al completarse desbloquea \($0)" }
                ?? (task.unlocksAnotherTask ? " · desbloquea otra tarea" : "")
            let blockerNames = TaskDependencyResolver.blockers(for: task.id, in: tasks).map(\.title)
            let blocked = blockerNames.isEmpty ? "" : " · BLOQUEADA por \(blockerNames.joined(separator: ", "))"
            return "- id=\(task.id.uuidString) · \(task.title) · \(task.area.title)\(subject)\(category)\(evaluation)\(grade) · vence \(deadline) · duración estimada \(task.estimatedMinutes) min · quedan \(task.remainingEstimatedMinutes) min · energía \(task.energy.title.lowercased()) · impacto \(task.impact.title.lowercased()) · postergada \(task.postponementCount) veces\(weight)\(unlock)\(blocked)"
        }.joined(separator: "\n")

        let subjectLines = activeSubjects.map { subject in
            let pendingCount = pending.filter { $0.academicSubjectID == subject.id }.count
            let target = subject.targetGrade.map { " · objetivo \($0.formatted(.number.precision(.fractionLength(0 ... 2))))/10" } ?? ""
            return "- id=\(subject.id.uuidString) · \(subject.name)\(target) · \(pendingCount) pendientes"
        }.joined(separator: "\n")

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
        Fecha y hora local: \(dateFormatter.string(from: now)) \(timeFormatter.string(from: now))
        Energía declarada: \(energyPreference.title)
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
        now: Date = .now
    ) -> [String] {
        var evidence = ["Energía actual: \(energyPreference.title.lowercased())"]
        if let first = recommendations.first {
            evidence.append("Primera prioridad: \(first.task.title) · \(first.reason)")
        } else {
            evidence.append("No hay prioridades pendientes para hoy")
        }
        if let agenda {
            evidence.append(agenda.availableMinutes == 0
                ? "Hoy está marcado como día protegido"
                : "Tiempo disponible hoy: \(durationTitle(agenda.availableMinutes))")
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
        DayAvailability.standardWeek.first(where: { $0.weekday == weekday })?.shortTitle ?? "Día"
    }

    private static func durationTitle(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) min" }
        if remainder == 0 { return hours == 1 ? "1 hora" : "\(hours) horas" }
        return "\(hours) h \(remainder) min"
    }
}
