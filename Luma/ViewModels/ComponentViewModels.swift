import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class DraggableAgendaRowViewModel {
    var dragOffset: CGFloat = 0

    func finishDrag(translation: CGFloat, currentStart: Int) -> Int? {
        let stepCount = Int((translation / 26).rounded())
        dragOffset = 0
        guard stepCount != 0 else { return nil }
        return currentStart + stepCount * 15
    }
}

@MainActor
@Observable
final class PriorityCardViewModel {
    var editingTask = false
}

@MainActor
@Observable
final class SubjectEditorViewModel {
    var name: String
    var colorHex: String
    var syllabusRaw: String
    var syllabusTopics: [StudyTopic]
    var syllabusSourceFileName: String
    var syllabusPageCount: Int
    var meetings: [ClassMeetingDraft]
    var isPDFImporterPresented = false
    var isProcessingPDF = false
    var processingProgress = 0.0
    var processingStage = ""
    var pdfMessage = ""
    @ObservationIgnored private var extractedDocument: ExtractedStudyDocument?

    init(subject: AcademicSubject?, meetings: [SubjectClassMeeting] = []) {
        name = subject?.name ?? ""
        colorHex = subject?.colorHex ?? "#59639A"
        let initialTopics = subject?.syllabusStudyTopics ?? []
        syllabusTopics = initialTopics
        syllabusRaw = initialTopics.map(\.title).joined(separator: "\n")
        syllabusSourceFileName = subject?.syllabusSourceFileName ?? ""
        syllabusPageCount = subject?.syllabusPageCount ?? 0
        self.meetings = meetings.map {
            ClassMeetingDraft(
                id: $0.id,
                weekday: $0.weekday,
                startMinuteOfDay: $0.startMinuteOfDay,
                endMinuteOfDay: $0.endMinuteOfDay,
                location: $0.location
            )
        }.sorted {
            $0.weekday == $1.weekday
                ? $0.startMinuteOfDay < $1.startMinuteOfDay
                : $0.weekday < $1.weekday
        }
    }

    var hasSyllabusPDF: Bool {
        !syllabusSourceFileName.isEmpty
    }

    var canAnalyzeImportedPDF: Bool {
        extractedDocument != nil
    }

    func importPDF(
        _ result: Result<[URL], Error>,
        using aiEngine: LocalAIEngine
    ) async {
        do {
            guard let url = try result.get().first else { return }
            isProcessingPDF = true
            processingProgress = 0
            processingStage = "Preparando el temario"
            pdfMessage = ""

            let document = try await PDFStudyExtractor().extract(from: url) { fraction, stage in
                self.processingProgress = fraction * 0.28
                self.processingStage = stage
            }
            extractedDocument = document
            syllabusTopics = []
            syllabusRaw = ""
            syllabusSourceFileName = document.fileName
            syllabusPageCount = document.pageCount

            #if DEBUG
            let readablePages = document.pages.map(\.pageNumber).map(String.init).joined(separator: ",")
            print("📄 [TEMARIO-MATERIA] PDF extraído | archivo=\(document.fileName) | páginas=\(document.pageCount) | páginas con texto=\(readablePages)")
            #endif

            guard aiEngine.isInstalled || aiEngine.isStudyModelInstalled else {
                isProcessingPDF = false
                processingStage = ""
                pdfMessage = "El PDF está listo. Prepará la IA local para detectar sus temas."
                #if DEBUG
                print("⏸️ [TEMARIO-MATERIA] Análisis pendiente | modelo local no instalado")
                #endif
                return
            }

            await analyzeImportedPDF(using: aiEngine)
        } catch {
            #if DEBUG
            print("❌ [TEMARIO-MATERIA] No se pudo importar | \(error.localizedDescription)")
            #endif
            isProcessingPDF = false
            processingStage = ""
            pdfMessage = "No pude leer el PDF: \(error.localizedDescription)"
        }
    }

