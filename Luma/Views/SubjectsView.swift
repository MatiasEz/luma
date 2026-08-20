import SwiftData
import SwiftUI

struct SubjectsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @Query(sort: \SubjectGradeItem.createdAt) private var gradeItems: [SubjectGradeItem]
    @Query(sort: \LumaTask.createdAt, order: .reverse) private var tasks: [LumaTask]

    @State private var editorPresented = false
    @State private var editingSubject: AcademicSubject?
    @State private var subjectToArchive: AcademicSubject?
    @State private var gradeDetailSubject: AcademicSubject?

    private var activeSubjects: [AcademicSubject] {
        subjects.filter { !$0.isArchived }
    }

    private var activeItems: [SubjectGradeItem] {
        gradeItems.filter { !$0.isArchived }
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

                explanationCard

                if activeSubjects.isEmpty {
                    EmptyStateView(
                        symbol: "books.vertical.fill",
                        title: "Todavía no agregaste materias",
                        message: "Creá una materia y anotá cuánto vale cada examen, tarea, asistencia o proyecto."
                    )
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                        ForEach(activeSubjects) { subject in
                            SubjectCard(
                                subject: subject,
                                items: items(for: subject),
                                tasks: tasks.filter { $0.academicSubjectID == subject.id },
                                onShowGradeDetail: { gradeDetailSubject = subject },
                                onEdit: { presentEditor(for: subject) },
                                onArchive: { subjectToArchive = subject }
                            )
                        }
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle("Materias")
        .sheet(isPresented: $editorPresented, onDismiss: { editingSubject = nil }) {
            SubjectEditorView(
                subject: editingSubject,
                existingItems: editingSubject.map { items(for: $0) } ?? []
            )
        }
        .sheet(item: $gradeDetailSubject) { subject in
            SubjectGradeDetailView(
                subject: subject,
                items: items(for: subject),
                tasks: tasks.filter { $0.academicSubjectID == subject.id }
            )
        }
        .alert(
            "¿Eliminar esta materia?",
            isPresented: Binding(
                get: { subjectToArchive != nil },
                set: { if !$0 { subjectToArchive = nil } }
            )
        ) {
            Button("Cancelar", role: .cancel) { subjectToArchive = nil }
            Button("Eliminar", role: .destructive) {
                if let subjectToArchive { archive(subjectToArchive) }
            }
        } message: {
            Text("La materia y sus porcentajes dejarán de aparecer en Luma.")
        }
    }

    private var heading: some View {
        SectionTitle(
            eyebrow: "Organización académica",
            title: "Materias y ponderaciones",
            trailing: activeSubjects.count == 1 ? "1 materia" : "\(activeSubjects.count) materias"
        )
    }

    private var addButton: some View {
        Button {
            presentEditor(for: nil)
        } label: {
            Label("Agregar materia", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .tint(LumaPalette.indigo)
    }

    private var explanationCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "percent")
                .font(.title3.weight(.semibold))
                .foregroundStyle(LumaPalette.indigo)
                .frame(width: 44, height: 44)
                .background(LumaPalette.indigo.opacity(0.11), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text("Anotá cómo se compone cada nota")
                    .font(.headline)
                    .foregroundStyle(LumaPalette.ink)
                Text("Podés guardar una materia aunque todavía no llegue al 100%. Luma te muestra cuánto falta completar.")
                    .font(.subheadline)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .lumaCard(padding: 16)
    }

    private func items(for subject: AcademicSubject) -> [SubjectGradeItem] {
        activeItems.filter { $0.subjectID == subject.id }
    }

    private func presentEditor(for subject: AcademicSubject?) {
        editingSubject = subject
        editorPresented = true
    }

    private func archive(_ subject: AcademicSubject) {
        let now = Date.now
        subject.isArchived = true
        subject.updatedAt = now
        items(for: subject).forEach {
            $0.isArchived = true
            $0.updatedAt = now
        }
        try? modelContext.save()
        subjectToArchive = nil
    }
}

private struct SubjectCard: View {
    let subject: AcademicSubject
    let items: [SubjectGradeItem]
    let tasks: [LumaTask]
    let onShowGradeDetail: () -> Void
    let onEdit: () -> Void
    let onArchive: () -> Void

    private var total: Double {
        items.reduce(0) { $0 + $1.weightPercent }
    }

    private var remaining: Double {
        max(0, 100 - total)
    }

    private var progressColor: Color {
        total > 100 ? LumaPalette.terracotta : (total == 100 ? LumaPalette.sage : LumaPalette.indigo)
    }

    private var gradeSummary: SubjectGradeSummary {
        SubjectGradeCalculator.makeSummary(items: items, tasks: tasks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "book.closed.fill")
                    .font(.headline)
                    .foregroundStyle(LumaPalette.indigo)
                    .frame(width: 38, height: 38)
                    .background(LumaPalette.indigo.opacity(0.11), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(subject.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let target = subject.targetGrade {
                        Label("Objetivo \(grade(target)) / 10", systemImage: "target")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(LumaPalette.sage)
                    }
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Editar", systemImage: "pencil", action: onEdit)
                    Divider()
                    Button("Eliminar materia", systemImage: "trash", role: .destructive, action: onArchive)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if items.isEmpty {
                Text("Sin ítems todavía")
                    .font(.subheadline)
                    .foregroundStyle(LumaPalette.secondaryInk)
            } else {
                VStack(spacing: 9) {
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(LumaPalette.lavender)
                                .frame(width: 7, height: 7)
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(LumaPalette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text("\(percentage(item.weightPercent))%")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(LumaPalette.indigo)
                        }
                    }
                }
            }

            if !items.isEmpty {
                Divider().opacity(0.55)
                gradeOverview
            }

            if !tasks.isEmpty {
                Divider().opacity(0.55)

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("TAREAS ASIGNADAS")
                            .font(.caption2.weight(.bold))
                            .tracking(0.8)
                            .foregroundStyle(LumaPalette.sage)
                        Spacer()
                        Text("\(tasks.count)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(LumaPalette.secondaryInk)
                    }

                    ForEach(Array(tasks.prefix(4))) { task in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(task.isCompleted ? LumaPalette.sage : LumaPalette.secondaryInk)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(LumaPalette.ink)
                                    .lineLimit(1)
                                if let category = categoryName(for: task) {
                                    Text(category)
                                        .font(.caption2)
                                        .foregroundStyle(LumaPalette.secondaryInk)
                                }
                            }
                            Spacer(minLength: 6)
                            Text(gradeLabel(for: task))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(task.grade.map { $0 >= 6 } == true ? LumaPalette.sage : LumaPalette.secondaryInk)
                        }
                    }

                    if tasks.count > 4 {
                        Text("Y \(tasks.count - 4) más en el Inbox")
                            .font(.caption2)
                            .foregroundStyle(LumaPalette.secondaryInk)
                    }
                }
            }

            Divider().opacity(0.55)

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: min(total, 100), total: 100)
                    .tint(progressColor)
                HStack {
                    Text("Total: \(percentage(total))%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(LumaPalette.ink)
                    Spacer()
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(progressColor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .lumaCard(padding: 16)
    }

    private var gradeOverview: some View {
        Button(action: onShowGradeDetail) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("NOTA DE LA MATERIA")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(LumaPalette.indigo)
                    Spacer()
                    Text("Ver detalle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LumaPalette.indigo)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(LumaPalette.indigo)
                }

                if let currentGrade = gradeSummary.currentGrade {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nota actual")
                                .font(.caption2)
                                .foregroundStyle(LumaPalette.secondaryInk)
                            Text("\(grade(currentGrade)) / 10")
                                .font(.title3.weight(.bold).monospacedDigit())
                                .foregroundStyle(LumaPalette.ink)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Peso con notas")
                                .font(.caption2)
                                .foregroundStyle(LumaPalette.secondaryInk)
                            Text("\(percentage(gradeSummary.gradedWeight))%")
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(LumaPalette.sage)
                        }
                    }
                    Text("Aporte ponderado actual: \(grade(gradeSummary.weightedContribution)) / 10")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                } else {
                    Text("Todavía no hay notas cargadas")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                    Text("Cuando califiques una tarea, vas a ver acá la nota actual y su aporte a la final.")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if gradeSummary.pendingGradeTaskCount > 0 {
                    Label(
                        gradeSummary.pendingGradeTaskCount == 1
                            ? "1 evaluación espera nota"
                            : "\(gradeSummary.pendingGradeTaskCount) evaluaciones esperan nota",
                        systemImage: "clock.badge.questionmark"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.indigo)
                }

                if let objectiveText {
                    Text(objectiveText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(objectiveColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(LumaPalette.indigo.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
    }

    private var statusText: String {
        if total > 100 { return "Excede \(percentage(total - 100))%" }
        if total == 100 { return "Completo" }
        return "Falta \(percentage(remaining))%"
    }

    private var objectiveText: String? {
        guard let target = subject.targetGrade else { return nil }
        if let current = gradeSummary.currentGrade, current >= target {
            return "Vas por encima del objetivo de \(grade(target))."
        }
        guard let required = gradeSummary.requiredAverage(for: target) else {
            return "Objetivo: \(grade(target)). Completá categorías y evaluaciones para calcular qué necesitás."
        }
        if required > 10 {
            return "Con las evaluaciones cargadas, el objetivo de \(grade(target)) ya no es alcanzable."
        }
        if required <= 0 {
            return "El objetivo de \(grade(target)) ya está asegurado."
        }
        return "Necesitás aproximadamente \(grade(required)) en lo pendiente."
    }

    private var objectiveColor: Color {
        guard let target = subject.targetGrade else { return LumaPalette.secondaryInk }
        if let current = gradeSummary.currentGrade, current >= target { return LumaPalette.sage }
        if let required = gradeSummary.requiredAverage(for: target), required > 10 { return LumaPalette.terracotta }
        return LumaPalette.indigo
    }

    private func percentage(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }

    private func grade(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }

    private func categoryName(for task: LumaTask) -> String? {
        guard let id = task.subjectGradeItemID else { return nil }
        return items.first { $0.id == id }?.title
    }

    private func gradeLabel(for task: LumaTask) -> String {
        switch task.academicEvaluationStatus {
        case .graded:
            guard let grade = task.grade else { return "Calificada" }
            return "\(grade.formatted(.number.precision(.fractionLength(0 ... 2)))) / 10"
        case .pendingGrade: return "Pendiente"
        case .notEvaluable: return "No evaluable"
        case nil: return "Sin materia"
        }
    }
}

private struct SubjectGradeDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let subject: AcademicSubject
    let items: [SubjectGradeItem]
    let tasks: [LumaTask]

    @State private var simulatorPresented = false

    private var summary: SubjectGradeSummary {
        SubjectGradeCalculator.makeSummary(items: items, tasks: tasks)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("DETALLE DE LA NOTA")
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(LumaPalette.sage)
                    Text(subject.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                }
                Spacer()
                if !tasks.filter({ $0.academicEvaluationStatus == .pendingGrade }).isEmpty {
                    Button {
                        simulatorPresented = true
                    } label: {
                        Label("Simular notas", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.indigo)
                }
                Button("Cerrar") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(24)

            Divider().opacity(0.55)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    gradeSummaryCard

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Desglose por categoría")
                            .font(.headline)
                            .foregroundStyle(LumaPalette.ink)

                        if summary.categories.isEmpty {
                            Text("Esta materia todavía no tiene categorías configuradas.")
                                .font(.subheadline)
                                .foregroundStyle(LumaPalette.secondaryInk)
                                .lumaCard(padding: 16)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(summary.categories.enumerated()), id: \.element.id) { index, category in
                                    categoryRow(category)
                                    if index < summary.categories.count - 1 {
                                        Divider().opacity(0.45)
                                    }
                                }
                            }
                            .lumaCard(padding: 0)
                        }
                    }

                    projectionCard
                }
                .padding(24)
            }
        }
        .background(LumaBackground())
        .frame(width: 700, height: 650)
        .sheet(isPresented: $simulatorPresented) {
            GradeSimulatorView(subject: subject, items: items, tasks: tasks)
        }
    }

    private var gradeSummaryCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                metric(
                    title: "Nota actual",
                    value: summary.currentGrade.map { "\(grade($0)) / 10" } ?? "Sin notas",
                    detail: "Sobre las categorías calificadas",
                    color: LumaPalette.indigo
                )
                metric(
                    title: "Aporte actual",
                    value: "\(grade(summary.weightedContribution)) / 10",
                    detail: "Aplicando las ponderaciones",
                    color: LumaPalette.sage
                )
                metric(
                    title: "Peso con notas",
                    value: "\(percentage(summary.gradedWeight))%",
                    detail: summary.gradedTaskCount == 1
                        ? "1 nota cargada"
                        : "\(summary.gradedTaskCount) notas cargadas",
                    color: LumaPalette.lavender
                )
            }

            Text("La nota actual considera solo las categorías que ya tienen calificaciones. El aporte actual muestra cuánto suman hoy esas notas dentro del resultado final.")
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            if summary.pendingGradeTaskCount > 0 {
                Label(
                    summary.pendingGradeTaskCount == 1
                        ? "1 evaluación tiene la nota pendiente y no se cuenta como cero."
                        : "\(summary.pendingGradeTaskCount) evaluaciones tienen la nota pendiente y no se cuentan como cero.",
                    systemImage: "clock.badge.questionmark"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(LumaPalette.indigo)
            }

            if summary.nonEvaluableTaskCount > 0 {
                Text(summary.nonEvaluableTaskCount == 1
                    ? "También hay 1 tarea de organización que no afecta la nota."
                    : "También hay \(summary.nonEvaluableTaskCount) tareas de organización que no afectan la nota.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
        }
        .lumaCard(padding: 16)
    }

    private func metric(
        title: String,
        value: String,
        detail: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LumaPalette.secondaryInk)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(LumaPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(LumaPalette.secondaryInk)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .padding(13)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
    }

    private func categoryRow(_ category: SubjectGradeCategorySummary) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(category.averageGrade == nil ? LumaPalette.secondaryInk.opacity(0.28) : LumaPalette.lavender)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(category.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                Text(categoryTaskDescription(category))
                    .font(.caption2)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text("Vale \(percentage(category.weightPercent))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(LumaPalette.indigo)
                if let average = category.averageGrade {
                    Text("Promedio \(grade(average)) · aporta \(grade(category.weightedContribution))")
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(LumaPalette.sage)
                } else {
                    Text("Sin notas")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var projectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Proyección", systemImage: "chart.line.uptrend.xyaxis")
                .font(.headline)
                .foregroundStyle(LumaPalette.ink)

            if let projection = summary.projectedFinalGrade {
                Text("Si mantenés el rendimiento actual, la proyección es \(grade(projection)) / 10.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
            } else if summary.unconfiguredWeight > 0 {
                Text("Completá el \(percentage(summary.unconfiguredWeight))% que falta configurar para calcular una proyección final.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
            } else {
                Text("Cargá al menos una nota para calcular una proyección final.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
            }

            if let target = subject.targetGrade {
                Divider().opacity(0.45)
                Label("Objetivo: \(grade(target)) / 10", systemImage: "target")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.sage)

                if let required = summary.requiredAverage(for: target) {
                    if required > 10 {
                        Text("Con las evaluaciones pendientes actuales, ese objetivo ya no es alcanzable. Probá distintos escenarios para ver el mejor resultado posible.")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LumaPalette.terracotta)
                    } else if required <= 0 {
                        Text("El objetivo ya está asegurado con las notas cargadas.")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LumaPalette.sage)
                    } else {
                        Text("Necesitás un promedio aproximado de \(grade(required)) en las evaluaciones pendientes.")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LumaPalette.indigo)
                    }
                } else if summary.pendingGradeTaskCount > 0 {
                    Text("Para calcular qué nota necesitás, completá la ponderación y asigná al menos una evaluación a cada categoría.")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
            } else {
                Text("Podés definir un objetivo desde Editar materia para saber qué notas necesitás.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }

            if summary.configuredWithoutGradesWeight > 0 {
                Text("Categorías todavía sin notas: \(percentage(summary.configuredWithoutGradesWeight))% de la materia.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
        }
        .lumaCard(padding: 16)
    }

    private func categoryTaskDescription(_ category: SubjectGradeCategorySummary) -> String {
        if category.assignedTaskCount == 0 { return "Sin tareas asignadas" }
        let assigned = category.assignedTaskCount == 1
            ? "1 tarea"
            : "\(category.assignedTaskCount) tareas"
        let graded = category.gradedTaskCount == 1
            ? "1 calificada"
            : "\(category.gradedTaskCount) calificadas"
        let pending = category.pendingGradeTaskCount == 1
            ? "1 pendiente"
            : "\(category.pendingGradeTaskCount) pendientes"
        return category.pendingGradeTaskCount > 0
            ? "\(assigned) · \(graded) · \(pending)"
            : "\(assigned) · \(graded)"
    }

    private func percentage(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }

    private func grade(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }
}

private struct GradeSimulatorView: View {
    @Environment(\.dismiss) private var dismiss

    let subject: AcademicSubject
    let items: [SubjectGradeItem]
    let tasks: [LumaTask]

    @State private var simulatedGrades: [UUID: Double] = [:]

    private var pendingTasks: [LumaTask] {
        tasks.filter { $0.academicEvaluationStatus == .pendingGrade }
    }

    private var actualSummary: SubjectGradeSummary {
        SubjectGradeCalculator.makeSummary(items: items, tasks: tasks)
    }

    private var simulatedSummary: SubjectGradeSummary {
        SubjectGradeCalculator.makeSummary(
            items: items,
            tasks: tasks,
            simulatedGrades: simulatedGrades
        )
    }

    private var allSimulated: Bool {
        !pendingTasks.isEmpty && pendingTasks.allSatisfy { simulatedGrades[$0.id] != nil }
    }

    private var valuesAreValid: Bool {
        simulatedGrades.values.allSatisfy { (0 ... 10).contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SIMULADOR")
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(LumaPalette.sage)
                    Text(subject.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                    Text("Probá notas sin modificar tus datos reales.")
                        .font(.subheadline)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                Button("Cerrar") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(24)

            Divider().opacity(0.55)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    resultCard

                    if pendingTasks.isEmpty {
                        EmptyStateView(
                            symbol: "checkmark.seal.fill",
                            title: "No hay evaluaciones pendientes",
                            message: "Agregá una evaluación sin nota para poder probar escenarios."
                        )
                    } else {
                        HStack {
                            Text("Notas posibles")
                                .font(.headline)
                                .foregroundStyle(LumaPalette.ink)
                            Spacer()
                            if let target = subject.targetGrade,
                               let required = actualSummary.requiredAverage(for: target),
                               (0 ... 10).contains(required)
                            {
                                Button("Usar nota necesaria") {
                                    for task in pendingTasks { simulatedGrades[task.id] = required }
                                }
                                .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
                            }
                        }

                        VStack(spacing: 0) {
                            ForEach(Array(pendingTasks.enumerated()), id: \.element.id) { index, task in
                                simulatorRow(task)
                                if index < pendingTasks.count - 1 { Divider().opacity(0.45) }
                            }
                        }
                        .lumaCard(padding: 0)
                    }
                }
                .padding(24)
            }

            HStack {
                Label("La simulación no cambia las notas guardadas", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
                Spacer()
                Button("Limpiar") { simulatedGrades.removeAll() }
                    .buttonStyle(.bordered)
                    .disabled(simulatedGrades.isEmpty)
            }
            .padding(24)
        }
        .background(LumaBackground())
        .frame(width: 680, height: 640)
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                simulatorMetric(
                    title: "Nota actual",
                    value: actualSummary.currentGrade.map { "\(grade($0)) / 10" } ?? "Sin notas"
                )
                simulatorMetric(
                    title: allSimulated ? "Final simulado" : "Escenario",
                    value: scenarioGrade.map { "\(grade($0)) / 10" } ?? "Completá notas"
                )
                simulatorMetric(
                    title: "Objetivo",
                    value: subject.targetGrade.map { "\(grade($0)) / 10" } ?? "Sin definir"
                )
            }

            Text(resultMessage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(resultColor)
                .fixedSize(horizontal: false, vertical: true)

            if !valuesAreValid {
                Text("Las notas deben estar entre 0 y 10.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.terracotta)
            }
        }
        .lumaCard(padding: 16)
    }

    private var scenarioGrade: Double? {
        guard valuesAreValid, !simulatedGrades.isEmpty else { return nil }
        if allSimulated, let final = simulatedSummary.finalGrade { return final }
        return simulatedSummary.currentGrade
    }

    private var resultMessage: String {
        guard let scenarioGrade else {
            return "Ingresá una o más notas para ver cómo cambiaría el resultado."
        }
        guard let target = subject.targetGrade else {
            return "Con este escenario, la nota estimada sería \(grade(scenarioGrade))."
        }
        if scenarioGrade >= target {
            return "Este escenario alcanza el objetivo de \(grade(target))."
        }
        return "Este escenario queda a \(grade(target - scenarioGrade)) puntos del objetivo."
    }

    private var resultColor: Color {
        guard let scenarioGrade, let target = subject.targetGrade else { return LumaPalette.indigo }
        return scenarioGrade >= target ? LumaPalette.sage : LumaPalette.terracotta
    }

    private func simulatorMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(LumaPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(LumaPalette.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func simulatorRow(_ task: LumaTask) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                Text(categoryName(for: task))
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
            Spacer(minLength: 12)
            TextField(
                "Nota",
                value: simulatedGradeBinding(for: task.id),
                format: .number.precision(.fractionLength(0 ... 2))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 100)
            Text("/ 10")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LumaPalette.secondaryInk)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func simulatedGradeBinding(for taskID: UUID) -> Binding<Double?> {
        Binding(
            get: { simulatedGrades[taskID] },
            set: { simulatedGrades[taskID] = $0 }
        )
    }

    private func categoryName(for task: LumaTask) -> String {
        guard let itemID = task.subjectGradeItemID,
              let item = items.first(where: { $0.id == itemID })
        else { return "Evaluación" }
        return "\(item.title) · vale \(item.weightPercent.formatted(.number.precision(.fractionLength(0 ... 2))))%"
    }

    private func grade(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }
}

private struct SubjectEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allSubjects: [AcademicSubject]

    let subject: AcademicSubject?
    let existingItems: [SubjectGradeItem]

    @State private var name: String
    @State private var targetGrade: Double?
    @State private var drafts: [GradeItemDraft]

    init(subject: AcademicSubject?, existingItems: [SubjectGradeItem]) {
        self.subject = subject
        self.existingItems = existingItems
        _name = State(initialValue: subject?.name ?? "")
        _targetGrade = State(initialValue: subject?.targetGrade)
        _drafts = State(initialValue: existingItems.isEmpty && subject == nil
            ? [GradeItemDraft()]
            : existingItems.map(GradeItemDraft.init))
    }

    private var parsedItems: [(draft: GradeItemDraft, weight: Double)]? {
        var result: [(GradeItemDraft, Double)] = []
        for draft in drafts {
            let normalized = draft.weightText.replacingOccurrences(of: ",", with: ".")
            guard !draft.trimmedTitle.isEmpty,
                  let weight = Double(normalized),
                  weight > 0,
                  weight <= 100
            else { return nil }
            result.append((draft, weight))
        }
        return result
    }

    private var total: Double {
        parsedItems?.reduce(0) { $0 + $1.weight } ?? 0
    }

    private var hasDuplicateName: Bool {
        allSubjects.contains {
            !$0.isArchived
                && $0.id != subject?.id
                && $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }
    }

    private var canSave: Bool {
        !trimmedName.isEmpty
            && !hasDuplicateName
            && !drafts.isEmpty
            && parsedItems != nil
            && total <= 100
            && targetGrade.map { (0 ... 10).contains($0) } != false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(subject == nil ? "Nueva materia" : "Editar materia")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                    Text("Definí qué parte de la nota representa cada ítem.")
                        .font(.subheadline)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                Button("Cerrar") { dismiss() }
                    .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Nombre")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.secondaryInk)
                TextField("Ej. Economía", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.weight(.medium))
                if hasDuplicateName {
                    Text("Ya existe una materia con este nombre.")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.terracotta)
                }
            }

            HStack(spacing: 14) {
                Image(systemName: "target")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(LumaPalette.sage)
                    .frame(width: 42, height: 42)
                    .background(LumaPalette.sage.opacity(0.11), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Objetivo de nota")
                        .font(.headline)
                        .foregroundStyle(LumaPalette.ink)
                    Text("Opcional. Luma lo usará para calcular escenarios y prioridades.")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                TextField(
                    "Sin objetivo",
                    value: $targetGrade,
                    format: .number.precision(.fractionLength(0 ... 2))
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                Text("/ 10")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
            .lumaCard(padding: 14)

            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("Ítems de la nota")
                        .font(.headline)
                        .foregroundStyle(LumaPalette.ink)
                    Spacer()
                    Button {
                        drafts.append(GradeItemDraft())
                    } label: {
                        Label("Agregar ítem", systemImage: "plus")
                    }
                    .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
                }

                ScrollView {
                    VStack(spacing: 9) {
                        ForEach($drafts) { $draft in
                            HStack(spacing: 9) {
                                TextField("Ej. Exámenes", text: $draft.title)
                                    .textFieldStyle(.roundedBorder)
                                TextField("0", text: $draft.weightText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 72)
                                Text("%")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(LumaPalette.secondaryInk)
                                Button {
                                    drafts.removeAll { $0.id == draft.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(LumaPalette.terracotta)
                                }
                                .buttonStyle(.plain)
                                .help("Quitar ítem")
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            .lumaCard(padding: 16)

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: min(total, 100), total: 100)
                    .tint(total == 100 ? LumaPalette.sage : LumaPalette.indigo)
                HStack {
                    Text("Total: \(percentage(total))%")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Spacer()
                    Text(completionMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(total > 100 ? LumaPalette.terracotta : LumaPalette.sage)
                }
            }

            HStack {
                Text("Podés completar el porcentaje más adelante.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Guardar materia") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.indigo)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .background(LumaBackground())
        .frame(width: 660, height: 680)
    }

    private var completionMessage: String {
        guard parsedItems != nil else { return "Revisá los valores" }
        if total > 100 { return "Excede \(percentage(total - 100))%" }
        if total == 100 { return "Ponderación completa" }
        return "Falta \(percentage(100 - total))%"
    }

    private func save() {
        guard canSave, let parsedItems else { return }
        let now = Date.now
        let savedSubject: AcademicSubject

        if let subject {
            subject.name = trimmedName
            subject.targetGrade = targetGrade
            subject.updatedAt = now
            savedSubject = subject
        } else {
            let newSubject = AcademicSubject(
                name: trimmedName,
                targetGrade: targetGrade,
                createdAt: now,
                updatedAt: now
            )
            modelContext.insert(newSubject)
            savedSubject = newSubject
        }

        let retainedIDs = Set(parsedItems.map { $0.draft.id })
        for item in existingItems where !retainedIDs.contains(item.id) {
            item.isArchived = true
            item.updatedAt = now
        }

        let existingByID = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.id, $0) })
        for entry in parsedItems {
            if let item = existingByID[entry.draft.id] {
                item.title = entry.draft.trimmedTitle
                item.weightPercent = entry.weight
                item.updatedAt = now
                item.isArchived = false
            } else {
                modelContext.insert(SubjectGradeItem(
                    id: entry.draft.id,
                    subjectID: savedSubject.id,
                    title: entry.draft.trimmedTitle,
                    weightPercent: entry.weight,
                    createdAt: now,
                    updatedAt: now
                ))
            }
        }

        try? modelContext.save()
        dismiss()
    }

    private func percentage(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }
}

private struct GradeItemDraft: Identifiable {
    let id: UUID
    var title: String
    var weightText: String

    init(id: UUID = UUID(), title: String = "", weightText: String = "") {
        self.id = id
        self.title = title
        self.weightText = weightText
    }

    init(_ item: SubjectGradeItem) {
        id = item.id
        title = item.title
        weightText = item.weightPercent.formatted(.number.precision(.fractionLength(0 ... 2)))
    }

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
