import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SubjectsView: View {
    @Environment(AppState.self) private var appState
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @Query(sort: \LumaTask.createdAt, order: .reverse) private var tasks: [LumaTask]
    @Query(sort: \SubjectClassMeeting.updatedAt) private var classMeetings: [SubjectClassMeeting]
    @Query(sort: \AcademicRoutine.updatedAt) private var routines: [AcademicRoutine]
    @Query(sort: \AcademicExam.date) private var exams: [AcademicExam]

    @State private var viewModel = SubjectsViewModel()

    private var activeSubjects: [AcademicSubject] {
        viewModel.activeSubjects(from: subjects)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom) {
                        heading
                        Spacer(minLength: 16)
                        addButton
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        heading
                        addButton
                    }
                }

                if activeSubjects.isEmpty {
                    EmptyStateView(
                        symbol: "books.vertical.fill",
                        title: "Todavía no agregaste materias",
                        message: "Creá una materia para agrupar sus tareas y encontrar más rápido qué tenés pendiente."
                    )
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(activeSubjects) { subject in
                            SubjectTaskCard(
                                subject: subject,
                                tasks: tasks.filter { $0.academicSubjectID == subject.id },
                                meetings: classMeetings.filter { $0.subjectID == subject.id },
                                routines: routines.filter { $0.subjectID == subject.id },
                                exams: exams.filter { $0.subjectID == subject.id && !$0.isArchived },
                                onComplete: complete,
                                onEdit: { presentEditor(for: subject) },
                                onDelete: { viewModel.subjectToArchive = subject }
                            )
                        }
                    }
                }
            }
            .padding(30)
            .lumaScrollContent()
        }
        .lumaScrollSurface()
        .navigationTitle("Materias")
        .sheet(isPresented: Binding(
            get: { viewModel.editorPresented },
            set: { viewModel.editorPresented = $0 }
        ), onDismiss: { viewModel.editingSubject = nil }) {
            SubjectEditorView(
                subject: viewModel.editingSubject,
                meetings: classMeetings.filter { $0.subjectID == viewModel.editingSubject?.id }
            )
        }
        .alert(
            "¿Eliminar esta materia?",
            isPresented: Binding(
                get: { viewModel.subjectToArchive != nil },
                set: { if !$0 { viewModel.subjectToArchive = nil } }
            )
        ) {
            Button("Cancelar", role: .cancel) { viewModel.subjectToArchive = nil }
            Button("Eliminar", role: .destructive) {
                if let subject = viewModel.subjectToArchive { archive(subject) }
            }
        } message: {
            Text("La materia dejará de aparecer. Sus tareas seguirán guardadas, pero quedarán sin materia asignada.")
        }
    }

    private var heading: some View {
        SectionTitle(
            eyebrow: "Organización académica",
            title: "Materias",
            trailing: activeSubjects.count == 1 ? "1 materia" : "\(activeSubjects.count) materias"
        )
    }

    private var addButton: some View {
        Button { presentEditor(for: nil) } label: {
            Label("Agregar materia", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .tint(LumaPalette.indigo)
    }

    private func presentEditor(for subject: AcademicSubject?) {
        viewModel.editingSubject = subject
        viewModel.editorPresented = true
    }

    private func archive(_ subject: AcademicSubject) {
        for task in tasks where task.academicSubjectID == subject.id {
            task.academicSubjectID = nil
            task.subjectGradeItemID = nil
            task.academicWeight = nil
            task.grade = nil
            task.touch()
        }
        subject.isArchived = true
        subject.updatedAt = .now
        try? modelContext.save()
        viewModel.subjectToArchive = nil
    }

    private func complete(_ task: LumaTask) {
        task.markCompleted()
        try? modelContext.save()
        try? calendarService.syncTask(task)
        appState.refreshPlan()
        appState.registerUndo(message: "Tarea completada") {
            task.restore()
            try? modelContext.save()
            try? calendarService.syncTask(task)
            appState.refreshPlan()
        }
    }
}

private struct SubjectTaskCard: View {
    let subject: AcademicSubject
    let tasks: [LumaTask]
    let meetings: [SubjectClassMeeting]
    let routines: [AcademicRoutine]
    let exams: [AcademicExam]
    let onComplete: (LumaTask) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var pendingTasks: [LumaTask] {
        tasks
            .filter { !$0.isCompleted }
            .sorted {
                switch ($0.deadline, $1.deadline) {
                case let (lhs?, rhs?): return lhs < rhs
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return $0.createdAt > $1.createdAt
                }
            }
    }

    private var completedCount: Int {
        tasks.filter(\.isCompleted).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "book.closed.fill")
                    .font(.headline)
                    .foregroundStyle(LumaPalette.indigo)
                    .frame(width: 42, height: 42)
                    .background(LumaPalette.indigo.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text(subject.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(summaryText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(LumaPalette.secondaryInk)
                }

                Spacer(minLength: 8)

                Menu {
                    Button("Editar", systemImage: "pencil", action: onEdit)
                    Divider()
                    Button("Eliminar materia", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Divider().opacity(0.45)

            academicOverview

            if pendingTasks.isEmpty {
                Label("No hay tareas pendientes en esta materia", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LumaPalette.sage)
                    .padding(.vertical, 5)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(pendingTasks.prefix(4).enumerated()), id: \.element.id) { index, task in
                        HStack(spacing: 11) {
                            Button {
                                onComplete(task)
                            } label: {
                                Image(systemName: "circle")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(LumaPalette.indigo)
                            }
                            .buttonStyle(.plain)
                            .help("Marcar como completada")
                            Text(task.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(LumaPalette.ink)
                                .lineLimit(2)
                            Spacer(minLength: 10)
                            VStack(alignment: .trailing, spacing: 2) {
                                if let deadline = task.deadline {
                                    Text(deadline, format: .dateTime.day().month(.abbreviated))
                                } else {
                                    Text("Sin fecha")
                                }
                                Text("\(task.estimatedMinutes) min")
                            }
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(LumaPalette.secondaryInk)
                        }
                        .padding(.vertical, 9)

                        if index < min(pendingTasks.count, 4) - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }

                if pendingTasks.count > 4 {
                    Text("Y \(pendingTasks.count - 4) tareas más en el Inbox")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LumaPalette.indigo)
                }
            }
        }
        .lumaCard(padding: 18)
    }

    private var academicOverview: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { overviewItems }
            VStack(alignment: .leading, spacing: 9) { overviewItems }
        }
        .font(.caption)
        .foregroundStyle(LumaPalette.secondaryInk)
    }

    @ViewBuilder
    private var overviewItems: some View {
        if meetings.isEmpty {
            Label("Sin horario cargado", systemImage: "calendar.badge.plus")
        } else {
            Label(meetings.map(meetingLabel).joined(separator: " · "), systemImage: "calendar")
        }
        if let nextExam = exams.filter({ $0.date >= .now }).min(by: { $0.date < $1.date }) {
            Label("Próximo examen: \(nextExam.date.formatted(.dateTime.day().month(.abbreviated)))", systemImage: "graduationcap.fill")
        }
        if !routines.isEmpty {
            Label("\(routines.count) \(routines.count == 1 ? "rutina" : "rutinas")", systemImage: "arrow.triangle.2.circlepath")
        }
        if !subject.syllabusTopics.isEmpty {
            Label("\(subject.syllabusTopics.count) temas", systemImage: "list.bullet.rectangle")
        }
        let studyTasks = tasks.filter { $0.academicSourceType == .examStudy }
        if !studyTasks.isEmpty {
            let completed = studyTasks.filter(\.isCompleted).count
            Label("Estudio \(completed)/\(studyTasks.count)", systemImage: "chart.line.uptrend.xyaxis")
        }
    }

    private func meetingLabel(_ meeting: SubjectClassMeeting) -> String {
        let weekdays = ["", "Dom", "Lun", "Mar", "Mié", "Jue", "Vie", "Sáb"]
        let date = Calendar.current.date(bySettingHour: meeting.startMinuteOfDay / 60, minute: meeting.startMinuteOfDay % 60, second: 0, of: .now) ?? .now
        return "\(weekdays[max(1, min(7, meeting.weekday))]) \(date.formatted(date: .omitted, time: .shortened))"
    }

    private var summaryText: String {
        let pending = pendingTasks.count == 1 ? "1 pendiente" : "\(pendingTasks.count) pendientes"
        guard completedCount > 0 else { return pending }
        return "\(pending) · \(completedCount) completadas"
    }
}

