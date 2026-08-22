import SwiftData
import SwiftUI

struct AgendaSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(NotificationService.self) private var notificationService
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]
    @Query(sort: \FocusSession.endedAt, order: .reverse) private var focusSessions: [FocusSession]
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @Query(sort: \SubjectGradeItem.createdAt) private var gradeItems: [SubjectGradeItem]

    @State private var viewModel = AgendaSettingsViewModel()

    private var availabilityWindows: [AvailabilityWindow] {
        get { viewModel.availabilityWindows }
        nonmutating set { viewModel.availabilityWindows = newValue }
    }

    private var energyPreference: EnergyPreference {
        get { viewModel.energyPreference }
        nonmutating set { viewModel.energyPreference = newValue }
    }

    private let learningEngine = BehaviorLearningEngine()
    private let scheduler = DailyScheduler()

    private var planner: TaskPlanner {
        let profile = learningEngine.profile(from: focusSessions)
        return TaskPlanner(
            rhythmProfile: appState.learningEnabled ? profile : nil,
            preferredBlockOverride: appState.preferredBlockOverride,
            academicContexts: AcademicPriorityEngine.contexts(
                subjects: subjects,
                items: gradeItems,
                tasks: tasks
            )
        )
    }

    private var totalAvailableMinutes: Int {
        min(480, viewModel.totalAvailableMinutes)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    availabilitySection
                    energySection
                }
                .padding(26)
            }

            footer
        }
        .background(LumaBackground())
        .onAppear(perform: loadCurrentAgenda)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Tu tiempo de hoy")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                Text("Hoy puede ser completamente distinto de ayer. Solo se usa para esta fecha.")
                    .font(.subheadline)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
            Spacer()
            Button("Cerrar") { dismiss() }
                .buttonStyle(SoftButtonStyle(color: LumaPalette.secondaryInk))
        }
        .padding(26)
    }

    private var availabilitySection: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("¿Cuándo tenés tiempo?")
                        .font(.headline)
                        .foregroundStyle(LumaPalette.ink)
                    Text("Elegí una opción rápida o agregá varios bloques.")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                Text(availabilityWindows.isEmpty ? "Día libre" : durationTitle(totalAvailableMinutes))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(availabilityWindows.isEmpty ? LumaPalette.lavender : LumaPalette.sage)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { quickAvailabilityButtons }
                VStack(alignment: .leading, spacing: 8) { quickAvailabilityButtons }
            }

            if !availabilityWindows.isEmpty {
                Divider()
                VStack(spacing: 10) {
                    ForEach(Binding(
                        get: { viewModel.availabilityWindows },
                        set: { viewModel.availabilityWindows = $0 }
                    )) { $window in
                        availabilityRow(window: $window)
                    }
                }
            }

            HStack(spacing: 9) {
                Button { addAvailabilityWindow() } label: {
                    Label("Agregar bloque", systemImage: "plus.circle.fill")
                }
                .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))

                if calendarService.isAuthorized, calendarService.isEnabled {
                    Button { useCalendarWindows() } label: {
                        Label("Usar huecos del calendario", systemImage: "calendar.badge.checkmark")
                    }
                    .buttonStyle(SoftButtonStyle(color: LumaPalette.sage))
                }
            }

            if calendarService.isAuthorized, calendarService.isEnabled {
                Text("Los compromisos del calendario se descuentan de estos bloques antes de ubicar tareas.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
        }
        .lumaCard(padding: 18)
    }

    @ViewBuilder
    private var quickAvailabilityButtons: some View {
        ForEach([30, 60, 120], id: \.self) { minutes in
            Button(durationTitle(minutes)) { setQuickAvailability(minutes) }
                .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
        }
        Button("Día libre") { availabilityWindows = [] }
            .buttonStyle(SoftButtonStyle(color: LumaPalette.lavender))
    }

    private func availabilityRow(window: Binding<AvailabilityWindow>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.fill")
                .foregroundStyle(LumaPalette.indigo)
            DatePicker(
                "Desde",
                selection: startTimeBinding(for: window),
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.compact)
            DatePicker(
                "Hasta",
                selection: endTimeBinding(for: window),
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.compact)
            Spacer()
            Button(role: .destructive) {
                availabilityWindows.removeAll { $0.id == window.wrappedValue.id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Eliminar este bloque")
        }
        .padding(12)
        .background(Color.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 14))
    }

    private var energySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cómo estás hoy")
                .font(.headline)
                .foregroundStyle(LumaPalette.ink)

            Picker("Energía", selection: Binding(
                get: { viewModel.energyPreference },
                set: { viewModel.energyPreference = $0 }
            )) {
                ForEach(EnergyPreference.allCases) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .pickerStyle(.segmented)
        }
        .lumaCard(padding: 18)
    }

    private var footer: some View {
        HStack {
            Label("Esta disponibilidad vence al terminar el día", systemImage: "calendar.day.timeline.left")
                .font(.caption)
                .foregroundStyle(LumaPalette.sage)
            Spacer()
            Button("Cancelar") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(LumaPalette.indigo)
            Button(availabilityWindows.isEmpty ? "Guardar día libre" : "Guardar agenda de hoy") { save() }
                .buttonStyle(.borderedProminent)
                .tint(LumaPalette.indigo)
        }
        .padding(26)
    }

    private func loadCurrentAgenda() {
        let agenda = appState.dailyAgenda.flatMap {
            Calendar.current.isDateInToday($0.day) ? $0 : nil
        }
        viewModel.load(from: agenda, fallbackEnergy: appState.energyPreference)
    }

    private func setQuickAvailability(_ minutes: Int) {
        viewModel.setQuickAvailability(minutes, defaultStart: scheduler.defaultStartMinute())
    }

    private func addAvailabilityWindow() {
        let defaultStart = scheduler.defaultStartMinute()
        let latestEnd = availabilityWindows.map(\.endMinuteOfDay).max() ?? defaultStart - 30
        let suggestedStart = min(22 * 60, max(defaultStart, latestEnd + 30))
        availabilityWindows.append(AvailabilityWindow(
            startMinuteOfDay: suggestedStart,
            endMinuteOfDay: min(23 * 60 + 45, suggestedStart + 60)
        ))
        availabilityWindows.sort { $0.startMinuteOfDay < $1.startMinuteOfDay }
    }

    private func useCalendarWindows() {
        let start = max(8 * 60, scheduler.defaultStartMinute())
        let end = 21 * 60
        guard end - start >= 30 else {
            availabilityWindows = []
            return
        }

        availabilityWindows = Array(scheduler.freeAvailabilityWindows(
            in: [AvailabilityWindow(startMinuteOfDay: start, endMinuteOfDay: end)],
            busyBlocks: calendarService.busyBlocks()
        ).filter { $0.durationMinutes >= 30 }.prefix(4))
    }

    private func startTimeBinding(for window: Binding<AvailabilityWindow>) -> Binding<Date> {
        Binding(
            get: { scheduler.date(on: .now, minuteOfDay: window.wrappedValue.startMinuteOfDay) },
            set: { date in
                let minute = minuteOfDay(date)
                window.wrappedValue.startMinuteOfDay = min(
                    minute,
                    window.wrappedValue.endMinuteOfDay - 15
                )
            }
        )
    }

    private func endTimeBinding(for window: Binding<AvailabilityWindow>) -> Binding<Date> {
        Binding(
            get: { scheduler.date(on: .now, minuteOfDay: window.wrappedValue.endMinuteOfDay) },
            set: { date in
                let minute = minuteOfDay(date)
                window.wrappedValue.endMinuteOfDay = max(
                    window.wrappedValue.startMinuteOfDay + 15,
                    minute
                )
            }
        )
    }

    private func minuteOfDay(_ date: Date) -> Int {
        let calendar = Calendar.current
        return calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }

    private func save() {
        appState.applyAgendaRequest(
            AgendaRequestDraft(
                availableMinutes: totalAvailableMinutes,
                startMinuteOfDay: availabilityWindows.first?.startMinuteOfDay,
                availabilityWindows: availabilityWindows,
                energyPreference: energyPreference
            ),
            tasks: tasks,
            planner: planner,
            scheduler: scheduler,
            busyBlocks: calendarService.busyBlocks()
        )
        appState.coachMessage = availabilityWindows.isEmpty
            ? "Listo. Hoy queda libre; no voy a empujarte tareas en un día sin espacio."
            : "Agenda lista. Usé solamente los bloques que marcaste y dejé afuera los compromisos del calendario."
        Task { await notificationService.scheduleAgenda(appState.dailyAgenda, tasks: tasks) }
        dismiss()
    }

    private func durationTitle(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remaining = minutes % 60
        if hours == 0 { return "\(remaining) min" }
        if remaining == 0 { return hours == 1 ? "1 hora" : "\(hours) horas" }
        return "\(hours) h \(remaining) min"
    }
}