    func analyzeImportedPDF(using aiEngine: LocalAIEngine) async {
        guard let document = extractedDocument else { return }
        guard aiEngine.isInstalled || aiEngine.isStudyModelInstalled else {
            pdfMessage = "Primero prepará la IA local para analizar el temario."
            return
        }

        do {
            #if DEBUG
            print("▶️ [TEMARIO-MATERIA] Analizando \(document.fileName) para la materia \(trimmedName.isEmpty ? "sin nombre todavía" : trimmedName)")
            #endif
            isProcessingPDF = true
            processingProgress = max(processingProgress, 0.28)
            processingStage = "Reconstruyendo el índice y los contenidos"
            pdfMessage = ""
            let referenceDate = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now
            let topics = try await aiEngine.createExamStudyTopics(
                for: document,
                examDate: referenceDate
            ) { fraction, stage in
                self.processingProgress = 0.28 + fraction * 0.72
                self.processingStage = stage
            }

            syllabusTopics = topics
            syllabusRaw = topics.map(\.title).joined(separator: "\n")
            syllabusSourceFileName = document.fileName
            syllabusPageCount = document.pageCount
            processingProgress = 1
            processingStage = ""
            pdfMessage = "Organicé \(topics.count) unidades o temas. Podés revisarlos antes de guardar la materia."
            #if DEBUG
            print("💾 [TEMARIO-MATERIA] Borrador listo | materia=\(trimmedName) | temas=\(topics.count)")
            #endif
        } catch {
            #if DEBUG
            print("❌ [TEMARIO-MATERIA] Falló el análisis | \(error.localizedDescription)")
            #endif
            processingStage = ""
            pdfMessage = "No pude analizar el temario: \(error.localizedDescription)"
        }
        isProcessingPDF = false
    }

    func resolvedSyllabusTopics() -> [StudyTopic] {
        let titles = syllabusRaw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var existingByTitle: [String: StudyTopic] = [:]
        for topic in syllabusTopics {
            existingByTitle[normalized(topic.title)] = topic
        }
        return titles.map { title in
            if var existing = existingByTitle[normalized(title)] {
                existing.title = title
                return existing
            }
            return StudyTopic(
                title: title,
                summary: "Tema incluido en el temario de \(trimmedName).",
                keyPoints: [],
                sourcePages: [],
                importance: 2,
                suggestedMinutes: 35,
                taskID: nil
            )
        }
    }

    var syllabusStructureSummary: String {
        let topics = resolvedSyllabusTopics()
        let subtopicCount = topics.reduce(0) { $0 + $1.syllabusSubtopics.count }
        let unitsLabel = topics.count == 1 ? "1 unidad" : "\(topics.count) unidades"
        guard subtopicCount > 0 else { return unitsLabel }
        let subtopicsLabel = subtopicCount == 1 ? "1 subtema" : "\(subtopicCount) subtemas"
        return "\(unitsLabel) · \(subtopicsLabel)"
    }

    func clearSyllabus() {
        syllabusRaw = ""
        syllabusTopics = []
        syllabusSourceFileName = ""
        syllabusPageCount = 0
        extractedDocument = nil
        pdfMessage = ""
        processingProgress = 0
        processingStage = ""
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hasDuplicateName(subject: AcademicSubject?, allSubjects: [AcademicSubject]) -> Bool {
        allSubjects.contains {
            !$0.isArchived
                && $0.id != subject?.id
                && $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }
    }

    func canSave(subject: AcademicSubject?, allSubjects: [AcademicSubject]) -> Bool {
        !trimmedName.isEmpty
            && !hasDuplicateName(subject: subject, allSubjects: allSubjects)
            && !hasInvalidMeeting
            && !isProcessingPDF
    }

    var hasInvalidMeeting: Bool {
        meetings.contains { $0.endMinuteOfDay <= $0.startMinuteOfDay }
    }

    func addMeeting() {
        var draft = ClassMeetingDraft()
        if let previous = meetings.last {
            draft.weekday = previous.weekday == 7 ? 2 : previous.weekday + 1
            draft.startMinuteOfDay = previous.startMinuteOfDay
            draft.endMinuteOfDay = previous.endMinuteOfDay
        }
        meetings.append(draft)
    }

    func removeMeeting(id: UUID) {
        meetings.removeAll { $0.id == id }
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ClassMeetingDraft: Identifiable, Equatable {
    var id = UUID()
    var weekday = 2
    var startMinuteOfDay = 9 * 60
    var endMinuteOfDay = 11 * 60
    var location = ""
}