private struct SubjectEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(LocalAIEngine.self) private var aiEngine
    @Query private var allSubjects: [AcademicSubject]
    @Query private var allMeetings: [SubjectClassMeeting]

    let subject: AcademicSubject?
    let meetings: [SubjectClassMeeting]
    @State private var viewModel: SubjectEditorViewModel

    init(subject: AcademicSubject?, meetings: [SubjectClassMeeting]) {
        self.subject = subject
        self.meetings = meetings
        _viewModel = State(initialValue: SubjectEditorViewModel(subject: subject, meetings: meetings))
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(subject == nil ? "Nueva materia" : "Editar materia")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                    Text("Usala para agrupar pendientes, exámenes y sesiones de estudio.")
                        .font(.subheadline)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Nombre")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.secondaryInk)
                TextField("Ej. Economía", text: $viewModel.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.weight(.medium))
                if viewModel.hasDuplicateName(subject: subject, allSubjects: allSubjects) {
                    Text("Ya existe una materia con este nombre.")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.terracotta)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.secondaryInk)
                HStack(spacing: 9) {
                    ForEach(subjectColors, id: \.self) { hex in
                        Button {
                            viewModel.colorHex = hex
                        } label: {
                            Circle()
                                .fill(color(for: hex))
                                .frame(width: 24, height: 24)
                                .overlay {
                                    if viewModel.colorHex == hex {
                                        Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Temario de la materia")
                            .font(.headline)
                            .foregroundStyle(LumaPalette.ink)
                        Text("Subí el PDF una sola vez. Después elegís qué temas entran en cada examen.")
                            .font(.caption)
                            .foregroundStyle(LumaPalette.secondaryInk)
                    }
                    Spacer()
                    Button {
                        viewModel.isPDFImporterPresented = true
                    } label: {
                        Label(viewModel.hasSyllabusPDF ? "Reemplazar PDF" : "Subir PDF", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .tint(LumaPalette.indigo)
                    .disabled(viewModel.isProcessingPDF || aiEngine.state.isBusy)
                }

                if viewModel.isProcessingPDF {
                    VStack(alignment: .leading, spacing: 7) {
                        ProgressView(value: viewModel.processingProgress)
                            .tint(LumaPalette.indigo)
                        Text(viewModel.processingStage)
                            .font(.caption)
                            .foregroundStyle(LumaPalette.secondaryInk)
                    }
                } else if viewModel.hasSyllabusPDF {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(LumaPalette.indigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.syllabusSourceFileName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text("\(viewModel.syllabusPageCount) páginas · \(viewModel.syllabusStructureSummary)")
                                .font(.caption2)
                                .foregroundStyle(LumaPalette.secondaryInk)
                        }
                        Spacer()
                        Button("Quitar") { viewModel.clearSyllabus() }
                            .buttonStyle(.plain)
                            .foregroundStyle(LumaPalette.terracotta)
                    }
                    .padding(10)
                    .background(LumaPalette.indigo.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
                }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $viewModel.syllabusRaw)
                        .font(.body)
                        .foregroundStyle(LumaPalette.ink)
                        .scrollContentBackground(.hidden)
                        .padding(8)

                    if viewModel.syllabusRaw.isEmpty {
                        Text("Un tema por línea")
                            .font(.body)
                            .foregroundStyle(LumaPalette.secondaryInk.opacity(0.72))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 96, idealHeight: 112, maxHeight: 150)
                .background(Color.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(LumaPalette.secondaryInk.opacity(0.18), lineWidth: 1)
                }

                if !viewModel.pdfMessage.isEmpty {
                    Text(viewModel.pdfMessage)
                        .font(.caption)
                        .foregroundStyle(viewModel.resolvedSyllabusTopics().isEmpty ? LumaPalette.terracotta : LumaPalette.sage)
                }

                if viewModel.canAnalyzeImportedPDF,
                   !viewModel.isProcessingPDF,
                   !aiEngine.isInstalled,
                   !aiEngine.isStudyModelInstalled
                {
                    Button {
                        Task {
                            await aiEngine.install()
                            await viewModel.analyzeImportedPDF(using: aiEngine)
                        }
                    } label: {
                        Label("Preparar IA y detectar temas", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.indigo)
                    .disabled(aiEngine.state.isBusy)
                }
            }
            .padding(15)
            .background(Color.white.opacity(0.50), in: RoundedRectangle(cornerRadius: 15))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Horario semanal")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LumaPalette.secondaryInk)
                        Text("Agregá cada día por separado; las horas pueden ser distintas.")
                            .font(.caption2)
                            .foregroundStyle(LumaPalette.secondaryInk)
                    }
                    Spacer()
                    Button("Agregar clase", systemImage: "plus") { viewModel.addMeeting() }
                        .buttonStyle(.bordered)
                        .tint(LumaPalette.indigo)
                }

                if viewModel.meetings.isEmpty {
                    Label(
                        "Sin clases cargadas. Por ejemplo: lunes, miércoles y viernes.",
                        systemImage: "calendar.badge.plus"
                    )
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
                    .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    LazyVStack(spacing: 9) {
                        ForEach($viewModel.meetings) { $meeting in
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack {
                                        Label("Clase semanal", systemImage: "calendar")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(LumaPalette.indigo)
                                        Spacer()
                                        Button(role: .destructive) {
                                            viewModel.removeMeeting(id: meeting.id)
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.plain)
                                        .help("Eliminar este horario")
                                    }

                                    HStack(spacing: 9) {
                                        Picker("Día", selection: $meeting.weekday) {
                                            Text("Domingo").tag(1); Text("Lunes").tag(2); Text("Martes").tag(3); Text("Miércoles").tag(4)
                                            Text("Jueves").tag(5); Text("Viernes").tag(6); Text("Sábado").tag(7)
                                        }
                                        .frame(width: 150)
                                        Text("de").font(.caption).foregroundStyle(LumaPalette.secondaryInk)
                                        DatePicker("Inicio", selection: meetingTimeBinding($meeting.startMinuteOfDay), displayedComponents: [.hourAndMinute])
                                            .labelsHidden()
                                        Text("a").font(.caption).foregroundStyle(LumaPalette.secondaryInk)
                                        DatePicker("Fin", selection: meetingTimeBinding($meeting.endMinuteOfDay), displayedComponents: [.hourAndMinute])
                                            .labelsHidden()
                                        TextField("Aula opcional", text: $meeting.location)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(minWidth: 120)
                                    }

                                    if meeting.endMinuteOfDay <= meeting.startMinuteOfDay {
                                        Text("La hora de fin debe ser posterior al inicio.")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(LumaPalette.terracotta)
                                    }
                                }
                                .padding(11)
                                .background(Color.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }

            HStack(spacing: 14) {
                Image(systemName: "books.vertical.fill")
                    .font(.title3)
                    .foregroundStyle(LumaPalette.sage)
                    .frame(width: 44, height: 44)
                    .background(LumaPalette.sage.opacity(0.10), in: Circle())
                Text("Después vas a poder asignar cualquier tarea universitaria a esta materia.")
                    .font(.subheadline)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .lumaCard(padding: 15)

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Guardar materia") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.indigo)
                    .disabled(!viewModel.canSave(subject: subject, allSubjects: allSubjects))
            }
        }
        }
        .padding(24)
        .background(LumaBackground())
        .frame(width: 780, height: 740)
        .fileImporter(
            isPresented: $viewModel.isPDFImporterPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            Task { await viewModel.importPDF(result, using: aiEngine) }
        }
    }

    private func save() {
        guard viewModel.canSave(subject: subject, allSubjects: allSubjects) else { return }
        let now = Date.now

        let savedSubject: AcademicSubject
        if let subject {
            subject.name = viewModel.trimmedName
            subject.colorHex = viewModel.colorHex
            subject.updateSyllabus(
                topics: viewModel.resolvedSyllabusTopics(),
                sourceFileName: viewModel.syllabusSourceFileName,
                pageCount: viewModel.syllabusPageCount
            )
            subject.updatedAt = now
            savedSubject = subject
        } else {
            let created = AcademicSubject(
                name: viewModel.trimmedName,
                targetGrade: nil,
                colorHex: viewModel.colorHex,
                createdAt: now,
                updatedAt: now
            )
            created.updateSyllabus(
                topics: viewModel.resolvedSyllabusTopics(),
                sourceFileName: viewModel.syllabusSourceFileName,
                pageCount: viewModel.syllabusPageCount
            )
            modelContext.insert(created)
            savedSubject = created
        }

        let retained = Set(viewModel.meetings.map(\.id))
        let removedMeetingIDs = allMeetings.filter { $0.subjectID == savedSubject.id && !retained.contains($0.id) }.map(\.id)
        for existing in allMeetings where existing.subjectID == savedSubject.id && !retained.contains(existing.id) {
            modelContext.delete(existing)
        }
        for draft in viewModel.meetings {
            if let existing = allMeetings.first(where: { $0.id == draft.id }) {
                existing.weekday = draft.weekday
                existing.startMinuteOfDay = draft.startMinuteOfDay
                existing.endMinuteOfDay = max(draft.startMinuteOfDay + 15, draft.endMinuteOfDay)
                existing.location = draft.location
                existing.updatedAt = now
            } else {
                modelContext.insert(SubjectClassMeeting(
                    id: draft.id,
                    subjectID: savedSubject.id,
                    weekday: draft.weekday,
                    startMinuteOfDay: draft.startMinuteOfDay,
                    endMinuteOfDay: max(draft.startMinuteOfDay + 15, draft.endMinuteOfDay),
                    location: draft.location,
                    createdAt: now,
                    updatedAt: now
                ))
            }
        }
        do {
            try modelContext.save()
            for id in removedMeetingIDs { CloudSyncService.queueDeletion(table: "subject_class_meetings", id: id) }
        } catch {
            modelContext.rollback()
            viewModel.pdfMessage = "No pude guardar los cambios. Tus datos siguen en el formulario."
            return
        }
        #if DEBUG
        let source = viewModel.syllabusSourceFileName.isEmpty ? "manual" : viewModel.syllabusSourceFileName
        print("✅ [TEMARIO-MATERIA] Guardado | materia=\(savedSubject.name) | fuente=\(source) | temas=\(savedSubject.syllabusTopics.count) | horarios=\(viewModel.meetings.count)")
        #endif
        dismiss()
    }

    private let subjectColors = ["#59639A", "#6F9C86", "#C77761", "#D9A640", "#9C8BC4", "#C8799B"]

    private func color(for hex: String) -> Color {
        switch hex {
        case "#6F9C86": LumaPalette.sage
        case "#C77761": LumaPalette.terracotta
        case "#D9A640": LumaPalette.mustard
        case "#9C8BC4": LumaPalette.lavender
        case "#C8799B": LumaPalette.rose
        default: LumaPalette.indigo
        }
    }

    private func meetingTimeBinding(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minute.wrappedValue / 60, minute: minute.wrappedValue % 60, second: 0, of: .now) ?? .now },
            set: { minute.wrappedValue = Calendar.current.component(.hour, from: $0) * 60 + Calendar.current.component(.minute, from: $0) }
        )
    }
}
