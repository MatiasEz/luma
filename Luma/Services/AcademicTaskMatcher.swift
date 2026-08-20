import Foundation

struct AcademicTaskMatch {
    let subjectID: UUID
    let gradeItemID: UUID?
    let grade: Double?
    let subjectName: String
    let categoryName: String?
}

struct AcademicTaskMatcher {
    func match(
        text: String,
        subjects: [AcademicSubject],
        gradeItems: [SubjectGradeItem]
    ) -> AcademicTaskMatch? {
        let normalizedText = normalize(text)
        guard let subject = matchingSubject(in: normalizedText, subjects: subjects) else { return nil }

        let subjectItems = gradeItems.filter { $0.subjectID == subject.id && !$0.isArchived }
        let item = matchingItem(in: normalizedText, items: subjectItems)

        return AcademicTaskMatch(
            subjectID: subject.id,
            gradeItemID: item?.id,
            grade: item == nil ? nil : detectedGrade(in: normalizedText),
            subjectName: subject.name,
            categoryName: item?.title
        )
    }

    private func matchingSubject(
        in normalizedText: String,
        subjects: [AcademicSubject]
    ) -> AcademicSubject? {
        let haystack = " \(normalizedText) "
        let directMatches = subjects
            .filter { !$0.isArchived }
            .filter { subject in
                let name = normalize(subject.name)
                return !name.isEmpty && haystack.contains(" \(name) ")
            }
            .sorted { normalize($0.name).count > normalize($1.name).count }

        if let direct = directMatches.first { return direct }

        guard let markerRange = normalizedText.range(of: " materia ")
                ?? normalizedText.range(of: "materia ")
        else { return nil }

        let mentionedName = normalizedText[markerRange.upperBound...]
            .split(separator: " ")
            .prefix(4)
            .joined(separator: " ")

        let prefixMatches = subjects.filter { subject in
            guard !subject.isArchived else { return false }
            let name = normalize(subject.name)
            return name.count >= 3
                && (mentionedName.hasPrefix(name) || name.hasPrefix(mentionedName))
        }
        return prefixMatches.count == 1 ? prefixMatches[0] : nil
    }

    private func matchingItem(
        in normalizedText: String,
        items: [SubjectGradeItem]
    ) -> SubjectGradeItem? {
        if let direct = items.first(where: {
            let title = normalize($0.title)
            return !title.isEmpty && " \(normalizedText) ".contains(" \(title) ")
        }) {
            return direct
        }

        let groups: [(signals: [String], categoryWords: [String])] = [
            (["examen", "parcial", "final"], ["examen", "parcial", "final"]),
            (["tarea", "tp", "trabajo practico", "entrega"], ["tarea", "trabajo", "practico", "entrega"]),
            (["asistencia", "asistir", "clase"], ["asistencia", "clase"]),
            (["proyecto"], ["proyecto"]),
            (["quiz", "cuestionario"], ["quiz", "cuestionario"]),
            (["presentacion", "exposicion"], ["presentacion", "exposicion"]),
        ]

        for group in groups where group.signals.contains(where: normalizedText.contains) {
            if let item = items.first(where: { item in
                let title = normalize(item.title)
                return group.categoryWords.contains(where: title.contains)
            }) {
                return item
            }
        }
        return nil
    }

    private func detectedGrade(in normalizedText: String) -> Double? {
        let pattern = #"\bnota\s*(?:(?:de)\s*)?[:=]?\s*(10(?:[\.,]\d+)?|[0-9](?:[\.,]\d+)?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: normalizedText,
                  range: NSRange(normalizedText.startIndex..., in: normalizedText)
              ),
              let range = Range(match.range(at: 1), in: normalizedText),
              let value = Double(normalizedText[range].replacingOccurrences(of: ",", with: ".")),
              (0 ... 10).contains(value)
        else { return nil }
        return value
    }

    private func normalize(_ text: String) -> String {
        let cleaned = String(text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " })
        return cleaned.split(separator: " ").joined(separator: " ")
    }
}
