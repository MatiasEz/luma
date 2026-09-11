import SwiftData
import SwiftUI

struct QuickCaptureView: View {
    @Environment(AppState.self) private var appState
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(LocalAIEngine.self) private var aiEngine
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @Query(sort: \AcademicRoutine.updatedAt) private var routines: [AcademicRoutine]
    @Query(sort: \AcademicExam.updatedAt) private var exams: [AcademicExam]

    @State private var viewModel: QuickCaptureViewModel
    @State private var saveError: String?
    @State private var showsDetails = false
    @State private var manualMode: Bool
    @FocusState private var titleFocused: Bool
    private let startsWithScheduledDate: Bool

    init(initialText: String = "", scheduledDate: Date? = nil) {
        let model = QuickCaptureViewModel()
        model.naturalLanguageInput = initialText
        model.draft.title = initialText
        model.draft.deadline = scheduledDate
        _viewModel = State(initialValue: model)
        _manualMode = State(initialValue: true)
        startsWithScheduledDate = scheduledDate != nil
    }

    private var activeSubjects: [AcademicSubject] {
        viewModel.activeSubjects(from: subjects)
    }

    private var assignmentIsValid: Bool {
        viewModel.assignmentIsValid(subjects: subjects)
    }

    private var canSave: Bool {
        guard viewModel.clarification == nil else { return false }
        if !viewModel.academicDrafts.isEmpty {
            return viewModel.academicDrafts.allSatisfy(isValidAcademicDraft)
        }
        let dependencyIsValid = viewModel.draft.unlocksTaskID.map { id in
            tasks.contains { $0.id == id && !$0.isCompleted }
        } ?? true
        return viewModel.canSave(subjects: subjects)
            && assignmentIsValid
            && dependencyIsValid
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(captureTitle)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                    Text(captureSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                Button("Cerrar") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.body.weight(.medium))
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.55), in: Capsule())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(26)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    draftEditor
                    if let saveError { Label(saveError, systemImage: "exclamationmark.triangle").foregroundStyle(LumaPalette.terracotta) }
                }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 20)
                    .lumaScrollContent()
            }
            .lumaScrollSurface()

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(LumaPalette.indigo)
                Button(saveButtonTitle) { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.indigo)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(26)
        }
        .frame(height: showsDetails ? 650 : 400)
        .background(LumaBackground())
        .environment(\.colorScheme, .light)
        .onAppear {
            DispatchQueue.main.async { titleFocused = true }
        }
        .onDisappear { appState.quickCaptureSeed = "" }
    }

    private var naturalLanguageCapture: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.isAwaitingClarification ? "Completá este dato" : "¿Qué querés organizar?")
                .font(.caption.weight(.bold))
                .foregroundStyle(LumaPalette.sage)
                .textCase(.uppercase)
                .tracking(1.1)

            if let clarification = viewModel.clarification {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(LumaPalette.indigo)
                        .frame(width: 30, height: 30)
                        .background(LumaPalette.indigo.opacity(0.10), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Luma te pregunta")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LumaPalette.indigo)
                        Text(clarification.question)
                            .font(.body.weight(.medium))
                            .foregroundStyle(LumaPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(LumaPalette.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            TextField(
                capturePlaceholder,
                text: $viewModel.naturalLanguageInput,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .font(.body)
            .lineLimit(2 ... 4)
            .onSubmit { Task { await interpret() } }

            HStack {
                if viewModel.isInterpreting {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.isAwaitingClarification ? "Sumando tu respuesta…" : "Entendiendo tu pedido…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(LumaPalette.secondaryInk)
                    Spacer()
                } else if viewModel.isAwaitingClarification {
                    Button("Empezar de nuevo") {
                        viewModel.resetInterpretation()
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.secondaryInk)
                    Spacer()
                    Button {
                        Task { await interpret() }
                    } label: {
                        Label("Responder", systemImage: "arrow.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.indigo)
                    .disabled(viewModel.naturalLanguageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if !viewModel.academicDrafts.isEmpty {
                    Label(interpretationSummary, systemImage: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.sage)
                    Spacer()
                    Button("Volver a interpretar") {
                        viewModel.resetInterpretation()
                        Task { await interpret() }
                    }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LumaPalette.indigo)
                } else {
                    Spacer()
                    Button {
                        Task { await interpret() }
                    } label: {
                        Label("Interpretar", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.indigo)
                    .disabled(
                        viewModel.naturalLanguageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.isInterpreting
                    )
                }
            }
        }
        .lumaCard(padding: 16)
    }

    private var captureTitle: String {
        if startsWithScheduledDate { return "Nueva tarea" }
        return "Nuevo pendiente"
    }

    private var captureSubtitle: String {
        if startsWithScheduledDate {
            return "La fecha ya está seleccionada. Completá el título y ajustá la hora si hace falta."
        }
        return "Completá los datos para agregarlo al Inbox."
    }

    private var capturePlaceholder: String {
        viewModel.isAwaitingClarification
            ? "Respondé como te salga…"
            : "Ej. El lunes estudio Anatomía; el martes entrego el informe; los viernes tengo laboratorio"
    }

    private var interpretationSummary: String {
        let count = viewModel.academicDrafts.count
        return count == 1
            ? "Revisá la propuesta antes de guardarla"
            : "Revisá las \(count) propuestas antes de guardarlas"
    }

    private var saveButtonTitle: String {
        let count = viewModel.academicDrafts.count
        if count == 1 { return "Confirmar y guardar" }
        if count > 1 { return "Guardar \(count) propuestas" }
        return "Guardar pendiente"
    }

    private var detectedProposalsOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Propuestas detectadas")
                        .font(.headline)
                        .foregroundStyle(LumaPalette.ink)
                    Text("Se van a guardar juntas cuando confirmes.")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                Text("\(viewModel.academicDrafts.count)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(LumaPalette.indigo)
                    .frame(minWidth: 34, minHeight: 34)
                    .background(LumaPalette.indigo.opacity(0.10), in: Circle())
            }

            VStack(spacing: 0) {
                ForEach(Array(viewModel.academicDrafts.enumerated()), id: \.element.id) { index, draft in
                    HStack(spacing: 11) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(LumaPalette.indigo)
                            .frame(width: 28, height: 28)
                            .background(LumaPalette.indigo.opacity(0.08), in: Circle())

                        Image(systemName: draft.kind.symbol)
                            .foregroundStyle(LumaPalette.indigo)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(LumaPalette.ink)
                                .lineLimit(2)
                            Text(proposalMetadata(for: draft))
                                .font(.caption)
                                .foregroundStyle(LumaPalette.secondaryInk)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)
                        if viewModel.clarification?.draftID == draft.id {
                            Label("Completando", systemImage: "ellipsis.message.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(LumaPalette.mustard)
                        } else {
                            Label("Incluida", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(LumaPalette.sage)
                        }
                    }
                    .padding(.vertical, 10)

                    if index < viewModel.academicDrafts.count - 1 {
                        Divider().opacity(0.45)
                    }
                }
            }
        }
        .lumaCard(padding: 16)
    }

    private func proposalMetadata(for draft: AcademicCaptureDraft) -> String {
        var parts = [draft.kind.title]
        if let subjectID = draft.subjectID,
           let subject = subjects.first(where: { $0.id == subjectID })
        {
            parts.append(subject.name)
        } else if let proposed = draft.proposedSubjectName {
            parts.append(proposed)
        }
        if let date = draft.date {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        } else if let weekday = draft.weekday,
                  let title = weekdayOptions.first(where: { $0.value == weekday })?.title
        {
            parts.append(title)
        }
        return parts.joined(separator: " · ")
    }

    private func interpretationNotice(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(LumaPalette.mustard)
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.academicDrafts.isEmpty ? "Luma te responde" : "Hay una parte que Luma no puede hacer")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .background(LumaPalette.mustard.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func interpretedEditor(draft: Binding<AcademicCaptureDraft>, draftID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: draft.wrappedValue.kind.symbol)
                    .foregroundStyle(LumaPalette.indigo)
                    .frame(width: 38, height: 38)
                    .background(LumaPalette.indigo.opacity(0.10), in: Circle())
                Picker("Tipo", selection: draft.kind) {
                    ForEach(AcademicCaptureKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(kind)
                    }
                }
                Spacer()
                if viewModel.academicDrafts.count > 1 {
                    Button {
                        viewModel.removeDraft(id: draftID, subjects: subjects)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .help("No guardar esta propuesta")
                }
            }

            TextField("Título", text: draft.title)
                .textFieldStyle(.roundedBorder)

            if draft.wrappedValue.kind != .subject {
                if let proposedSubjectName = draft.wrappedValue.proposedSubjectName {
                    HStack(spacing: 10) {
                        Text("Materia")
                        Label("\(proposedSubjectName) · Nueva", systemImage: "books.vertical.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LumaPalette.sage)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(LumaPalette.sage.opacity(0.10), in: Capsule())
                        Spacer()
                        Button("Quitar") {
                            draft.wrappedValue.proposedSubjectName = nil
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LumaPalette.secondaryInk)
                    }
                } else {
                    Picker("Materia", selection: draft.subjectID) {
                        Text("Sin materia").tag(UUID?.none)
                        ForEach(activeSubjects) { subject in
                            Text(subject.name).tag(Optional(subject.id))
                        }
                    }
                }
            }

            if draft.wrappedValue.kind == .subject {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Temario inicial · opcional")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LumaPalette.secondaryInk)
                    TextField("Un tema por línea o separados por comas", text: draft.topicsRaw, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2 ... 5)
                }
            } else if draft.wrappedValue.kind == .exam {
                DatePicker(
                    "Fecha del examen",
                    selection: Binding(
                        get: { draft.wrappedValue.date ?? .now.addingTimeInterval(7 * 86_400) },
                        set: { draft.wrappedValue.date = $0 }
                    ),
                    displayedComponents: [.date]
                )
                Picker("Importancia", selection: draft.importance) {
                    ForEach(ExamImportance.allCases) { importance in
                        Text(importance.title).tag(importance)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Temas")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LumaPalette.secondaryInk)
                    TextField("Un tema por línea o separados por comas", text: draft.topicsRaw, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3 ... 6)
                }
            } else if draft.wrappedValue.kind == .routine || draft.wrappedValue.kind == .classMeeting {
                HStack(spacing: 14) {
                    Picker("Día", selection: draft.weekday) {
                        ForEach(weekdayOptions, id: \.value) { option in
                            Text(option.title).tag(Optional(option.value))
                        }
                    }
                    Toggle("Con hora", isOn: Binding(
                        get: { draft.wrappedValue.minuteOfDay != nil },
                        set: { draft.wrappedValue.minuteOfDay = $0 ? 17 * 60 : nil }
                    ))
                    if draft.wrappedValue.minuteOfDay != nil {
                        DatePicker("Hora", selection: timeBinding(for: draft), displayedComponents: [.hourAndMinute])
                            .labelsHidden()
                    }
                }
                Picker("Actividad", selection: draft.activityType) {
                    ForEach(AcademicActivityType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
            } else {
                Toggle("Tiene fecha", isOn: Binding(
                    get: { draft.wrappedValue.date != nil },
                    set: { draft.wrappedValue.date = $0 ? .now.addingTimeInterval(86_400) : nil }
                ))
                if draft.wrappedValue.date != nil {
                    DatePicker(
                        "Fecha y hora",
                        selection: Binding(get: { draft.wrappedValue.date ?? .now }, set: { draft.wrappedValue.date = $0 }),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
            }

            if draft.wrappedValue.kind != .subject {
                HStack {
                    Stepper("\(draft.wrappedValue.estimatedMinutes) min", value: draft.estimatedMinutes, in: 10 ... 900, step: 5)
                    Spacer()
                    Picker("Energía", selection: draft.energy) {
                        ForEach(EnergyLevel.allCases) { energy in
                            Text(energy.title).tag(energy)
                        }
                    }
                    .frame(width: 150)
                }
            }
        }
        .padding(17)
        .background(Color.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var draftEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Título", text: $viewModel.draft.title)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(LumaPalette.ink)
                .focused($titleFocused)

            HStack(spacing: 16) {
                Toggle("Tiene fecha de entrega", isOn: Binding(
                    get: { viewModel.draft.dueDate != nil },
                    set: { viewModel.draft.dueDate = $0 ? (.now.addingTimeInterval(86_400)) : nil }
                ))

                if viewModel.draft.dueDate != nil {
                    DatePicker(
                        "Entrega",
                        selection: Binding(get: { viewModel.draft.dueDate ?? .now }, set: { viewModel.draft.dueDate = $0 }),
                        displayedComponents: [.date]
                    )
                    .labelsHidden()
                }
                Spacer()
            }



            Stepper("Duración total: \(viewModel.draft.estimatedMinutes) min", value: $viewModel.draft.estimatedMinutes, in: 5 ... 1_800, step: 5)

            DisclosureGroup("Más detalles · área, energía y horario", isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Picker("Área", selection: $viewModel.draft.area) {
                    ForEach(LifeArea.allCases) { area in
                        Label(area.title, systemImage: area.symbol).tag(area)
                    }
                }

                Picker("Energía", selection: $viewModel.draft.energy) {
                    ForEach(EnergyLevel.allCases) { energy in
                        Text(energy.title).tag(energy)
                    }
                }

                Picker("Impacto", selection: $viewModel.draft.impact) {
                    ForEach(ImpactType.allCases) { impact in
                        Text(impact.title).tag(impact)
                    }
                }
            }

            HStack(spacing: 16) {
                Toggle("Programar en calendario", isOn: Binding(
                    get: { viewModel.draft.deadline != nil },
                    set: { viewModel.draft.deadline = $0 ? (.now.addingTimeInterval(86400)) : nil }
                ))

                if viewModel.draft.deadline != nil {
                    DatePicker(
                        "Día",
                        selection: Binding(get: { viewModel.draft.deadline ?? .now }, set: { viewModel.draft.deadline = $0 }),
                        displayedComponents: [.date]
                    )
                    .labelsHidden()

                    DatePicker(
                        "Hora de inicio",
                        selection: Binding(get: { viewModel.draft.deadline ?? .now }, set: { viewModel.draft.deadline = $0 }),
                        displayedComponents: [.hourAndMinute]
                    )
                    .labelsHidden()
                }

                Spacer()
            }
            if viewModel.draft.area == .university {
                AcademicTaskFields(
                    subjects: activeSubjects,
                    subjectID: $viewModel.draft.academicSubjectID
                )
            }

            TaskDependencyPicker(
                sourceTaskID: nil,
                tasks: tasks,
                selectedTaskID: $viewModel.draft.unlocksTaskID
            )
                    Toggle("Ponderación en la nota", isOn: Binding(
                        get: { viewModel.draft.academicWeight != nil },
                        set: { viewModel.draft.academicWeight = $0 ? 20 : nil }))
                    if viewModel.draft.academicWeight != nil {
                        Stepper("Vale \(Int(viewModel.draft.academicWeight ?? 0))%", value: Binding(
                            get: { viewModel.draft.academicWeight ?? 20 }, set: { viewModel.draft.academicWeight = $0 }), in: 0...100, step: 5)
                    }
                }.padding(.top, 12)
            }

        }
        .padding(16)
        .background(Color.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 16))
    }

    private func save() {
        if !viewModel.academicDrafts.isEmpty {
            saveAcademic(drafts: viewModel.academicDrafts)
            return
        }
        let task = LumaTask(
            title: viewModel.draft.title,
            area: viewModel.draft.area,
            dueDate: viewModel.draft.dueDate,
            deadline: viewModel.draft.deadline,
            estimatedMinutes: viewModel.draft.estimatedMinutes,
            energy: viewModel.draft.energy,
            impact: viewModel.draft.impact,
            academicWeight: viewModel.draft.academicWeight,
            academicSubjectID: viewModel.draft.area == .university ? viewModel.draft.academicSubjectID : nil,
            subjectGradeItemID: nil,
            grade: nil,
            unlocksAnotherTask: viewModel.draft.unlocksTaskID != nil,
            unlocksTaskID: viewModel.draft.unlocksTaskID,
            notes: viewModel.draft.notes
        )
        modelContext.insert(task)
        do {
            try modelContext.save()
            try? calendarService.syncTask(task)
            appState.refreshPlan()
            dismiss()
        } catch {
            modelContext.delete(task)
            saveError = "No pude guardar el pendiente. Tu texto sigue acá; intentá de nuevo."
        }
    }

    private func interpret() async {
        guard !viewModel.naturalLanguageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        manualMode = false
        await viewModel.interpret(subjects: subjects, aiEngine: aiEngine)
    }

    private func saveAcademic(drafts: [AcademicCaptureDraft]) {
        let now = Date.now
        var subjectIDsByName = activeSubjects.reduce(into: [String: UUID]()) { result, subject in
            result[normalizedSubjectName(subject.name)] = subject.id
        }

        for draft in drafts where draft.kind == .subject {
            let subjectName = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subjectName.isEmpty else { continue }
            let key = normalizedSubjectName(subjectName)
            guard subjectIDsByName[key] == nil else { continue }
            let subject = AcademicSubject(
                name: subjectName,
                syllabusRaw: draft.topicsRaw,
                createdAt: now,
                updatedAt: now
            )
            modelContext.insert(subject)
            subjectIDsByName[key] = subject.id
        }

        for draft in drafts {
            guard draft.kind != .subject else { continue }
            let resolvedSubjectID = draft.subjectID ?? draft.proposedSubjectName.flatMap {
                subjectIDsByName[normalizedSubjectName($0)]
            }
            switch draft.kind {
            case .subject:
                continue
            case .exam:
                guard let subjectID = resolvedSubjectID, let date = draft.date else { continue }
                modelContext.insert(AcademicExam(
                    title: draft.title,
                    subjectID: subjectID,
                    date: date,
                    topicsRaw: draft.topicsRaw,
                    importance: draft.importance,
                    preparationMinutes: draft.estimatedMinutes,
                    createdAt: now,
                    updatedAt: now
                ))
            case .routine:
                guard let weekday = draft.weekday else { continue }
                modelContext.insert(AcademicRoutine(
                    title: draft.title,
                    subjectID: resolvedSubjectID,
                    weekday: weekday,
                    minuteOfDay: draft.minuteOfDay,
                    activityType: draft.activityType,
                    estimatedMinutes: draft.estimatedMinutes,
                    startDate: now,
                    notes: draft.originalText,
                    createdAt: now,
                    updatedAt: now
                ))
            case .classMeeting:
                guard let subjectID = resolvedSubjectID, let weekday = draft.weekday else { continue }
                let start = draft.minuteOfDay ?? 10 * 60
                modelContext.insert(SubjectClassMeeting(
                    subjectID: subjectID,
                    weekday: weekday,
                    startMinuteOfDay: start,
                    endMinuteOfDay: min(23 * 60 + 59, start + draft.estimatedMinutes),
                    createdAt: now,
                    updatedAt: now
                ))
            case .task, .study:
                let normalizedRequest = draft.originalText.folding(
                    options: [.diacriticInsensitive, .caseInsensitive],
                    locale: Locale(identifier: "es")
                )
                let isDeliveryDate = ["entrego", "entregar", "entrega", "vence", "vencimiento", "fecha limite"]
                    .contains(where: normalizedRequest.contains)
                let task = LumaTask(
                    title: draft.title,
                    area: resolvedSubjectID == nil ? .errands : .university,
                    dueDate: isDeliveryDate ? draft.date : nil,
                    deadline: isDeliveryDate ? nil : draft.date,
                    estimatedMinutes: draft.estimatedMinutes,
                    energy: draft.energy,
                    impact: resolvedSubjectID == nil ? .general : .grade,
                    academicSubjectID: resolvedSubjectID,
                    notes: draft.originalText
                )
                modelContext.insert(task)
                try? calendarService.syncTask(task)
            }
        }
        try? modelContext.save()
        let currentRoutines = (try? modelContext.fetch(FetchDescriptor<AcademicRoutine>())) ?? routines
        let currentExams = (try? modelContext.fetch(FetchDescriptor<AcademicExam>())) ?? exams
        let currentTasks = (try? modelContext.fetch(FetchDescriptor<LumaTask>())) ?? tasks
        let context = (try? modelContext.fetch(FetchDescriptor<DailyPlanningContext>()))?.first {
            Calendar.current.isDateInToday($0.day)
        }
        AcademicPlanningService().materialize(
            routines: currentRoutines,
            exams: currentExams,
            tasks: currentTasks,
            dailyContext: context,
            in: modelContext
        )
        appState.refreshPlan()
        dismiss()
    }

    private func isValidAcademicDraft(_ draft: AcademicCaptureDraft) -> Bool {
        if draft.kind == .subject {
            return !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let proposedSubjectExists = draft.proposedSubjectName.map { proposedName in
            viewModel.academicDrafts.contains {
                $0.kind == .subject
                    && normalizedSubjectName($0.title) == normalizedSubjectName(proposedName)
            }
        } ?? false
        let requiresSubject = draft.kind == .exam || draft.kind == .classMeeting
        return !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!requiresSubject || draft.subjectID != nil || proposedSubjectExists)
            && (draft.kind != .exam || draft.date != nil)
            && (!(draft.kind == .routine || draft.kind == .classMeeting) || draft.weekday != nil)
    }

    private func academicDraftBinding(
        id draftID: UUID,
        fallback: AcademicCaptureDraft
    ) -> Binding<AcademicCaptureDraft> {
        Binding(
            get: {
                viewModel.academicDrafts.first(where: { $0.id == draftID }) ?? fallback
            },
            set: { newValue in
                guard let index = viewModel.academicDrafts.firstIndex(where: { $0.id == draftID }) else { return }
                let previous = viewModel.academicDrafts[index]
                var updated = newValue
                if updated.kind == .subject {
                    let previousName = previous.proposedSubjectName ?? previous.title
                    updated.proposedSubjectName = updated.title
                    for linkedIndex in viewModel.academicDrafts.indices
                    where linkedIndex != index
                        && viewModel.academicDrafts[linkedIndex].proposedSubjectName.map(normalizedSubjectName)
                            == normalizedSubjectName(previousName)
                    {
                        viewModel.academicDrafts[linkedIndex].proposedSubjectName = updated.title
                    }
                }
                viewModel.academicDrafts[index] = updated
            }
        )
    }

    private func normalizedSubjectName(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var weekdayOptions: [(title: String, value: Int)] {
        [("Domingo", 1), ("Lunes", 2), ("Martes", 3), ("Miércoles", 4), ("Jueves", 5), ("Viernes", 6), ("Sábado", 7)]
    }

    private func timeBinding(for draft: Binding<AcademicCaptureDraft>) -> Binding<Date> {
        Binding(
            get: {
                let minute = draft.wrappedValue.minuteOfDay ?? 17 * 60
                return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
            },
            set: {
                draft.wrappedValue.minuteOfDay = Calendar.current.component(.hour, from: $0) * 60
                    + Calendar.current.component(.minute, from: $0)
            }
        )
    }
}

struct MenuBarCaptureView: View {
    @Environment(AppState.self) private var appState
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]
    @Query(sort: \FocusSession.endedAt, order: .reverse) private var focusSessions: [FocusSession]
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @Query(sort: \SubjectClassMeeting.updatedAt) private var classMeetings: [SubjectClassMeeting]
    @Query(sort: \DailyPlanningContext.updatedAt) private var dailyContexts: [DailyPlanningContext]
    @State private var viewModel = MenuBarCaptureViewModel()

    private let parser = NaturalLanguageTaskParser()
    private let learningEngine = BehaviorLearningEngine()

    private var topPriority: PlanRecommendation? {
        let profile = learningEngine.profile(from: focusSessions)
        let context = dailyContexts.first { Calendar.current.isDateInToday($0.day) }
        let planner = TaskPlanner(
            rhythmProfile: appState.learningEnabled ? profile : nil,
            preferredBlockOverride: appState.preferredBlockOverride,
            availableMinutes: appState.remainingAvailableMinutes(fallback: context?.availableMinutes ?? 120),
            planningMode: context?.planningMode ?? .realistic,
            classMeetings: classMeetings,
            subjectNames: Dictionary(uniqueKeysWithValues: subjects.map { ($0.id, $0.name) }),
            weeklyAvailability: appState.weeklyAvailability,
            restCounts: context?.restCounts ?? true
        )
        return appState.dailyRecommendations(from: tasks, planner: planner).first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Luma", systemImage: "moon.stars.fill")
                    .font(.headline)
                    .foregroundStyle(LumaPalette.indigo)
                Spacer()
                Text("Captura rápida")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("¿Qué tenés pendiente?", text: $viewModel.input)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(LumaPalette.ink)
                .onSubmit(save)

            if viewModel.saved {
                Label("Guardado. Yo lo acomodo.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.sage)
            }

            if let topPriority {
                VStack(alignment: .leading, spacing: 7) {
                    Text("AHORA CONVIENE")
                        .font(.caption2.weight(.bold))
                        .tracking(1)
                        .foregroundStyle(LumaPalette.sage)
                    Text(topPriority.task.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                        .lineLimit(2)
                    HStack {
                        Text("\(topPriority.suggestedMinutes) min · \(topPriority.task.area.title)")
                            .font(.caption)
                            .foregroundStyle(LumaPalette.secondaryInk)
                        Spacer()
                        Button("Empezar") {
                            openWindow(id: "main")
                            NSApp.activate(ignoringOtherApps: true)
                            appState.startFocus(
                                for: topPriority.task.id,
                                durationMinutes: topPriority.suggestedMinutes
                            )
                        }
                        .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            }

            Divider()

            HStack {
                Button("Abrir Luma") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Guardar", action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.indigo)
                    .disabled(viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 350)
    }

    private func save() {
        guard !viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let draft = parser.parse(viewModel.input)
        let task = LumaTask(
            title: draft.title,
            area: draft.area,
            dueDate: draft.dueDate,
            deadline: draft.deadline,
            estimatedMinutes: draft.estimatedMinutes,
            energy: draft.energy,
            impact: draft.impact,
            academicWeight: nil,
            unlocksAnotherTask: draft.unlocksAnotherTask,
            notes: draft.notes
        )
        modelContext.insert(task)
        try? modelContext.save()
        try? calendarService.syncTask(task)
        appState.refreshPlan()
        viewModel.input = ""
        viewModel.saved = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            viewModel.saved = false
        }
    }
}
