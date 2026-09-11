import SwiftData
import SwiftUI

struct RoutinesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AcademicRoutine.updatedAt) private var routines: [AcademicRoutine]
    @Query(sort: \AcademicExam.updatedAt) private var exams: [AcademicExam]
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]
    @Query(sort: \DailyPlanningContext.updatedAt) private var dailyContexts: [DailyPlanningContext]
    @State private var viewModel = RoutinesViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom) { heading; Spacer(); addButton }
                    VStack(alignment: .leading, spacing: 12) { heading; addButton }
                }

                if routines.isEmpty {
                    EmptyStateView(
                        symbol: "arrow.triangle.2.circlepath",
                        title: "Todavía no hay rutinas",
                        message: "Agregá lo que se repite cada semana y Luma lo va a incorporar sin que tengas que volver a escribirlo."
                    )
                } else {
                    LazyVStack(spacing: 13) {
                        ForEach(viewModel.activeRoutines(from: routines)) { routine in
                            routineCard(routine)
                        }
                    }
                }
            }
            .padding(30)
            .lumaScrollContent()
        }
        .lumaScrollSurface()
        .navigationTitle("Rutinas")
        .sheet(isPresented: $viewModel.editorPresented) {
            RoutineEditorView { routine in
                modelContext.insert(routine)
                try? modelContext.save()
                materialize()
            }
        }
    }

    private var heading: some View {
        SectionTitle(
            eyebrow: "Ritmo académico",
            title: "Lo que vuelve cada semana",
            trailing: routines.count == 1 ? "1 rutina" : "\(routines.count) rutinas"
        )
    }

    private var addButton: some View {
        Button { viewModel.editorPresented = true } label: {
            Label("Agregar rutina", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .tint(LumaPalette.indigo)
    }

    private func routineCard(_ routine: AcademicRoutine) -> some View {
        HStack(spacing: 16) {
            Image(systemName: routine.activityType.symbol)
                .font(.title3)
                .foregroundStyle(routine.isPaused ? LumaPalette.secondaryInk : LumaPalette.indigo)
                .frame(width: 48, height: 48)
                .background(LumaPalette.indigo.opacity(0.09), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(routine.title)
                    .font(.headline)
                    .foregroundStyle(LumaPalette.ink)
                HStack(spacing: 12) {
                    Label(weekdayTitle(routine.weekday), systemImage: "calendar")
                    if let minute = routine.minuteOfDay {
                        Label(timeTitle(minute), systemImage: "clock")
                    }
                    Label("\(routine.estimatedMinutes) min", systemImage: "timer")
                    Text(viewModel.subjectName(for: routine, subjects: subjects))
                }
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
            }
            Spacer()
            Toggle("Pausada", isOn: Binding(
                get: { !routine.isPaused },
                set: {
                    routine.isPaused = !$0
                    routine.updatedAt = .now
                    try? modelContext.save()
                    appState.refreshPlan()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            Text(routine.isPaused ? "Pausada" : "Activa")
                .font(.caption.weight(.semibold))
                .foregroundStyle(routine.isPaused ? LumaPalette.secondaryInk : LumaPalette.sage)
        }
        .lumaCard(padding: 17)
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

    private func weekdayTitle(_ weekday: Int) -> String {
        ["", "Domingo", "Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado"][max(1, min(7, weekday))]
    }

    private func timeTitle(_ minute: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private struct RoutineEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @State private var viewModel = RoutineEditorViewModel()
    let onSave: (AcademicRoutine) -> Void

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: 18) {
            Text("Nueva rutina")
                .font(.title2.weight(.semibold))
                .foregroundStyle(LumaPalette.ink)
            Text("Luma va a crear la actividad automáticamente el día que corresponda.")
                .font(.subheadline)
                .foregroundStyle(LumaPalette.secondaryInk)
            TextField("Ej. Acordeón de lectura", text: $viewModel.title)
                .textFieldStyle(.roundedBorder)
            Picker("Materia", selection: $viewModel.subjectID) {
                Text("Sin materia").tag(UUID?.none)
                ForEach(subjects.filter { !$0.isArchived }) { Text($0.name).tag(Optional($0.id)) }
            }
            HStack {
                Picker("Día", selection: $viewModel.weekday) {
                    Text("Domingo").tag(1); Text("Lunes").tag(2); Text("Martes").tag(3)
                    Text("Miércoles").tag(4); Text("Jueves").tag(5); Text("Viernes").tag(6); Text("Sábado").tag(7)
                }
                Picker("Actividad", selection: $viewModel.activityType) {
                    ForEach(AcademicActivityType.allCases) { Text($0.title).tag($0) }
                }
            }
            HStack {
                Toggle("Tiene hora", isOn: $viewModel.hasTime)
                if viewModel.hasTime {
                    DatePicker("Hora", selection: timeBinding, displayedComponents: [.hourAndMinute]).labelsHidden()
                }
                Spacer()
                Stepper("\(viewModel.estimatedMinutes) min", value: $viewModel.estimatedMinutes, in: 10 ... 240, step: 5)
            }
            HStack {
                DatePicker("Desde", selection: $viewModel.startDate, displayedComponents: [.date])
                Toggle("Fecha de fin", isOn: $viewModel.hasEndDate)
                if viewModel.hasEndDate {
                    DatePicker("Hasta", selection: $viewModel.endDate, displayedComponents: [.date]).labelsHidden()
                }
            }
            Toggle("Pausar durante vacaciones", isOn: $viewModel.pauseDuringVacation)
            Spacer()
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(.bordered)
                Button("Guardar rutina") {
                    onSave(AcademicRoutine(
                        title: viewModel.title.trimmingCharacters(in: .whitespacesAndNewlines),
                        subjectID: viewModel.subjectID,
                        weekday: viewModel.weekday,
                        minuteOfDay: viewModel.hasTime ? viewModel.minuteOfDay : nil,
                        activityType: viewModel.activityType,
                        estimatedMinutes: viewModel.estimatedMinutes,
                        startDate: viewModel.startDate,
                        endDate: viewModel.hasEndDate ? viewModel.endDate : nil,
                        pauseDuringVacation: viewModel.pauseDuringVacation
                    ))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(LumaPalette.indigo)
                .disabled(!viewModel.canSave)
            }
        }
        .padding(26)
        .frame(width: 650, height: 570)
        .background(LumaBackground())
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: viewModel.minuteOfDay / 60, minute: viewModel.minuteOfDay % 60, second: 0, of: .now) ?? .now
            },
            set: {
                viewModel.minuteOfDay = Calendar.current.component(.hour, from: $0) * 60
                    + Calendar.current.component(.minute, from: $0)
            }
        )
    }
}
