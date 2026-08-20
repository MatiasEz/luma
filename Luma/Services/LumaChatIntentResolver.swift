import Foundation

enum LumaFocusIntentResolution {
    case notRequested
    case resolved(message: String, action: LumaChatSuggestedAction)
    case needsClarification(message: String)
}

enum LumaChatIntentResolver {
    static func resolveFocus(
        question: String,
        modelAction: LumaChatSuggestedAction?,
        tasks: [LumaTask],
        subjects: [AcademicSubject],
        recommendations: [PlanRecommendation]
    ) -> LumaFocusIntentResolution {
        if let modelAction, modelAction.kind != .startFocus {
            return .notRequested
        }
        let normalizedQuestion = normalize(question)
        let duration = detectedDuration(in: normalizedQuestion)
            ?? modelAction?.durationMinutes
            ?? 25

        let pendingTasks = tasks.filter {
            !$0.isCompleted && !TaskDependencyResolver.isBlocked($0, in: tasks)
        }
        let taskMatches = rankedMatches(
            query: normalizedQuestion,
            candidates: pendingTasks.map { ($0.id, $0.title) }
        )
        let activeSubjects = subjects.filter { !$0.isArchived }
        let subjectMatches = rankedMatches(
            query: normalizedQuestion,
            candidates: activeSubjects.map { ($0.id, $0.name) }
        )

        let mentionsKnownTarget = (taskMatches.first?.score ?? 0) >= 0.72
            || (subjectMatches.first?.score ?? 0) >= 0.72
        let requested = modelAction?.kind == .startFocus
            || looksLikeFocusRequest(normalizedQuestion, mentionsKnownTarget: mentionsKnownTarget)
        guard requested else { return .notRequested }

        if let ambiguity = ambiguousTopMatch(in: taskMatches, minimumScore: 0.82) {
            return .needsClarification(
                message: "Encontré más de un pendiente que coincide: \(joinedOptions(ambiguity)). ¿Con cuál querés iniciar la sesión?"
            )
        }

        if let directTaskMatch = taskMatches.first,
           directTaskMatch.score >= 0.82,
           let task = pendingTasks.first(where: { $0.id == directTaskMatch.id })
        {
            return resolved(task: task, duration: duration)
        }

        if let ambiguity = ambiguousTopMatch(in: subjectMatches, minimumScore: 0.72) {
            return .needsClarification(
                message: "Encontré más de una materia parecida: \(joinedOptions(ambiguity)). ¿A cuál te referís?"
            )
        }

        if let subjectMatch = subjectMatches.first,
           subjectMatch.score >= 0.72,
           let subject = activeSubjects.first(where: { $0.id == subjectMatch.id })
        {
            let subjectTasks = pendingTasks.filter { $0.academicSubjectID == subject.id }
            guard let task = preferredTask(from: subjectTasks, recommendations: recommendations) else {
                return .needsClarification(
                    message: "Entendí que querés dedicar \(duration) minutos a \(subject.name), pero no encontré pendientes disponibles de esa materia."
                )
            }
            return resolved(task: task, duration: duration, subjectName: subject.name)
        }

        if let modelAction,
           modelAction.kind == .startFocus,
           let taskID = modelAction.taskID,
           let task = pendingTasks.first(where: { $0.id == taskID })
        {
            return resolved(task: task, duration: duration)
        }

        guard let task = preferredTask(from: pendingTasks, recommendations: recommendations) else {
            return .needsClarification(message: "No encontré un pendiente disponible para iniciar la sesión.")
        }
        return resolved(task: task, duration: duration)
    }

    private static func resolved(
        task: LumaTask,
        duration: Int,
        subjectName: String? = nil
    ) -> LumaFocusIntentResolution {
        let safeDuration = min(120, max(10, duration))
        let message: String
        if let subjectName {
            message = "Entendí que querés dedicar \(safeDuration) minutos a \(subjectName). Te propongo avanzar con “\(task.title)”, que es la opción más conveniente disponible."
        } else {
            message = "Entendí que querés hacer una sesión de \(safeDuration) minutos con “\(task.title)”."
        }
        return .resolved(
            message: message,
            action: LumaChatSuggestedAction(
                kind: .startFocus,
                label: "Iniciar \(safeDuration) min",
                taskID: task.id,
                durationMinutes: safeDuration
            )
        )
    }

