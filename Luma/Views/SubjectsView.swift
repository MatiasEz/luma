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
    @State private var quickGradeEntryPresented = false

    private var activeSubjects: [AcademicSubject] {
        subjects.filter { !$0.isArchived }
    }

    private var activeItems: [SubjectGradeItem] {
        gradeItems.filter { !$0.isArchived }
    }

    private var gradeEntryTasks: [LumaTask] {
        let subjectIDs = Set(activeSubjects.map(\.id))
        let itemIDs = Set(activeItems.map(\.id))
        return tasks.filter {
            $0.academicSubjectID.map(subjectIDs.contains) == true
                && $0.subjectGradeItemID.map(itemIDs.contains) == true
                && ($0.isCompleted || $0.grade != nil)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom) {
                        heading
                        Spacer(minLength: 16)
                        headerActions
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        heading
                        headerActions
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
                    LazyVStack(spacing: 14) {
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
            .frame(maxWidth: 1040, alignment: .leading)
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
        .sheet(isPresented: $quickGradeEntryPresented) {
            QuickGradeEntryView(
                subjects: activeSubjects,
                items: activeItems,
                tasks: gradeEntryTasks
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

    private var headerActions: some View {
        HStack(spacing: 9) {
            Button {
                quickGradeEntryPresented = true
            } label: {
                Label("Cargar notas", systemImage: "square.and.pencil")
            }
            .buttonStyle(.bordered)
            .disabled(gradeEntryTasks.isEmpty)

            Button {
                presentEditor(for: nil)
            } label: {
                Label("Agregar materia", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(LumaPalette.indigo)
        }
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
        total > 100.001
            ? LumaPalette.terracotta
            : (abs(total - 100) < 0.001 ? LumaPalette.sage : LumaPalette.indigo)
    }

    private var gradeSummary: SubjectGradeSummary {
        SubjectGradeCalculator.makeSummary(items: items, tasks: tasks)
    }

    private var openTaskCount: Int {
        tasks.filter { !$0.isCompleted }.count
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                subjectIdentity
                    .frame(width: 250, alignment: .topLeading)

                Divider()
                    .frame(height: 142)

                categoryOverview
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                Divider()
                    .frame(height: 142)

                gradeOverview
                    .frame(width: 240, alignment: .topLeading)
            }
            .frame(minWidth: 720, alignment: .leading)

            VStack(alignment: .leading, spacing: 16) {
                subjectIdentity
                Divider().opacity(0.55)
                categoryOverview
                Divider().opacity(0.55)
                gradeOverview
            }
        }
        .lumaCard(padding: 18)
    }

    private var subjectIdentity: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "book.closed.fill")
                    .font(.headline)
                    .foregroundStyle(LumaPalette.indigo)
                    .frame(width: 40, height: 40)
                    .background(LumaPalette.indigo.opacity(0.11), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(subject.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let target = subject.targetGrade {
                        Label("Objetivo \(grade(target))", systemImage: "target")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LumaPalette.sage)
                    }
                }

                Spacer(minLength: 4)

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

            HStack(spacing: 14) {
                Label(taskCountText, systemImage: "checklist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.secondaryInk)

                if gradeSummary.awaitingGradeTaskCount > 0 {
                    Label("\(gradeSummary.awaitingGradeTaskCount) espera nota", systemImage: "clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LumaPalette.mustard)
                }
            }
        }
    }

    private var categoryOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PONDERACIÓN")
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(LumaPalette.secondaryInk)

            if items.isEmpty {
                Text("Todavía no configuraste categorías.")
                    .font(.subheadline)
                    .foregroundStyle(LumaPalette.secondaryInk)
            } else {
                ForEach(Array(items.prefix(4))) { item in
                    HStack(spacing: 9) {
                        Circle()
                            .fill(LumaPalette.lavender)
                            .frame(width: 7, height: 7)
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(LumaPalette.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(percentage(item.weightPercent))%")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(LumaPalette.indigo)
                    }
                }

                if items.count > 4 {
                    Text("Y \(items.count - 4) categorías más")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
            }

            ProgressView(value: min(total, 100), total: 100)
                .tint(progressColor)

            Text(configurationText)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(progressColor)
        }
    }

    private var gradeOverview: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("NOTA ACTUAL")
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(LumaPalette.secondaryInk)

            if let currentGrade = gradeSummary.currentGrade {
                Text("\(grade(currentGrade)) / 10")
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(LumaPalette.ink)
                Text("Promedio de lo ya calificado")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
                Text("Aporta \(grade(gradeSummary.weightedContribution)) / 10 a la nota final")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.sage)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Sin notas")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                Text("Cargá una calificación para empezar.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }

            if let objectiveSummary {
                Label(objectiveSummary, systemImage: objectiveSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(objectiveColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onShowGradeDetail) {
                HStack(spacing: 6) {
                    Text("Ver detalle")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(LumaPalette.indigo)
            }
            .buttonStyle(.plain)
        }
    }

    private var taskCountText: String {
        if tasks.isEmpty { return "Sin tareas" }
        if openTaskCount == 0 { return "Todo al día" }
        return openTaskCount == 1 ? "1 pendiente" : "\(openTaskCount) pendientes"
    }

    private var configurationText: String {
        if total > 100.001 { return "Excede por \(percentage(total - 100))%" }
        if abs(total - 100) < 0.001 { return "100% configurado" }
        return "\(percentage(total))% configurado · falta \(percentage(remaining))%"
    }

    private var objectiveSummary: String? {
        guard let target = subject.targetGrade else { return nil }

        if gradeSummary.pendingGradeTaskCount > 0,
           let required = gradeSummary.requiredAverage(for: target)
        {
            if required > 10 { return "Objetivo en riesgo" }
            if required <= 0 { return "Objetivo asegurado" }
            return "Necesitás \(grade(required)) en pendientes"
        }

        guard let current = gradeSummary.currentGrade else {
            return "Objetivo \(grade(target)) aún sin medir"
        }
        return current >= target ? "Objetivo alcanzado" : "A \(grade(target - current)) del objetivo"
    }

    private var objectiveSymbol: String {
        guard let target = subject.targetGrade else { return "target" }
        if let required = gradeSummary.requiredAverage(for: target), required > 10 {
            return "exclamationmark.triangle.fill"
        }
        if let current = gradeSummary.currentGrade, current >= target,
           gradeSummary.pendingGradeTaskCount == 0
        {
            return "checkmark.seal.fill"
        }
        return "target"
    }

    private var objectiveColor: Color {
        guard let target = subject.targetGrade else { return LumaPalette.secondaryInk }
        if let required = gradeSummary.requiredAverage(for: target), required > 10 {
            return LumaPalette.terracotta
        }
        if let current = gradeSummary.currentGrade, current >= target,
           gradeSummary.pendingGradeTaskCount == 0
        {
            return LumaPalette.sage
        }
        return LumaPalette.indigo
    }

    private func percentage(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }

    private func grade(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }

}

private struct SubjectGradeDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let subject: AcademicSubject
    let items: [SubjectGradeItem]
    let tasks: [LumaTask]

    @State private var simulatorPresented = false
    @State private var quickGradeEntryPresented = false

    private var summary: SubjectGradeSummary {
        SubjectGradeCalculator.makeSummary(items: items, tasks: tasks)
    }

    private var gradeEntryTasks: [LumaTask] {
        tasks.filter { $0.subjectGradeItemID != nil && ($0.isCompleted || $0.grade != nil) }
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
                if !gradeEntryTasks.isEmpty {
                    Button {
                        quickGradeEntryPresented = true
                    } label: {
                        Label("Cargar notas", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.bordered)
                }
                if tasks.contains(where: {
                    $0.academicEvaluationStatus == .upcomingEvaluation
                        || $0.academicEvaluationStatus == .awaitingGrade
                }) {
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
        .sheet(isPresented: $quickGradeEntryPresented) {
            QuickGradeEntryView(subjects: [subject], items: items, tasks: gradeEntryTasks)
        }
    }

    private var gradeSummaryCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("RENDIMIENTO ACTUAL")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(LumaPalette.secondaryInk)
                    Text(summary.currentGrade.map { "\(grade($0)) / 10" } ?? "Sin notas")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit())
                        .foregroundStyle(LumaPalette.ink)
                    Text(summary.gradedTaskCount == 1
                        ? "Calculado con 1 calificación"
                        : "Calculado con \(summary.gradedTaskCount) calificaciones")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }

                Spacer(minLength: 16)

                if let target = subject.targetGrade {
                    VStack(alignment: .trailing, spacing: 5) {
                        Label("Objetivo", systemImage: "target")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LumaPalette.sage)
                        Text("\(grade(target)) / 10")
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(LumaPalette.ink)
                        Text(targetDistanceText(target))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(targetDistanceColor(target))
                    }
                }
            }

            if let currentGrade = summary.currentGrade {
                ProgressView(value: min(max(currentGrade, 0), 10), total: 10)
                    .tint(LumaPalette.indigo)
            }

            Text("El rendimiento actual promedia únicamente lo que ya fue calificado. Las evaluaciones sin nota no se cuentan como cero.")
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                metric(
                    title: "Aporte confirmado",
                    value: "\(grade(summary.weightedContribution)) / 10",
                    detail: "Solo lo que ya fue calificado",
                    color: LumaPalette.sage
                )
                metric(
                    title: "Próximas",
                    value: "\(summary.upcomingEvaluationTaskCount)",
                    detail: "Todavía no realizadas",
                    color: LumaPalette.indigo
                )
                metric(
                    title: "Esperando nota",
                    value: "\(summary.awaitingGradeTaskCount)",
                    detail: "Ya fueron completadas",
                    color: LumaPalette.mustard
                )
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

    private func targetDistanceText(_ target: Double) -> String {
        guard let current = summary.currentGrade else { return "Todavía sin medir" }
        if current >= target { return "Hoy estás sobre el objetivo" }
        return "A \(grade(target - current)) puntos"
    }

    private func targetDistanceColor(_ target: Double) -> Color {
        guard let current = summary.currentGrade else { return LumaPalette.secondaryInk }
        return current >= target ? LumaPalette.sage : LumaPalette.terracotta
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
                Text("Pesa \(percentage(category.weightPercent))% de la nota final")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(LumaPalette.indigo)
                Text(categoryTaskDescription(category))
                    .font(.caption2)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                if let average = category.averageGrade {
                    Text("Promedio \(grade(average)) / 10")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(LumaPalette.ink)
                    Text("Aporta \(grade(category.weightedContribution)) de \(grade(category.weightPercent / 10)) puntos")
                        .font(.caption2.weight(.semibold).monospacedDigit())
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
                Text("Peso configurado todavía sin calificar: \(percentage(summary.configuredWithoutGradesWeight))% de la materia.")
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
        var parts = [assigned, graded]
        if category.upcomingEvaluationTaskCount > 0 {
            parts.append(category.upcomingEvaluationTaskCount == 1
                ? "1 próxima"
                : "\(category.upcomingEvaluationTaskCount) próximas")
        }
        if category.awaitingGradeTaskCount > 0 {
            parts.append(category.awaitingGradeTaskCount == 1
                ? "1 esperando nota"
                : "\(category.awaitingGradeTaskCount) esperando nota")
        }
        return parts.joined(separator: " · ")
    }

    private func percentage(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }

    private func grade(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }
}

private struct QuickGradeEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    let subjects: [AcademicSubject]
    let items: [SubjectGradeItem]
    let tasks: [LumaTask]

    @State private var selectedSubjectID: UUID?
    @State private var gradeTexts: [UUID: String]

    init(subjects: [AcademicSubject], items: [SubjectGradeItem], tasks: [LumaTask]) {
        self.subjects = subjects
        self.items = items
        self.tasks = tasks
        _selectedSubjectID = State(initialValue: subjects.count == 1 ? subjects.first?.id : nil)
        _gradeTexts = State(initialValue: Dictionary(uniqueKeysWithValues: tasks.map { task in
            let text = task.grade?.formatted(.number.precision(.fractionLength(0 ... 2))) ?? ""
            return (task.id, text)
        }))
    }

    private var filteredSubjects: [AcademicSubject] {
        subjects.filter { subject in
            (selectedSubjectID == nil || selectedSubjectID == subject.id)
                && tasks.contains { $0.academicSubjectID == subject.id }
        }
    }

    private var changedTasks: [LumaTask] {
        tasks.filter { gradeChanged(for: $0) }
    }

    private var allInputsAreValid: Bool {
        tasks.allSatisfy { inputIsValid(for: $0) }
    }

    private var awaitingCount: Int {
        tasks.filter { $0.academicEvaluationStatus == .awaitingGrade }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CARGA RÁPIDA")
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(LumaPalette.sage)
                    Text("Notas de evaluaciones")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                    Text("Completá las que están esperando o corregí una nota ya guardada.")
                        .font(.subheadline)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                Button("Cerrar") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(24)

            Divider().opacity(0.55)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    if subjects.count > 1 {
                        Picker("Materia", selection: $selectedSubjectID) {
                            Text("Todas las materias").tag(nil as UUID?)
                            ForEach(subjects) { subject in
                                Text(subject.name).tag(subject.id as UUID?)
                            }
                        }
                        .frame(maxWidth: 280)
                    }

                    Spacer()

                    if awaitingCount > 0 {
                        Label(
                            awaitingCount == 1 ? "1 esperando nota" : "\(awaitingCount) esperando nota",
                            systemImage: "clock.badge.questionmark"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LumaPalette.mustard)
                    }
                }

                Text("Si borrás una calificación guardada, la evaluación volverá a quedar sin nota.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(filteredSubjects) { subject in
                        subjectGradeGroup(subject)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            Divider().opacity(0.55)

            HStack {
                if !allInputsAreValid {
                    Label("Las notas deben estar entre 0 y 10.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LumaPalette.terracotta)
                } else {
                    Text(changesText)
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.borderless)
                Button("Guardar cambios") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.indigo)
                    .keyboardShortcut(.defaultAction)
                    .disabled(changedTasks.isEmpty || !allInputsAreValid)
            }
            .padding(24)
        }
        .background(LumaBackground())
        .frame(width: 720, height: 680)
    }

    private func subjectGradeGroup(_ subject: AcademicSubject) -> some View {
        let subjectTasks = tasks.filter { $0.academicSubjectID == subject.id }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(subject.name, systemImage: "book.closed.fill")
                    .font(.headline)
                    .foregroundStyle(LumaPalette.ink)
                Spacer()
                Text(subjectTasks.count == 1 ? "1 evaluación" : "\(subjectTasks.count) evaluaciones")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }

            VStack(spacing: 0) {
                ForEach(Array(subjectTasks.enumerated()), id: \.element.id) { index, task in
                    gradeEntryRow(task)
                    if index < subjectTasks.count - 1 {
                        Divider().opacity(0.45)
                    }
                }
            }
            .lumaCard(padding: 0)
        }
    }

    private func gradeEntryRow(_ task: LumaTask) -> some View {
        HStack(spacing: 14) {
            Image(systemName: task.grade == nil ? "clock.badge.questionmark" : "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(task.grade == nil ? LumaPalette.mustard : LumaPalette.sage)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(categoryName(for: task))
                    Text("·")
                    Text(task.grade == nil ? "Esperando nota" : "Calificada")
                        .foregroundStyle(task.grade == nil ? LumaPalette.mustard : LumaPalette.sage)
                }
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                TextField("Nota", text: gradeBinding(for: task.id))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 92)
                    .overlay {
                        if !inputIsValid(for: task) {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(LumaPalette.terracotta, lineWidth: 1)
                        }
                    }
                Text("/ 10")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var changesText: String {
        if changedTasks.isEmpty { return "No hay cambios para guardar." }
        return changedTasks.count == 1 ? "1 nota modificada" : "\(changedTasks.count) notas modificadas"
    }

    private func categoryName(for task: LumaTask) -> String {
        guard let itemID = task.subjectGradeItemID,
              let item = items.first(where: { $0.id == itemID })
        else { return "Evaluación" }
        return item.title
    }

    private func gradeBinding(for taskID: UUID) -> Binding<String> {
        Binding(
            get: { gradeTexts[taskID] ?? "" },
            set: { gradeTexts[taskID] = $0 }
        )
    }

    private func parsedGrade(for task: LumaTask) -> Double? {
        let text = (gradeTexts[task.id] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty else { return nil }
        return Double(text)
    }

    private func inputIsValid(for task: LumaTask) -> Bool {
        let text = (gradeTexts[task.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return true }
        guard let grade = parsedGrade(for: task) else { return false }
        return (0 ... 10).contains(grade)
    }

    private func gradeChanged(for task: LumaTask) -> Bool {
        guard inputIsValid(for: task) else { return false }
        switch (task.grade, parsedGrade(for: task)) {
        case (nil, nil): return false
        case let (old?, new?): return abs(old - new) > 0.0001
        default: return true
        }
    }

    private func save() {
        guard allInputsAreValid else { return }
        for task in changedTasks {
            task.grade = parsedGrade(for: task)
        }
        try? modelContext.save()
        appState.refreshPlan()
        dismiss()
    }
}

private struct GradeSimulatorView: View {
    @Environment(\.dismiss) private var dismiss

    let subject: AcademicSubject
    let items: [SubjectGradeItem]
    let tasks: [LumaTask]

    @State private var simulatedGrades: [UUID: Double] = [:]

    private var pendingTasks: [LumaTask] {
        tasks.filter {
            $0.academicEvaluationStatus == .upcomingEvaluation
                || $0.academicEvaluationStatus == .awaitingGrade
        }
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
                Text("\(categoryName(for: task)) · \(task.academicEvaluationStatus?.title ?? "Sin nota")")
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
