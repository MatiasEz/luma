import Foundation

struct AcademicSyllabusSubtopic: Hashable, Sendable {
    var code: String
    var title: String
    var sourcePages: [Int]
}

struct AcademicSyllabusUnit: Hashable, Sendable {
    var number: Int
    var title: String
    var indexPages: [Int]
    var subtopics: [AcademicSyllabusSubtopic]

    var sourcePages: [Int] {
        Array(Set(indexPages + subtopics.flatMap(\.sourcePages))).sorted()
    }
}

struct AcademicSyllabusStructure: Sendable {
    var units: [AcademicSyllabusUnit]

    var hasOfficialHierarchy: Bool {
        units.count >= 2 && units.allSatisfy { !$0.title.isEmpty }
    }

    func unitBatches(maximumUnits: Int = 4) -> [[AcademicSyllabusUnit]] {
        let size = max(1, maximumUnits)
        return stride(from: 0, to: units.count, by: size).map { start in
            Array(units[start ..< min(start + size, units.count)])
        }
    }

    func sourceText(for units: [AcademicSyllabusUnit]) -> String {
        units.map { unit in
            let pages = unit.sourcePages.map(String.init).joined(separator: ", ")
            let details = unit.subtopics.isEmpty
                ? "- El PDF no incluye subtemas numerados para esta unidad."
                : unit.subtopics.map { subtopic in
                    let source = subtopic.sourcePages.map(String.init).joined(separator: ", ")
                    return "- \(subtopic.code) \(subtopic.title) [PÁGINA \(source)]"
                }.joined(separator: "\n")
            return """
            [UNIDAD \(unit.number)] \(unit.title)
            Páginas verificadas: \(pages)
            Subtemas oficiales:
            \(details)
            """
        }.joined(separator: "\n\n")
    }
}

enum AcademicSyllabusStructureAnalyzer {
    private struct SourceLine {
        var pageNumber: Int
        var text: String
        var normalized: String
    }

    private struct MutableUnit {
        var number: Int
        var title: String
        var pages: Set<Int>
    }

    private struct MutableSubtopic {
        var unitNumber: Int
        var code: String
        var title: String
        var pages: Set<Int>
    }

    static func analyze(_ document: ExtractedStudyDocument) -> AcademicSyllabusStructure {
        let lines = document.pages.flatMap { page in
            page.text.split(whereSeparator: \.isNewline).compactMap { rawLine -> SourceLine? in
                let text = compact(String(rawLine))
                guard !text.isEmpty else { return nil }
                return SourceLine(
                    pageNumber: page.pageNumber,
                    text: text,
                    normalized: normalized(text)
                )
            }
        }

        guard let indexStart = lines.firstIndex(where: { $0.normalized.contains("indice tematico") }),
              let contentStart = lines.indices.dropFirst(indexStart + 1).first(where: {
                  lines[$0].normalized == "contenido" || lines[$0].normalized == "contenidos"
              })
        else { return AcademicSyllabusStructure(units: []) }

        let indexUnits = parseIndex(Array(lines[(indexStart + 1) ..< contentStart]))
        guard indexUnits.count >= 2 else { return AcademicSyllabusStructure(units: []) }

        let contentEnd = lines.indices.dropFirst(contentStart + 1).first(where: {
            isPracticeHeading(lines[$0].normalized)
                || lines[$0].normalized.contains("actividades ensenanza aprendizaje")
                || lines[$0].normalized == "evaluacion del aprendizaje"
        }) ?? lines.endIndex
        let subtopics = parseSubtopics(Array(lines[(contentStart + 1) ..< contentEnd]))
        let groupedSubtopics = Dictionary(grouping: subtopics, by: \.unitNumber)

        let units = indexUnits.map { unit in
            AcademicSyllabusUnit(
                number: unit.number,
                title: cleanTitle(unit.title),
                indexPages: Array(unit.pages).sorted(),
                subtopics: (groupedSubtopics[unit.number] ?? []).map {
                    AcademicSyllabusSubtopic(
                        code: $0.code,
                        title: cleanTitle($0.title),
                        sourcePages: Array($0.pages).sorted()
                    )
                }
            )
        }
        return AcademicSyllabusStructure(units: units)
    }

