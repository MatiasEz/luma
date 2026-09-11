import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ExamsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AcademicExam.date) private var exams: [AcademicExam]
    @Query(sort: \AcademicRoutine.updatedAt) private var routines: [AcademicRoutine]
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]
    @Query(sort: \DailyPlanningContext.updatedAt) private var dailyContexts: [DailyPlanningContext]
    @State private var viewModel = ExamsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom) { heading; Spacer(); addButton }
                    VStack(alignment: .leading, spacing: 12) { heading; addButton }
                }

                if viewModel.upcoming(from: exams).isEmpty {
                    EmptyStateView(
                        symbol: "graduationcap.fill",
                        title: "No hay exámenes próximos",
                        message: "Cuando agregues uno, Luma va a repartir su preparación en bloques manejables."
                    )
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(viewModel.upcoming(from: exams)) { exam in examCard(exam) }
                    }
                }
            }
            .padding(30)
            .lumaScrollContent()
        }
        .lumaScrollSurface()
        .navigationTitle("Exámenes")
        .sheet(
            isPresented: $viewModel.editorPresented,
            onDismiss: viewModel.editorDismissed
        ) {
            ExamEditorView(exam: viewModel.editingExam, onSave: saveExam)
        }
    }

    private var heading: some View {
        SectionTitle(
            eyebrow: "Preparación sin maratones",
            title: "Exámenes y temarios",
            trailing: exams.filter { !$0.isArchived }.count == 1 ? "1 examen" : "\(exams.filter { !$0.isArchived }.count) exámenes"
        )
    }

    private var addButton: some View {
        Button { viewModel.presentNewExam() } label: {
            Label("Agregar examen", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .tint(LumaPalette.indigo)
    }

    private func examCard(_ exam: AcademicExam) -> some View {
        let completed = viewModel.completedStages(for: exam, tasks: tasks)
        let studyTasks = viewModel.studyTasks(for: exam, tasks: tasks)
        let usesGeneratedPlan = viewModel.usesGeneratedTopicPlan(for: exam, tasks: tasks)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "graduationcap.fill")
                    .font(.title3)
                    .foregroundStyle(LumaPalette.indigo)
                    .frame(width: 48, height: 48)
                    .background(LumaPalette.indigo.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Text(exam.title).font(.headline).foregroundStyle(LumaPalette.ink)
                    Text("\(viewModel.subjectName(for: exam, subjects: subjects)) · \(exam.date.formatted(.dateTime.day().month(.wide)))")
                        .font(.subheadline)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                Text(daysLabel(until: exam.date))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LumaPalette.terracotta)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(LumaPalette.terracotta.opacity(0.10), in: Capsule())
                Button {
                    viewModel.presentEditor(for: exam)
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 30, height: 30)
                        .background(LumaPalette.indigo.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(LumaPalette.indigo)
                .help("Editar examen")
            }

            if exam.topics.isEmpty {
                Label("Sin temario · podés agregarlo más adelante", systemImage: "doc.badge.plus")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            } else {
                Text(exam.topics.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .lineLimit(2)
            }

            if exam.topics.isEmpty {
                EmptyView()
            } else if usesGeneratedPlan {
                generatedPlanProgress(studyTasks)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(ExamStudyStage.allCases.enumerated()), id: \.element.id) { index, stage in
                        VStack(spacing: 6) {
                            Image(systemName: completed.contains(stage) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(completed.contains(stage) ? LumaPalette.sage : LumaPalette.lavender)
                            Text(stage.shortTitle)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(LumaPalette.secondaryInk)
                        }
                        .frame(maxWidth: .infinity)
                        if index < ExamStudyStage.allCases.count - 1 {
                            Rectangle().fill(LumaPalette.lavender.opacity(0.35)).frame(height: 2).frame(maxWidth: 34)
                        }
                    }
                }
            }
        }
        .lumaCard(padding: 18)
    }

    private func generatedPlanProgress(_ studyTasks: [LumaTask]) -> some View {
        let completedCount = studyTasks.filter(\.isCompleted).count
        let progress = studyTasks.isEmpty ? 0 : Double(completedCount) / Double(studyTasks.count)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Plan creado por temas", systemImage: "list.bullet.clipboard")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.indigo)
                Spacer()
                Text("\(completedCount) de \(studyTasks.count) sesiones")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
            ProgressView(value: progress)
                .tint(LumaPalette.sage)
        }
    }

    private func materialize() {
        let currentRoutines = (try? modelContext.fetch(FetchDescriptor<AcademicRoutine>())) ?? routines
        let currentExams = (try? modelContext.fetch(FetchDescriptor<AcademicExam>())) ?? exams
        let currentTasks = (try? modelContext.fetch(FetchDescriptor<LumaTask>())) ?? tasks
        AcademicPlanningService().materialize(
            routines: currentRoutines,
            exams: currentExams,
            tasks: currentTasks,
            dailyContext: dailyContexts.first { Calendar.current.isDateInToday($0.day) },
            in: modelContext
        )
        appState.refreshPlan()
    }

    private func saveExam(
        _ draft: AcademicExam,
        generatedTopics: [StudyTopic],
        sourceFileName: String
    ) {
        let savedExam: AcademicExam
        var tasksAvailableForGeneration = tasks

        if let existing = viewModel.editingExam {
            let pendingStudyTasks = tasks.filter {
                $0.sourceID == existing.id
                    && $0.academicSourceType == .examStudy
                    && !$0.isCompleted
            }
            let removedIDs = Set(pendingStudyTasks.map(\.id))
            for task in pendingStudyTasks { modelContext.delete(task) }
            tasksAvailableForGeneration.removeAll { removedIDs.contains($0.id) }

            existing.title = draft.title
            existing.subjectID = draft.subjectID
            existing.date = draft.date
            existing.topicsRaw = draft.topicsRaw
            existing.importance = draft.importance
            existing.preparationMinutes = draft.preparationMinutes
            existing.updatedAt = .now
            savedExam = existing

            #if DEBUG
            print("✏️ [EXAMEN] Actualizado | nombre=\(existing.title) | tareas pendientes reemplazadas=\(pendingStudyTasks.count)")
            #endif
        } else {
            modelContext.insert(draft)
            savedExam = draft
        }

        if !generatedTopics.isEmpty {
            AcademicPlanningService().materializeGeneratedExamStudy(
                exam: savedExam,
                topics: generatedTopics,
                sourceFileName: sourceFileName,
                tasks: tasksAvailableForGeneration,
                in: modelContext
            )
        }
        try? modelContext.save()
        materialize()
    }

    private func daysLabel(until date: Date) -> String {
        let days = max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: Calendar.current.startOfDay(for: date)).day ?? 0)
        return days == 1 ? "Mañana" : "\(days) días"
    }
}

