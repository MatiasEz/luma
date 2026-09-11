import SwiftUI

struct AcademicTaskFields: View {
    let subjects: [AcademicSubject]
    @Binding var subjectID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "graduationcap.fill")
                    .foregroundStyle(LumaPalette.indigo)
                Text("Materia")
                    .font(.headline)
                    .foregroundStyle(LumaPalette.ink)
                Spacer()
            }

            if subjects.isEmpty {
                Text("Podés crear una materia desde la sección Materias y asignarla después.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Materia", selection: $subjectID) {
                    Text("Sin materia").tag(nil as UUID?)
                    ForEach(subjects) { subject in
                        Text(subject.name).tag(subject.id as UUID?)
                    }
                }
                .frame(minWidth: 175, maxWidth: 320, alignment: .leading)

                Text("Sirve para agrupar la tarea y verla dentro de su materia.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
        }
        .padding(14)
        .background(LumaPalette.indigo.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(LumaPalette.indigo.opacity(0.12))
        }
    }
}