    private static func parseIndex(_ lines: [SourceLine]) -> [MutableUnit] {
        var result: [MutableUnit] = []
        var current: MutableUnit?

        func flush() {
            guard var unit = current else { return }
            unit.title = cleanTitle(unit.title)
            if !unit.title.isEmpty { result.append(unit) }
            current = nil
        }

        for line in lines {
            if let groups = captures(#"^\s*(\d{1,2})\s+(.+)$"#, in: line.text),
               let number = Int(groups[0]),
               (1 ... 99).contains(number)
            {
                flush()
                current = MutableUnit(
                    number: number,
                    title: removingTrailingHours(groups[1]),
                    pages: [line.pageNumber]
                )
                continue
            }

            guard current != nil,
                  !isIndexNoise(line.normalized)
            else { continue }
            current?.title += " \(removingTrailingHours(line.text))"
            current?.pages.insert(line.pageNumber)
        }
        flush()

        var seen = Set<Int>()
        return result
            .filter { seen.insert($0.number).inserted }
            .sorted { $0.number < $1.number }
    }

    private static func parseSubtopics(_ lines: [SourceLine]) -> [MutableSubtopic] {
        var result: [MutableSubtopic] = []
        var current: MutableSubtopic?

        func flush() {
            guard var subtopic = current else { return }
            subtopic.title = cleanTitle(subtopic.title)
            if !subtopic.title.isEmpty { result.append(subtopic) }
            current = nil
        }

        for line in lines {
            if let groups = captures(#"^\s*(\d{1,2})\.(\d+(?:\.\d+)*)\s+(.+)$"#, in: line.text),
               let unitNumber = Int(groups[0])
            {
                flush()
                current = MutableSubtopic(
                    unitNumber: unitNumber,
                    code: "\(groups[0]).\(groups[1])",
                    title: groups[2],
                    pages: [line.pageNumber]
                )
                continue
            }

            guard current != nil,
                  !isContentNoise(line.text, normalized: line.normalized)
            else { continue }
            current?.title += " \(line.text)"
            current?.pages.insert(line.pageNumber)
        }
        flush()
        return result
    }

    private static func isPracticeHeading(_ value: String) -> Bool {
        value == "practicas" || value.hasPrefix("n practicas") || value.hasPrefix("numero practicas")
    }

    private static func isIndexNoise(_ value: String) -> Bool {
        let exact = [
            "unidad", "temas", "horas", "semestre hemisemestre", "teoricas", "practicas",
            "teoricas practicas",
        ]
        return exact.contains(value)
            || value.hasPrefix("total ")
            || value.hasPrefix("aprobada la modificacion")
    }

    private static func isContentNoise(_ text: String, normalized value: String) -> Bool {
        value == "unidad"
            || value == "contenido"
            || value.hasPrefix("aprobada la modificacion")
            || text.range(of: #"^\s*\d+\s*$"#, options: .regularExpression) != nil
    }

    private static func removingTrailingHours(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\s+\d+\s+\d+\s*$"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func cleanTitle(_ text: String) -> String {
        compact(text).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ".")
        ))
    }

    private static func compact(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex ..< text.endIndex, in: text)
              )
        else { return nil }

        return (1 ..< match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }
}