private struct ExamEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    let exam: AcademicExam?
    @State private var viewModel: ExamEditorViewModel
    @State private var expandedUnitIDs: Set<UUID> = []
    let onSave: (AcademicExam, [StudyTopic], String) -> Void

    init(
        exam: AcademicExam?,
        onSave: @escaping (AcademicExam, [StudyTopic], String) -> Void
    ) {
        self.exam = exam
        self.onSave = onSave
        _viewModel = State(initialValue: ExamEditorViewModel(exam: exam))
    }

    private var selectedSubject: AcademicSubject? {
        viewModel.subjectID.flatMap { id in subjects.first { !$0.isArchived && $0.id == id } }
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: 18) {
            Text(exam == nil ? "Nuevo examen" : "Editar examen")
                .font(.title2.weight(.semibold))
                .foregroundStyle(LumaPalette.ink)
            Text("El temario es opcional. Si elegís temas, Luma los convierte en tareas y los reparte antes de la fecha.")
                .font(.subheadline).foregroundStyle(LumaPalette.secondaryInk)
            TextField("Ej. Parcial de Parasitología", text: $viewModel.title).textFieldStyle(.roundedBorder)
            Picker("Materia", selection: $viewModel.subjectID) {
                Text("Elegí una materia").tag(UUID?.none)
                ForEach(subjects.filter { !$0.isArchived }) { Text($0.name).tag(Optional($0.id)) }
            }
            .onChange(of: viewModel.subjectID) { oldValue, newValue in
                if oldValue != newValue {
                    viewModel.resetTopicsForSubjectChange()
                    expandedUnitIDs = []
                }
            }
            HStack {
                DatePicker("Fecha", selection: $viewModel.date, displayedComponents: [.date])
                Picker("Importancia", selection: $viewModel.importance) {
                    ForEach(ExamImportance.allCases) { Text($0.title).tag($0) }
                }
                Stepper("\(viewModel.preparationMinutes / 60) h aprox.", value: $viewModel.preparationMinutes, in: 100 ... 1200, step: 30)
            }

            examTopicsSection

            Spacer()
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(.bordered)
                Button(saveButtonTitle) {
                    guard let subject = selectedSubject else { return }
                    let selectedTopics = viewModel.topicTitles(for: subject)
                    let exam = AcademicExam(
                        id: self.exam?.id ?? UUID(),
                        title: viewModel.title.trimmingCharacters(in: .whitespacesAndNewlines),
                        subjectID: subject.id,
                        date: viewModel.date,
                        topicsRaw: selectedTopics.joined(separator: "\n"),
                        importance: viewModel.importance,
                        preparationMinutes: viewModel.preparationMinutes,
                        isArchived: self.exam?.isArchived ?? false,
                        createdAt: self.exam?.createdAt ?? .now,
                        updatedAt: .now
                    )
                    #if DEBUG
                    print("📝 [EXAMEN] Confirmado | nombre=\(exam.title) | materia=\(subject.name) | temas=\(selectedTopics.joined(separator: " | ")) | preparación=\(exam.preparationMinutes)m")
                    #endif
                    onSave(
                        exam,
                        viewModel.topicsForGeneratedPlan(subject: subject),
                        subject.syllabusSourceFileName
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(LumaPalette.indigo)
                .disabled(!viewModel.canSave(subjects: subjects))
            }
        }
        .padding(26)
        .frame(width: 760, height: 700)
        .background(LumaBackground())
        .onAppear {
            if let selectedSubject {
                viewModel.configureExistingTopics(for: selectedSubject)
            }
        }
    }

    private var saveButtonTitle: String {
        guard exam == nil else { return "Guardar cambios" }
        guard let subject = selectedSubject,
              !viewModel.topicTitles(for: subject).isEmpty
        else {
            return "Crear examen"
        }
        return "Crear plan de estudio"
    }

    @ViewBuilder
    private var examTopicsSection: some View {
        if let subject = selectedSubject {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("¿Qué temas entran? (opcional)")
                            .font(.headline)
                            .foregroundStyle(LumaPalette.ink)
                        Text("Si todavía no los sabés, podés guardar el examen y completar el temario después.")
                            .font(.caption)
                            .foregroundStyle(LumaPalette.secondaryInk)
                    }
                    Spacer()
                    let count = viewModel.topicTitles(for: subject).count
                    Text(count == 1 ? "1 tema" : "\(count) temas")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(count == 0 ? LumaPalette.secondaryInk : LumaPalette.sage)
                }

                if subject.hasSyllabusPDF {
                    Label(
                        "Temario: \(subject.syllabusSourceFileName) · \(subject.syllabusPageCount) páginas",
                        systemImage: "doc.text.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.indigo)
                }

                if subject.syllabusTopics.isEmpty {
                    Label(
                        "Esta materia todavía no tiene temario. Podés escribir los temas abajo o cargar el PDF desde Materias.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 9) {
                            ForEach(subject.syllabusStudyTopics) { topic in
                                syllabusUnitRow(topic)
                            }
                        }
                    }
                    .frame(maxHeight: 245)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Otros temas que también entran")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LumaPalette.secondaryInk)
                    ZStack(alignment: .topLeading) {
                        if viewModel.topicsRaw.isEmpty {
                            Text("Opcional · uno por línea")
                                .foregroundStyle(LumaPalette.secondaryInk.opacity(0.72))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $viewModel.topicsRaw)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                    }
                    .frame(minHeight: 82, maxHeight: 120)
                    .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(LumaPalette.secondaryInk.opacity(0.20), lineWidth: 1)
                    }
                }
            }
            .padding(15)
            .background(Color.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 15))
        } else {
            Label("Elegí una materia para ver su temario.", systemImage: "arrow.up.circle")
                .font(.subheadline)
                .foregroundStyle(LumaPalette.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func syllabusUnitRow(_ topic: StudyTopic) -> some View {
        let subtopics = topic.syllabusSubtopics
        let isExpanded = expandedUnitIDs.contains(topic.id)
        let fullySelected = viewModel.isUnitFullySelected(topic)
        let partiallySelected = viewModel.isUnitPartiallySelected(topic)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    viewModel.toggleUnit(topic)
                } label: {
                    Image(systemName: fullySelected ? "checkmark.circle.fill" : partiallySelected ? "minus.circle.fill" : "circle")
                        .foregroundStyle(fullySelected || partiallySelected ? LumaPalette.indigo : LumaPalette.secondaryInk)
                    Text(topic.title)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(LumaPalette.ink)
                    Spacer(minLength: 8)
                    if !subtopics.isEmpty {
                        Text("\(subtopics.count) subtemas")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(LumaPalette.secondaryInk)
                    }
                }
                .buttonStyle(.plain)

                if !subtopics.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if isExpanded {
                                expandedUnitIDs.remove(topic.id)
                            } else {
                                expandedUnitIDs.insert(topic.id)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LumaPalette.indigo)
                    .help(isExpanded ? "Ocultar subtemas" : "Ver subtemas")
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 10)

            if isExpanded, !subtopics.isEmpty {
                Divider().opacity(0.45)
                VStack(spacing: 4) {
                    ForEach(subtopics) { subtopic in
                        Button {
                            viewModel.toggleTopic(subtopic.displayTitle)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: viewModel.isSelected(subtopic.displayTitle) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(viewModel.isSelected(subtopic.displayTitle) ? LumaPalette.sage : LumaPalette.secondaryInk)
                                Text(subtopic.displayTitle)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(LumaPalette.ink)
                                Spacer(minLength: 0)
                            }
                            .font(.caption)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                viewModel.isSelected(subtopic.displayTitle)
                                    ? LumaPalette.sage.opacity(0.10)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
        }
        .background(Color.white.opacity(0.70), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(LumaPalette.indigo.opacity(fullySelected || partiallySelected ? 0.30 : 0.10), lineWidth: 1)
        }
    }
}
