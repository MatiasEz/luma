import SwiftData
import SwiftUI

struct AgendaSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(NotificationService.self) private var notificationService
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]
    @Query(sort: \FocusSession.endedAt, order: .reverse) private var focusSessions: [FocusSession]
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @Query(sort: \SubjectClassMeeting.updatedAt) private var classMeetings: [SubjectClassMeeting]
    @Query(sort: \DailyPlanningContext.updatedAt) private var dailyContexts: [DailyPlanningContext]

    @State private var viewModel = AgendaSettingsViewModel()
    @State private var loadedAvailableMinutes: Int?
    @State private var saveFailed = false

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

    private func planner(availableMinutes: Int? = nil) -> TaskPlanner {
        let profile = learningEngine.profile(from: focusSessions)
        let context = todayContext
        return TaskPlanner(
            rhythmProfile: appState.learningEnabled ? profile : nil,
            preferredBlockOverride: appState.preferredBlockOverride,
            availableMinutes: availableMinutes ?? appState.remainingAvailableMinutes(fallback: context?.availableMinutes ?? 120),
            planningMode: context?.planningMode ?? .realistic,
            classMeetings: classMeetings,
            subjectNames: Dictionary(uniqueKeysWithValues: subjects.map { ($0.id, $0.name) }),
            weeklyAvailability: appState.weeklyAvailability,
            restCounts: context?.restCounts ?? true
        )
    }

    private var todayContext: DailyPlanningContext? {
        dailyContexts.first { Calendar.current.isDateInToday($0.day) }
    }

    private var totalAvailableMinutes: Int {
        min(600, viewModel.totalAvailableMinutes)
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
                .lumaScrollContent()
            }
            .lumaScrollSurface()

            footer
        }
        .background(LumaBackground())
        .alert("No se pudo guardar la disponibilidad", isPresented: $saveFailed) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text("Tu tiempo no cambió. Podés volver a intentar guardarla.")
        }
        .onAppear(perform: loadCurrentAgenda)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("El tiempo que te queda hoy")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                Text("Ajustá los bloques que todavía podés usar. El tiempo ya realizado sigue registrado.")
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
                    Text("Las tareas evitan los compromisos del calendario. Tu tiempo neto disponible no se descuenta dos veces.")
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
        viewModel.load(from: agenda, fallbackEnergy: todayContext?.energy ?? appState.energyPreference)
        let remaining = appState.remainingAvailableMinutes(fallback: todayContext?.availableMinutes ?? 120)
        fitAvailabilityWindows(to: remaining)
        loadedAvailableMinutes = viewModel.totalAvailableMinutes
    }

    private func fitAvailabilityWindows(to remaining: Int) {
        guard viewModel.totalAvailableMinutes != remaining else { return }
        if availabilityWindows.isEmpty || viewModel.totalAvailableMinutes < remaining {
            viewModel.setQuickAvailability(remaining, defaultStart: scheduler.defaultStartMinute())
        } else {
            var unassigned = remaining
            availabilityWindows = availabilityWindows.compactMap { window in
                let minutes = min(window.durationMinutes, unassigned)
                guard minutes > 0 else { return nil }
                unassigned -= minutes
                var adjusted = window
                adjusted.endMinuteOfDay = adjusted.startMinuteOfDay + minutes
                return adjusted
            }
        }
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
        let context: DailyPlanningContext
        if let existing = todayContext {
            context = existing
        } else {
            context = DailyPlanningContext(day: .now)
            modelContext.insert(context)
        }
        appState.ensureDailyTimeBudget(availableMinutes: context.availableMinutes)
        let previousRemainingMinutes = appState.remainingAvailableMinutes(fallback: context.availableMinutes)
        let changedTime = totalAvailableMinutes != (loadedAvailableMinutes ?? previousRemainingMinutes)
        let minutesToSave = changedTime ? totalAvailableMinutes : previousRemainingMinutes
        if !changedTime { fitAvailabilityWindows(to: minutesToSave) }
        let previousEnergy = context.energy
        let previousContextMinutes = context.availableMinutes
        let previousUpdatedAt = context.updatedAt
        context.energy = energyPreference
        context.availableMinutes = minutesToSave
        context.updatedAt = .now
        do {
            try modelContext.save()
        } catch {
            context.energy = previousEnergy
            context.availableMinutes = previousContextMinutes
            context.updatedAt = previousUpdatedAt
            saveFailed = true
            return
        }
        if minutesToSave != previousRemainingMinutes {
            appState.setRemainingAvailableMinutes(minutesToSave)
        }
        let configuredPlanner = planner(availableMinutes: minutesToSave)
        appState.replanDaily(from: tasks, planner: configuredPlanner, preference: energyPreference)
        appState.applyAgendaRequest(
            AgendaRequestDraft(
                availableMinutes: minutesToSave,
                startMinuteOfDay: availabilityWindows.first?.startMinuteOfDay,
                availabilityWindows: availabilityWindows,
                energyPreference: energyPreference
            ),
            tasks: tasks,
            planner: configuredPlanner,
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