    private static func preferredTask(
        from candidates: [LumaTask],
        recommendations: [PlanRecommendation]
    ) -> LumaTask? {
        guard !candidates.isEmpty else { return nil }
        let candidateIDs = Set(candidates.map(\.id))
        if let recommended = recommendations.first(where: { candidateIDs.contains($0.task.id) }) {
            return recommended.task
        }
        return candidates.sorted { left, right in
            switch (left.deadline, right.deadline) {
            case let (leftDate?, rightDate?):
                if leftDate != rightDate { return leftDate < rightDate }
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): break
            }
            if left.postponementCount != right.postponementCount {
                return left.postponementCount > right.postponementCount
            }
            return left.createdAt < right.createdAt
        }.first
    }

    private static func looksLikeFocusRequest(
        _ normalizedQuestion: String,
        mentionsKnownTarget: Bool
    ) -> Bool {
        let completionSignals = ["complete", "completado", "termine", "finalice", "marcar como hecho"]
        if completionSignals.contains(where: normalizedQuestion.contains) { return false }
        let strongSignals = [
            "focus", "pomodoro", "sesion", "concentr", "estudi", "repas", "practic",
            "trabaj", "ponerme",
        ]
        if strongSignals.contains(where: normalizedQuestion.contains) { return true }
        let weakSignals = ["avanz", "dedic", "inici", "empez", "arranc", "hagamos", "hacer"]
        if weakSignals.contains(where: normalizedQuestion.contains),
           mentionsKnownTarget || detectedDuration(in: normalizedQuestion) != nil
        {
            return true
        }
        return mentionsKnownTarget && detectedDuration(in: normalizedQuestion) != nil
    }

    private static func detectedDuration(in normalizedQuestion: String) -> Int? {
        if normalizedQuestion.contains("hora y media") || normalizedQuestion.contains("una hora y media") {
            return 90
        }
        if normalizedQuestion.contains("media hora") { return 30 }

        if let value = firstNumber(
            in: normalizedQuestion,
            pattern: #"\b(\d{1,3})\s*(?:min|minuto|minutos)\b"#
        ) {
            return min(120, max(10, value))
        }
        if let hours = firstNumber(
            in: normalizedQuestion,
            pattern: #"\b(\d{1,2})\s*(?:h|hora|horas)\b"#
        ) {
            return min(120, max(10, hours * 60))
        }
        if normalizedQuestion.range(of: #"\buna\s+hora\b"#, options: .regularExpression) != nil {
            return 60
        }
        return nil
    }

    private static func firstNumber(in text: String, pattern: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[range])
    }

    private struct RankedMatch {
        let id: UUID
        let title: String
        let score: Double
    }

    private static func rankedMatches(
        query: String,
        candidates: [(id: UUID, title: String)]
    ) -> [RankedMatch] {
        candidates
            .map { RankedMatch(id: $0.id, title: $0.title, score: matchScore(query: query, candidate: $0.title)) }
            .filter { $0.score > 0 }
            .sorted {
                if $0.score == $1.score { return $0.title.count > $1.title.count }
                return $0.score > $1.score
            }
    }

    private static func ambiguousTopMatch(
        in matches: [RankedMatch],
        minimumScore: Double
    ) -> [RankedMatch]? {
        guard let first = matches.first,
              first.score >= minimumScore
        else { return nil }
        let closeMatches = matches.filter {
            $0.score >= minimumScore && first.score - $0.score < 0.06
        }
        return closeMatches.count > 1 ? Array(closeMatches.prefix(3)) : nil
    }

    private static func joinedOptions(_ matches: [RankedMatch]) -> String {
        matches.map { "“\($0.title)”" }.joined(separator: ", ")
    }

    private static func matchScore(query: String, candidate: String) -> Double {
        let normalizedCandidate = normalize(candidate)
        guard normalizedCandidate.count >= 3 else { return 0 }
        if " \(query) ".contains(" \(normalizedCandidate) ") { return 1 }

        let queryTokens = meaningfulTokens(query)
        let candidateTokens = meaningfulTokens(normalizedCandidate)
        guard !queryTokens.isEmpty, !candidateTokens.isEmpty else { return 0 }

        var matched = 0.0
        for candidateToken in candidateTokens {
            let tokenScore = queryTokens.map { queryToken in
                tokenSimilarity(queryToken, candidateToken)
            }.max() ?? 0
            matched += tokenScore
        }
        return matched / Double(candidateTokens.count)
    }

    private static func tokenSimilarity(_ left: String, _ right: String) -> Double {
        if left == right { return 1 }
        if min(left.count, right.count) >= 3,
           left.hasPrefix(right) || right.hasPrefix(left)
        {
            return 0.82
        }
        guard left.count >= 4, right.count >= 4 else { return 0 }
        let distance = editDistance(left, right)
        let longest = max(left.count, right.count)
        let similarity = 1 - (Double(distance) / Double(longest))
        return similarity >= 0.78 ? similarity : 0
    }

    private static func meaningfulTokens(_ text: String) -> [String] {
        let ignored: Set<String> = [
            "a", "al", "con", "de", "del", "el", "en", "la", "las", "lo", "los",
            "me", "mi", "para", "por", "que", "quiero", "un", "una", "y",
        ]
        return text.split(separator: " ")
            .map(String.init)
            .filter { !ignored.contains($0) && ($0.count >= 3 || Int($0) != nil) }
    }

    private static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "es_AR")
        )
        let cleaned = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return cleaned.split(separator: " ").joined(separator: " ")
    }

    private static func editDistance(_ left: String, _ right: String) -> Int {
        let lhs = Array(left)
        let rhs = Array(right)
        var previous = Array(0 ... rhs.count)
        for (leftIndex, leftCharacter) in lhs.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(rhs.count + 1)
            for (rightIndex, rightCharacter) in rhs.enumerated() {
                current.append(min(
                    min(current[rightIndex] + 1, previous[rightIndex + 1] + 1),
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
