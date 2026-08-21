import SwiftUI

struct AcademicTaskFields: View {
    let subjects: [AcademicSubject]
    let gradeItems: [SubjectGradeItem]

    @Binding var subjectID: UUID?
    @Binding var gradeItemID: UUID?
    @Binding var grade: Double?
    @Binding var legacyWeight: Double?
    let isCompleted: Bool

    private var selectedItems: [SubjectGradeItem] {
        guard let subjectID else { return [] }
        return gradeItems.filter { $0.subjectID == subjectID }
    }

    private var subjectSelection: Binding<UUID?> {
        Binding(
            get: { subjectID },
            set: { newSubjectID in
                subjectID = newSubjectID
                gradeItemID = nil
                grade = nil
                if newSubjectID != nil { legacyWeight = nil }
            }
        )
    }

    private var countsTowardGrade: Binding<Bool> {
        Binding(
            get: { gradeItemID != nil },
            set: { newValue in
                if newValue {
                    gradeItemID = selectedItems.first?.id
                } else {
                    gradeItemID = nil
                    grade = nil
                }
            }
        )
    }

    private var evaluationStatus: AcademicEvaluationStatus? {
        guard subjectID != nil else { return nil }
        guard gradeItemID != nil else { return .notEvaluable }
        guard grade == nil else { return .graded }
        return isCompleted ? .awaitingGrade : .upcomingEvaluation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "graduationcap.fill")
                    .foregroundStyle(LumaPalette.indigo)
                Text("Datos académicos")
                    .font(.headline)
                    .foregroundStyle(LumaPalette.ink)
                Spacer()
                if let evaluationStatus {
                    Label(evaluationStatus.title, systemImage: evaluationStatus.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor(evaluationStatus))
                }
            }

            if subjects.isEmpty {
                Text("Primero agregá una materia desde la sección Materias. Mientras tanto podés usar una ponderación individual.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                legacyWeightField
            } else {
                subjectField

                if subjectID == nil {
                    legacyWeightField
                } else {
                    evaluationFields
                }
            }

            if let grade, !(0 ... 10).contains(grade) {
                Label("La nota debe estar entre 0 y 10.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.terracotta)
            }
        }
        .padding(14)
        .background(LumaPalette.indigo.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(LumaPalette.indigo.opacity(0.12))
        }
    }

    private var subjectField: some View {
        Picker("Materia", selection: subjectSelection) {
            Text("Sin materia").tag(nil as UUID?)
            ForEach(subjects) { subject in
                Text(subject.name).tag(subject.id as UUID?)
            }
        }
        .frame(minWidth: 175, maxWidth: 320, alignment: .leading)
    }

    @ViewBuilder
    private var evaluationFields: some View {
        Toggle("Esta tarea lleva nota", isOn: countsTowardGrade)
            .toggleStyle(.switch)
            .disabled(selectedItems.isEmpty)

        if selectedItems.isEmpty {
            Text("Esta materia no tiene categorías configuradas. La tarea se guardará como no evaluable.")
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        } else if gradeItemID != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { gradeFields }
                VStack(alignment: .leading, spacing: 10) { gradeFields }
            }

            Text(evaluationHelpText)
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Queda vinculada a la materia para organizarte, pero no afecta el promedio.")
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var gradeFields: some View {
        Picker("Categoría", selection: $gradeItemID) {
            ForEach(selectedItems) { item in
                Text("\(item.title) · \(percentage(item.weightPercent))%")
                    .tag(item.id as UUID?)
            }
        }
        .frame(minWidth: 185)

        HStack(spacing: 6) {
            TextField(
                "Nota opcional",
                value: $grade,
                format: .number.precision(.fractionLength(0 ... 2))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 125)
            Text("/ 10")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LumaPalette.secondaryInk)
        }
    }

    private var legacyWeightField: some View {
        TextField("Ponderación individual %", value: $legacyWeight, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 190)
    }

    private func percentage(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }

    private func statusColor(_ status: AcademicEvaluationStatus) -> Color {
        switch status {
        case .notEvaluable: LumaPalette.secondaryInk
        case .upcomingEvaluation: LumaPalette.indigo
        case .awaitingGrade: LumaPalette.mustard
        case .graded: grade.map { $0 >= 6 ? LumaPalette.sage : LumaPalette.terracotta } ?? LumaPalette.sage
        }
    }

    private var evaluationHelpText: String {
        if grade != nil {
            return "La nota ya está incluida en el cálculo de la materia."
        }
        if isCompleted {
            return "La evaluación ya está completada. Quedará esperando nota y no contará como cero."
        }
        return "Primero aparecerá como próxima evaluación. Al marcarla como hecha, podrás cargar la nota desde el Inbox."
    }
}