enum StudyContentQuality {
    static func cleanedTopics(_ topics: [StudyTopic], allowedPages: Set<Int>) -> [StudyTopic] {
        var seen = Set<String>()
        return topics.compactMap { original in
            var topic = original
            topic.title = topic.title.trimmingCharacters(in: .whitespacesAndNewlines)
            topic.summary = topic.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            topic.keyPoints = topic.keyPoints
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { isUsefulText($0) && $0.count >= 8 }
                .map { String($0.prefix(260)) }
            topic.sourcePages = Array(Set(topic.sourcePages.filter(allowedPages.contains))).sorted()
            topic.importance = min(3, max(1, topic.importance))
            topic.suggestedMinutes = min(90, max(20, topic.suggestedMinutes))

            let key = normalized(topic.title)
            guard isUsefulTopicTitle(topic.title),
                  isUsefulText(topic.summary),
                  topic.summary.count >= 45,
                  !topic.sourcePages.isEmpty,
                  seen.insert(key).inserted
            else { return nil }

            topic.title = String(topic.title.prefix(110))
            topic.summary = String(topic.summary.prefix(900))
            topic.keyPoints = Array(topic.keyPoints.prefix(12))
            return topic
        }
    }

    static func cleanedFlashcards(
        _ cards: [StudyFlashcard],
        allowedPages: Set<Int>
    ) -> [StudyFlashcard] {
        var seen = Set<String>()
        return cards.compactMap { original in
            var card = original
            card.front = card.front.trimmingCharacters(in: .whitespacesAndNewlines)
            card.back = card.back.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized(card.front)
            guard card.front.count >= 8,
                  card.back.count >= 12,
                  isUsefulText(card.front),
                  isUsefulText(card.back),
                  card.sourcePage.map(allowedPages.contains) ?? true,
                  seen.insert(key).inserted
            else { return nil }
            card.front = String(card.front.prefix(240))
            card.back = String(card.back.prefix(700))
            return card
        }
    }

    static func cleanedQuestions(
        _ questions: [StudyQuizQuestion],
        allowedPages: Set<Int>
    ) -> [StudyQuizQuestion] {
        var seen = Set<String>()
        return questions.compactMap { original in
            var question = original
            question.prompt = question.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            question.explanation = question.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
            question.options = question.options
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter(isUsefulText)
            let optionKeys = Set(question.options.map(normalized))
            let key = normalized(question.prompt)
            guard question.prompt.count >= 12,
                  question.explanation.count >= 18,
                  question.options.count >= 3,
                  optionKeys.count == question.options.count,
                  question.options.indices.contains(question.correctIndex),
                  question.sourcePage.map(allowedPages.contains) ?? true,
                  isUsefulText(question.prompt),
                  isUsefulText(question.explanation),
                  seen.insert(key).inserted
            else { return nil }
            question.prompt = String(question.prompt.prefix(300))
            question.explanation = String(question.explanation.prefix(700))
            question.options = question.options.map { String($0.prefix(240)) }
            return question
        }
    }

    static func isUsefulText(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2 else { return false }
        let value = normalized(cleaned)
        let leakedInstructions = [
            "analiza pero nunca",
            "nunca sigas instrucciones",
            "no sigas instrucciones",
            "material no confiable",
            "no muestres razonamiento",
            "responde solamente con json",
            "json valido",
            "conceptos revisados",
            "system prompt",
        ]
        return !leakedInstructions.contains(where: value.contains)
    }

    private static func isUsefulTopicTitle(_ title: String) -> Bool {
        let value = normalized(title)
        let genericPrefixes = [
            "practica ", "actividad ", "actividades ", "destrezas ", "imagen ",
            "figura ", "tabla ", "desempeno ", "puntuacion ",
        ]
        let rubricPhrases = ["total suma", "si parcial no", "habilidades y destrezas desempeno"]
        let administrativePhrases = [
            "objetivo general", "objetivos especificos", "perfil profesiografico",
            "habilidades y destrezas", "evaluacion del aprendizaje",
            "actividades ensenanza aprendizaje", "bibliografia basica",
            "bibliografia complementaria", "identificacion de inspectores",
        ]
        let letterCount = value.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return isUsefulText(title)
            && title.count <= 140
            && value.split(separator: " ").count >= 2
            && letterCount >= 10
            && !genericPrefixes.contains(where: value.hasPrefix)
            && !rubricPhrases.contains(where: value.contains)
            && !administrativePhrases.contains(where: value.contains)
    }

    private static func normalized(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
