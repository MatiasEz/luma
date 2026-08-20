import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct StudyModeView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalAIEngine.self) private var aiEngine
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StudyGuide.importedAt, order: .reverse) private var guides: [StudyGuide]
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]

    @State private var selectedGuideID: UUID?
    @State private var examDate = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
    @State private var isFileImporterPresented = false
    @State private var isProcessing = false
    @State private var processingProgress = 0.0
    @State private var processingStage = ""
    @State private var message = ""
    @State private var selectedTab = StudyDetailTab.plan
    @State private var cardIndex = 0
    @State private var isCardRevealed = false
    @State private var questionIndex = 0
    @State private var selectedAnswer: Int?

    private var selectedGuide: StudyGuide? {
        guides.first { $0.id == selectedGuideID } ?? guides.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 18)

            if aiEngine.state.isDownloading {
                AIDownloadProgressView()
                    .lumaCard(padding: 14)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 16)
            } else if isProcessing {
                processingBanner
                    .padding(.horizontal, 30)
                    .padding(.bottom, 16)
            } else if !message.isEmpty {
                statusBanner
                    .padding(.horizontal, 30)
                    .padding(.bottom, 16)
            }

            if guides.isEmpty, !isProcessing {
                emptyState
                    .padding(.horizontal, 30)
                    .padding(.bottom, 30)
            } else {
                studyWorkspace
            }
        }
        .background(LumaBackground())
        .navigationTitle("Modo Estudio")
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            importPDF(result)
        }
        .onAppear {
            if selectedGuideID == nil { selectedGuideID = guides.first?.id }
        }
        .onChange(of: selectedGuideID) { _, _ in
            resetPracticeState()
        }
        .onChange(of: guides.count) { _, _ in
            if selectedGuide == nil { selectedGuideID = guides.first?.id }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MODO ESTUDIO")
                    .font(.caption2.weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(LumaPalette.lavender)
                Text("Convertí un PDF en un plan posible")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                Text("Luma encuentra los temas, arma repasos y los conecta con tu agenda.")
                    .font(.subheadline)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }

            Spacer(minLength: 20)

            VStack(alignment: .leading, spacing: 5) {
                Text("Fecha del examen")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.secondaryInk)
                DatePicker(
                    "Fecha del examen",
                    selection: $examDate,
                    in: Calendar.current.startOfDay(for: .now)...,
                    displayedComponents: .date
                )
                .labelsHidden()
            }

            if aiEngine.isStudyModelInstalled {
                Button {
                    isFileImporterPresented = true
                } label: {
                    Label("Importar PDF", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(LumaPalette.indigo)
                .disabled(isProcessing || aiEngine.state.isBusy)
            } else {
                Button {
                    Task { await aiEngine.installStudyModel() }
                } label: {
                    Label("Preparar análisis avanzado", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(LumaPalette.indigo)
                .disabled(aiEngine.state.isBusy)
            }
        }
    }

    private var processingBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "books.vertical.fill")
                .font(.title3)
                .foregroundStyle(LumaPalette.indigo)
                .frame(width: 42, height: 42)
                .background(LumaPalette.indigo.opacity(0.11), in: Circle())
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(processingStage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                    Spacer()
                    Text(processingProgress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                ProgressView(value: processingProgress)
                    .tint(LumaPalette.indigo)
            }
        }
        .lumaCard(padding: 14)
    }

    private var statusBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: message.hasPrefix("No pude") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(message)
                .font(.subheadline)
            Spacer()
            Button("Cerrar") { message = "" }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(message.hasPrefix("No pude") ? LumaPalette.terracotta : LumaPalette.sage)
        .lumaCard(padding: 12)
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(LumaPalette.lavender.opacity(0.12))
                    .frame(width: 150, height: 150)
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(LumaPalette.indigo)
            }
            VStack(spacing: 9) {
                Text(aiEngine.isStudyModelInstalled ? "Subí tu primer material" : "Prepará el análisis de estudio")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                Text(aiEngine.isStudyModelInstalled
                     ? "Elegí un PDF y la fecha del examen. Luma organizará el contenido en temas y sesiones."
                     : "Prepará el análisis completo para conservar términos técnicos y producir contenido académico más útil. Descarga: 4,3 GB.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .frame(maxWidth: 520)
            }
            HStack(spacing: 24) {
                benefit("Temas y resúmenes", symbol: "list.bullet.rectangle")
                benefit("Tarjetas de repaso", symbol: "rectangle.on.rectangle")
                benefit("Sesiones en tu agenda", symbol: "calendar.badge.plus")
            }
            if aiEngine.isStudyModelInstalled {
                Button("Elegir PDF") { isFileImporterPresented = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(LumaPalette.indigo)
            } else {
                Button {
                    Task { await aiEngine.installStudyModel() }
                } label: {
                    Label("Preparar análisis de estudio", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(LumaPalette.indigo)
                .disabled(aiEngine.state.isBusy)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .lumaCard()
    }

    private func benefit(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(LumaPalette.secondaryInk)
    }

    private var studyWorkspace: some View {
        HStack(spacing: 0) {
            guideList
                .frame(width: 248)
                .background(Color.white.opacity(0.24))
            Divider().opacity(0.45)
            if let selectedGuide {
                guideDetail(selectedGuide)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(
                    symbol: "books.vertical",
                    title: "Elegí un material",
                    message: "Tus sistemas de estudio aparecen en esta columna."
                )
                .padding(30)
            }
        }
    }

    private var guideList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("MATERIALES")
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(LumaPalette.secondaryInk)
                    Spacer()
                    Text("\(guides.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                .padding(.bottom, 4)

                ForEach(guides) { guide in
                    Button {
                        selectedGuideID = guide.id
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(guide.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(LumaPalette.ink)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                            Text("\(guide.pageCount) págs. · Examen \(guide.examDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2)
                                .foregroundStyle(LumaPalette.secondaryInk)
                            if guide.plannedTopicCount > 0 {
                                Label("\(guide.plannedTopicCount) sesiones creadas", systemImage: "checkmark.circle.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(LumaPalette.sage)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            selectedGuide?.id == guide.id
                                ? LumaPalette.indigo.opacity(0.13)
                                : Color.white.opacity(0.38),
                            in: RoundedRectangle(cornerRadius: 13)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 13)
                                .stroke(selectedGuide?.id == guide.id ? LumaPalette.indigo.opacity(0.28) : .clear)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
    }

    private func guideDetail(_ guide: StudyGuide) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                guideSummary(guide)

                Picker("Contenido", selection: $selectedTab) {
                    ForEach(StudyDetailTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)

                switch selectedTab {
                case .plan:
                    topicPlan(guide)
                case .cards:
                    flashcardPractice(guide)
                case .practice:
                    quizPractice(guide)
                }
            }
            .padding(26)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private func guideSummary(_ guide: StudyGuide) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(guide.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                    Text("\(guide.sourceFileName) · \(guide.pageCount) páginas")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("EXAMEN")
                        .font(.caption2.weight(.bold))
                        .tracking(1)
                        .foregroundStyle(LumaPalette.lavender)
                    Text(guide.examDate, format: .dateTime.day().month(.wide))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                }
            }
            Divider()
            Text(guide.overview)
                .font(.subheadline)
                .foregroundStyle(LumaPalette.secondaryInk)
                .lineSpacing(3)
            Divider()
            HStack(spacing: 12) {
                Label(
                    guide.generationVersion >= 2
                        ? "Análisis académico · calidad avanzada"
                        : "Análisis anterior · conviene regenerarlo",
                    systemImage: guide.generationVersion >= 2 ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
                )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(guide.generationVersion >= 2 ? LumaPalette.sage : LumaPalette.terracotta)
                Spacer()
                if aiEngine.isStudyModelInstalled {
                    Button {
                        regenerate(guide)
                    } label: {
                        Label("Regenerar con mejor calidad", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
                    .disabled(isProcessing || aiEngine.state.isBusy)
                } else {
                    Button {
                        Task { await aiEngine.installStudyModel() }
                    } label: {
                        Label("Preparar análisis avanzado", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
                    .disabled(aiEngine.state.isBusy)
                }
            }
        }
        .lumaCard()
    }

    private func topicPlan(_ guide: StudyGuide) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Plan sugerido")
                        .font(.headline)
                        .foregroundStyle(LumaPalette.ink)
                    Text("Cada tema se transforma en una tarea de universidad antes del examen.")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                Button {
                    addStudySessions(for: guide)
                } label: {
                    Label(
                        guide.plannedTopicCount == guide.topics.count ? "Sesiones agregadas" : "Agregar a mi agenda",
                        systemImage: guide.plannedTopicCount == guide.topics.count ? "checkmark.circle.fill" : "calendar.badge.plus"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(guide.plannedTopicCount == guide.topics.count ? LumaPalette.sage : LumaPalette.indigo)
            }

            ForEach(Array(guide.topics.enumerated()), id: \.element.id) { index, topic in
                topicCard(topic, number: index + 1)
            }
        }
    }

    private func topicCard(_ topic: StudyTopic, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(LumaPalette.indigo, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(topic.title)
                        .font(.headline)
                        .foregroundStyle(LumaPalette.ink)
                    HStack(spacing: 9) {
                        Label(topic.pageLabel, systemImage: "doc.text")
                        Label("\(topic.suggestedMinutes) min", systemImage: "clock")
                        Label(importanceLabel(topic.importance), systemImage: "flag.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                if let taskID = topic.taskID, tasks.contains(where: { $0.id == taskID && !$0.isCompleted }) {
                    Button {
                        appState.startFocus(for: taskID, durationMinutes: topic.suggestedMinutes)
                    } label: {
                        Label("Empezar", systemImage: "play.fill")
                    }
                    .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
                }
            }

            Text(topic.summary)
                .font(.subheadline)
                .foregroundStyle(LumaPalette.secondaryInk)

            if !topic.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(topic.keyPoints, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(LumaPalette.sage)
                                .frame(width: 5, height: 5)
                            Text(point)
                                .font(.caption)
                                .foregroundStyle(LumaPalette.secondaryInk)
                        }
                    }
                }
                .padding(.leading, 40)
            }
        }
        .lumaCard(padding: 16)
    }

    private func flashcardPractice(_ guide: StudyGuide) -> some View {
        let cards = guide.flashcards
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tarjetas de repaso")
                        .font(.headline)
                        .foregroundStyle(LumaPalette.ink)
                    Text(cards.isEmpty ? "No se generaron tarjetas para este material." : "Tarjeta \(safeCardIndex(for: cards) + 1) de \(cards.count)")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                Text("\(cards.filter(\.isMastered).count) aprendidas")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.sage)
            }

            if cards.isEmpty {
                EmptyStateView(symbol: "rectangle.on.rectangle", title: "Sin tarjetas", message: "Podés usar el plan por temas y las preguntas de práctica.")
            } else {
                let index = safeCardIndex(for: cards)
                let card = cards[index]
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isCardRevealed.toggle() }
                } label: {
                    VStack(spacing: 18) {
                        Text(isCardRevealed ? "RESPUESTA" : "PREGUNTA")
                            .font(.caption2.weight(.bold))
                            .tracking(1.2)
                            .foregroundStyle(isCardRevealed ? LumaPalette.sage : LumaPalette.lavender)
                        Text(isCardRevealed ? card.back : card.front)
                            .font(.title3.weight(.medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(LumaPalette.ink)
                            .lineSpacing(4)
                        Label(isCardRevealed ? "Tocá para volver" : "Tocá para revelar", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(LumaPalette.secondaryInk)
                    }
                    .padding(34)
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .background(
                        (isCardRevealed ? LumaPalette.sage : LumaPalette.lavender).opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 24)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 24)
                            .stroke((isCardRevealed ? LumaPalette.sage : LumaPalette.lavender).opacity(0.25))
                    }
                }
                .buttonStyle(.plain)

                HStack {
                    Button {
                        cardIndex = max(0, index - 1)
                        isCardRevealed = false
                    } label: {
                        Label("Anterior", systemImage: "chevron.left")
                    }
                    .buttonStyle(SoftButtonStyle(color: LumaPalette.secondaryInk))
                    .disabled(index == 0)

                    Spacer()

                    Button {
                        toggleMastered(cardID: card.id, in: guide)
                    } label: {
                        Label(card.isMastered ? "Aprendida" : "Marcar aprendida", systemImage: card.isMastered ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(SoftButtonStyle(color: LumaPalette.sage))

                    Button {
                        cardIndex = min(cards.count - 1, index + 1)
                        isCardRevealed = false
                    } label: {
                        Label("Siguiente", systemImage: "chevron.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
                    .disabled(index == cards.count - 1)
                }
            }
        }
    }

    private func quizPractice(_ guide: StudyGuide) -> some View {
        let questions = guide.questions
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Práctica rápida")
                        .font(.headline)
                        .foregroundStyle(LumaPalette.ink)
                    Text(questions.isEmpty ? "No se generaron preguntas." : "Pregunta \(safeQuestionIndex(for: questions) + 1) de \(questions.count)")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                if !questions.isEmpty, let page = questions[safeQuestionIndex(for: questions)].sourcePage {
                    Label("Pág. \(page)", systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
            }

            if questions.isEmpty {
                EmptyStateView(symbol: "questionmark.bubble", title: "Sin preguntas", message: "El resumen y las tarjetas siguen disponibles.")
            } else {
                let index = safeQuestionIndex(for: questions)
                let question = questions[index]
                VStack(alignment: .leading, spacing: 16) {
                    Text(question.prompt)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)

                    ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                        Button {
                            if selectedAnswer == nil { selectedAnswer = optionIndex }
                        } label: {
                            HStack(spacing: 12) {
                                Text(String(UnicodeScalar(65 + optionIndex)!))
                                    .font(.caption.weight(.bold))
                                    .frame(width: 27, height: 27)
                                    .foregroundStyle(answerColor(optionIndex, question: question))
                                    .background(answerColor(optionIndex, question: question).opacity(0.12), in: Circle())
                                Text(option)
                                    .font(.subheadline)
                                    .foregroundStyle(LumaPalette.ink)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                if selectedAnswer != nil, optionIndex == question.safeCorrectIndex {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(LumaPalette.sage)
                                } else if selectedAnswer == optionIndex {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(LumaPalette.terracotta)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(answerColor(optionIndex, question: question).opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }

                    if let selectedAnswer {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(selectedAnswer == question.safeCorrectIndex ? "Bien ahí" : "Casi. Revisemos la idea")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(selectedAnswer == question.safeCorrectIndex ? LumaPalette.sage : LumaPalette.terracotta)
                            Text(question.explanation)
                                .font(.caption)
                                .foregroundStyle(LumaPalette.secondaryInk)
                        }
                        .padding(.top, 4)
                    }
                }
                .lumaCard()

                HStack {
                    Spacer()
                    Button(questionIndex == questions.count - 1 ? "Volver a empezar" : "Siguiente pregunta") {
                        questionIndex = questionIndex == questions.count - 1 ? 0 : questionIndex + 1
                        selectedAnswer = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.indigo)
                    .disabled(selectedAnswer == nil)
                }
            }
        }
    }

    private func importPDF(_ result: Result<[URL], Error>) {
        Task { @MainActor in
            do {
                guard let url = try result.get().first else { return }
                isProcessing = true
                processingProgress = 0
                processingStage = "Preparando el PDF"
                message = ""

                let document = try await PDFStudyExtractor().extract(from: url) { fraction, stage in
                    processingProgress = fraction * 0.28
                    processingStage = stage
                }
                let system = try await aiEngine.createStudySystem(for: document, examDate: examDate) { fraction, stage in
                    processingProgress = 0.28 + fraction * 0.72
                    processingStage = stage
                }
                let guide = StudyGuide(
                    title: document.title,
                    sourceFileName: document.fileName,
                    examDate: examDate,
                    pageCount: document.pageCount,
                    overview: system.overview,
                    sourcePages: document.pages,
                    topics: system.topics,
                    flashcards: system.flashcards,
                    questions: system.questions
                )
                modelContext.insert(guide)
                try modelContext.save()
                selectedGuideID = guide.id
                selectedTab = .plan
                message = "Listo. Armé \(system.topics.count) temas, \(system.flashcards.count) tarjetas y \(system.questions.count) preguntas."
            } catch {
                message = "No pude crear el sistema de estudio: \(error.localizedDescription)"
            }
            processingProgress = 1
            isProcessing = false
        }
    }

    private func regenerate(_ guide: StudyGuide) {
        Task { @MainActor in
            do {
                isProcessing = true
                processingProgress = 0
                processingStage = "Revisando el material de estudio"
                message = ""

                let document = ExtractedStudyDocument(
                    title: guide.title,
                    fileName: guide.sourceFileName,
                    pageCount: guide.pageCount,
                    pages: guide.sourcePages
                )
                let system = try await aiEngine.createStudySystem(
                    for: document,
                    examDate: guide.examDate
                ) { fraction, stage in
                    processingProgress = fraction
                    processingStage = stage
                }

                guide.overview = system.overview
                guide.topics = preservingTaskLinks(from: guide.topics, in: system.topics)
                guide.flashcards = system.flashcards
                guide.questions = system.questions
                guide.generatedAt = .now
                guide.generationVersion = 2
                try modelContext.save()
                resetPracticeState()
                message = "Reemplacé el contenido anterior por \(system.topics.count) conceptos revisados. Ya no se muestran fragmentos crudos del PDF."
            } catch {
                message = "No pude regenerar el material: \(error.localizedDescription)"
            }
            processingProgress = 1
            isProcessing = false
        }
    }

    private func preservingTaskLinks(
        from previousTopics: [StudyTopic],
        in generatedTopics: [StudyTopic]
    ) -> [StudyTopic] {
        var usedPreviousIDs = Set<UUID>()
        return generatedTopics.map { generated in
            var result = generated
            let generatedPages = Set(generated.sourcePages)
            let match = previousTopics
                .filter { $0.taskID != nil && !usedPreviousIDs.contains($0.id) }
                .max { lhs, rhs in
                    generatedPages.intersection(lhs.sourcePages).count
                        < generatedPages.intersection(rhs.sourcePages).count
                }
            if let match,
               !generatedPages.intersection(match.sourcePages).isEmpty
            {
                result.taskID = match.taskID
                usedPreviousIDs.insert(match.id)
            }
            return result
        }
    }

    private func addStudySessions(for guide: StudyGuide) {
        let drafts = StudyScheduleBuilder.drafts(
            guideID: guide.id,
            guideTitle: guide.title,
            topics: guide.topics,
            examDate: guide.examDate
        )
        var topics = guide.topics
        var added = 0
        var addedTasks: [LumaTask] = []

        for draft in drafts {
            let marker = if let topicID = draft.topicID {
                "LUMA-STUDY-TOPIC:\(topicID.uuidString)"
            } else {
                "LUMA-STUDY-GUIDE:\(guide.id.uuidString)\nLUMA-STUDY-REVIEW"
            }
            let existing = tasks.first { $0.notes.contains(marker) }
            let task: LumaTask
            if let existing {
                task = existing
            } else {
                task = LumaTask(
                    title: draft.title,
                    area: .university,
                    deadline: draft.deadline,
                    estimatedMinutes: draft.estimatedMinutes,
                    energy: draft.energy,
                    impact: .grade,
                    notes: draft.notes
                )
                modelContext.insert(task)
                addedTasks.append(task)
                added += 1
            }

            if let topicID = draft.topicID,
               let index = topics.firstIndex(where: { $0.id == topicID })
            {
                topics[index].taskID = task.id
            } else {
                guide.reviewTaskID = task.id
            }
        }

        guide.topics = topics
        try? modelContext.save()
        for task in addedTasks {
            try? calendarService.syncTask(task)
        }
        appState.refreshPlan()
        message = added == 0
            ? "Ese plan ya estaba agregado a tu agenda."
            : "Agregué \(added) sesiones. Luma las va a priorizar junto con el resto de tu semana."
    }

    private func toggleMastered(cardID: UUID, in guide: StudyGuide) {
        var cards = guide.flashcards
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[index].isMastered.toggle()
        guide.flashcards = cards
        try? modelContext.save()
    }

    private func resetPracticeState() {
        selectedTab = .plan
        cardIndex = 0
        isCardRevealed = false
        questionIndex = 0
        selectedAnswer = nil
    }

    private func safeCardIndex(for cards: [StudyFlashcard]) -> Int {
        min(max(0, cardIndex), max(0, cards.count - 1))
    }

    private func safeQuestionIndex(for questions: [StudyQuizQuestion]) -> Int {
        min(max(0, questionIndex), max(0, questions.count - 1))
    }

    private func importanceLabel(_ importance: Int) -> String {
        switch importance {
        case 3: "Clave"
        case 2: "Importante"
        default: "Complementario"
        }
    }

    private func answerColor(_ optionIndex: Int, question: StudyQuizQuestion) -> Color {
        guard let selectedAnswer else { return LumaPalette.indigo }
        if optionIndex == question.safeCorrectIndex { return LumaPalette.sage }
        if optionIndex == selectedAnswer { return LumaPalette.terracotta }
        return LumaPalette.secondaryInk
    }
}

private enum StudyDetailTab: String, CaseIterable, Identifiable {
    case plan
    case cards
    case practice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan: "Plan"
        case .cards: "Tarjetas"
        case .practice: "Práctica"
        }
    }

    var symbol: String {
        switch self {
        case .plan: "list.bullet.clipboard"
        case .cards: "rectangle.on.rectangle"
        case .practice: "questionmark.bubble"
        }
    }
}
