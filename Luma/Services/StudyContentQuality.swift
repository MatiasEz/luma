import Foundation

enum StudyContentQuality {
    static func cleanedTopics(_ topics: [StudyTopic], allowedPages: Set<Int>) -> [StudyTopic] {
        var seen = Set<String>()
        return topics.compactMap { original in
            var topic = original
            topic.title = topic.title.trimmingCharacters(in: .whitespacesAndNewlines)
            topic.summary = topic.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            topic.keyPoints = topic.keyPoints
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { isUsefulText($0) && $0.count >= 18 }
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
            topic.keyPoints = Array(topic.keyPoints.prefix(6))
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
        let letterCount = value.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return isUsefulText(title)
            && title.count <= 140
            && value.split(separator: " ").count >= 2
            && letterCount >= 10
            && !genericPrefixes.contains(where: value.hasPrefix)
            && !rubricPhrases.contains(where: value.contains)
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
