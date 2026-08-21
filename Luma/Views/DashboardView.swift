import Combine
import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalAIEngine.self) private var aiEngine
    @Environment(NotificationService.self) private var notificationService
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]
    @Query(sort: \FocusSession.endedAt, order: .reverse) private var focusSessions: [FocusSession]
    @Query(sort: \LumaProfile.createdAt) private var profiles: [LumaProfile]
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @Query(sort: \SubjectGradeItem.createdAt) private var gradeItems: [SubjectGradeItem]

    @State private var agendaSettingsPresented = false
    @State private var calendarFeedback = ""

    private let learningEngine = BehaviorLearningEngine()
    private let scheduler = DailyScheduler()
    private let dayChangeTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var recommendations: [PlanRecommendation] {
        appState.dailyRecommendations(from: tasks, planner: planner)
    }

    private var rhythmProfile: UserRhythmProfile {
        learningEngine.profile(from: focusSessions)
    }

    private var planner: TaskPlanner {
        TaskPlanner(
            rhythmProfile: appState.learningEnabled ? rhythmProfile : nil,
            preferredBlockOverride: appState.preferredBlockOverride,
            preferredAreas: Set(profiles.first?.selectedAreas ?? []),
            energyPeak: profiles.first?.energyPeak,
            academicContexts: AcademicPriorityEngine.contexts(
                subjects: subjects,
                items: gradeItems,
                tasks: tasks
            )
        )
    }

    private var taskFingerprint: String {
        let taskValues = tasks.map(taskFingerprintValue).joined(separator: "|")
        let sessionValues = focusSessions.map { session in
            [
                session.id.uuidString,
                String(session.actualMinutes),
                String(session.completedTask),
                String(session.ignoredFromLearning),
            ].joined(separator: ":")
        }.joined(separator: "|")
        let calendarValues = calendarService.commitments.map {
            "\($0.id):\($0.start.timeIntervalSinceReferenceDate):\($0.end.timeIntervalSinceReferenceDate)"
        }.joined(separator: "|")
        let profileValue = profiles.first.map { "\($0.updatedAt.timeIntervalSinceReferenceDate)" } ?? "sin-perfil"
        let academicValues = subjects.map { subject in
            let target = subject.targetGrade.map { String($0) } ?? "sin-objetivo"
            return "\(subject.id):\(target):\(subject.updatedAt.timeIntervalSinceReferenceDate)"
        }.joined(separator: "|") + gradeItems.map {
            "\($0.id):\($0.weightPercent):\($0.updatedAt.timeIntervalSinceReferenceDate)"
        }.joined(separator: "|")
        return "\(taskValues)#\(sessionValues)#\(calendarValues)#\(profileValue)#\(academicValues)#\(appState.learningEnabled)#\(appState.preferredBlockOverrideMinutes)"
    }

    private func taskFingerprintValue(_ task: LumaTask) -> String {
        let deadline = task.deadline.map { String($0.timeIntervalSinceReferenceDate) } ?? "sin-fecha"
        let subject = task.academicSubjectID?.uuidString ?? "sin-materia"
        let category = task.subjectGradeItemID?.uuidString ?? "sin-categoria"
        let grade = task.grade.map { String($0) } ?? "sin-nota"
        let dependency = task.unlocksTaskID?.uuidString ?? "sin-dependencia"
        return [
            task.id.uuidString,
            String(task.updatedAt.timeIntervalSinceReferenceDate),
            task.statusRaw,
            deadline,
            String(task.estimatedMinutes),
            task.energyRaw,
            task.impactRaw,
            String(task.postponementCount),
            String(task.focusedMinutes),
            subject,
            category,
            grade,
            dependency,
        ].joined(separator: ":")
    }

    private var agendaItems: [AgendaDisplayItem] {
        guard let agenda = appState.dailyAgenda else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        return agenda.blocks.compactMap { block in
            guard let task = byID[block.taskID], !task.isCompleted else { return nil }
            return AgendaDisplayItem(
                task: task,
                block: block,
                start: scheduler.date(on: agenda.day, minuteOfDay: block.startMinuteOfDay),
                end: scheduler.date(on: agenda.day, minuteOfDay: block.endMinuteOfDay)
            )
        }
    }

    private var timelineItems: [AgendaTimelineItem] {
        let taskEntries = agendaItems.map { AgendaTimelineItem.task($0) }
        let calendarEntries = calendarService.commitments.map { AgendaTimelineItem.commitment($0) }
        return (taskEntries + calendarEntries).sorted { $0.start < $1.start }
    }

    private var hasTimeToday: Bool {
        appState.isTodayAvailabilityConfirmed
            && (appState.dailyAgenda?.availabilityWindows.isEmpty == false)
    }

    var body: some View {
        @Bindable var appState = appState

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                coachCard

                SectionTitle(
                    eyebrow: "Plan de hoy",
                    title: "Tres cosas, no una lista infinita",
                    trailing: "Carga \(planner.workload(from: tasks).title.lowercased())"
                )

                if appState.learningEnabled, rhythmProfile.isReady {
                    Label(
                        "Plan adaptado · bloques de \(appState.preferredBlockOverride ?? rhythmProfile.preferredBlockMinutes) min",
                        systemImage: "brain.head.profile"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LumaPalette.indigo)
                }

                if recommendations.isEmpty {
                    EmptyStateView(
                        symbol: "checkmark.seal.fill",
                        title: "Está todo en calma",
                        message: "Agregá un pendiente cuando aparezca. Luma va a encontrarle un lugar."
                    )
                } else {
                    VStack(spacing: 12) {
                        ForEach(Array(recommendations.enumerated()), id: \.element.id) { index, recommendation in
                            PriorityCard(index: index + 1, recommendation: recommendation)
                        }
                    }
                }

                actionBar(preference: $appState.energyPreference)
                agendaSection
                upcomingRiskSection
            }
            .padding(30)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .background(Color.clear)
        .navigationTitle("Hoy")
        .onAppear { preparePlan() }
        .onChange(of: taskFingerprint) { _, _ in preparePlan() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { preparePlan() }
        }
        .onReceive(dayChangeTimer) { now in preparePlan(now: now) }
        .sheet(isPresented: $agendaSettingsPresented) {
            AgendaSettingsView()
                .frame(width: 700, height: 680)
        }
        .sheet(item: $appState.pendingReplanProposal) { proposal in
            ReplanPreviewView(
                proposal: proposal,
                tasks: tasks,
                onCancel: {
                    appState.pendingReplanProposal = nil
                    appState.pendingReplanCoachMessage = ""
                },
                onApply: { applyReplan(proposal) }
            )
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) {
                greetingBlock
                Spacer(minLength: 16)
                aiStatusBlock
            }
            VStack(alignment: .leading, spacing: 10) {
                greetingBlock
                aiStatusBlock
            }
        }
    }

    private var greetingBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(LumaPalette.secondaryInk)
            Text("Buen día. Vamos de a poco.")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(LumaPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aiStatusBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(
                aiEngine.state.isBusy ? "Luma está trabajando" : "Todo listo",
                systemImage: aiEngine.state.isBusy ? "sparkles" : "checkmark.circle.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(aiEngine.state.isBusy ? LumaPalette.mustard : LumaPalette.sage)
            Text(aiEngine.state.title)
                .font(.caption2)
                .foregroundStyle(LumaPalette.secondaryInk)
        }
    }

    private var coachCard: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().fill(LumaPalette.indigo.opacity(0.12))
                Image(systemName: "moon.stars.fill")
                    .font(.title2)
                    .foregroundStyle(LumaPalette.indigo)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 6) {
                Text("Luma te recomienda")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LumaPalette.indigo)
                Text(appState.coachMessage)
                    .font(.body)
                    .foregroundStyle(LumaPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
        }
        .lumaCard()
    }

    private func actionBar(preference: Binding<EnergyPreference>) -> some View {
        let standard = replanProposal(
            preference: .normal,
            message: "Listo. Volví a ordenar el día con un ritmo posible y mantuve solo tres prioridades."
        )
        let tired = replanProposal(
            preference: .tired,
            message: "No pasa nada. Bajé la carga y prioricé avances cortos que no te drenen."
        )
        let energized = replanProposal(
            preference: .energized,
            message: "Aprovechemos el envión sin llenar todo el día. Amplié los bloques importantes."
        )

        return Group {
            if standard.changesCurrentPlan || tired.changesCurrentPlan || energized.changesCurrentPlan {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        if standard.changesCurrentPlan { standardReplanButton(standard) }
                        if tired.changesCurrentPlan { tiredReplanButton(tired) }
                        if energized.changesCurrentPlan { energizedReplanButton(energized) }
                        Spacer(minLength: 8)
                        energyLabel(preference.wrappedValue)
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        if standard.changesCurrentPlan { standardReplanButton(standard) }
                        if tired.changesCurrentPlan { tiredReplanButton(tired) }
                        if energized.changesCurrentPlan { energizedReplanButton(energized) }
                        energyLabel(preference.wrappedValue)
                    }
                }
            }
        }
    }

    private func standardReplanButton(_ proposal: ReplanProposal) -> some View {
        Button {
            presentReplan(proposal)
        } label: {
            Label("Reacomodar mi día", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
    }

    private func tiredReplanButton(_ proposal: ReplanProposal) -> some View {
        Button {
            presentReplan(proposal)
        } label: {
            Label("Estoy cansada", systemImage: "battery.25percent")
        }
        .buttonStyle(SoftButtonStyle(color: LumaPalette.lavender))
    }

    private func energizedReplanButton(_ proposal: ReplanProposal) -> some View {
        Button {
            presentReplan(proposal)
        } label: {
            Label("Tengo más tiempo", systemImage: "sun.max.fill")
        }
        .buttonStyle(SoftButtonStyle(color: LumaPalette.mustard))
    }

    private func energyLabel(_ preference: EnergyPreference) -> some View {
        Text(preference.title)
            .font(.caption)
            .foregroundStyle(LumaPalette.secondaryInk)
    }

    private var upcomingRiskSection: some View {
        let risky = tasks.filter { task in
            guard !task.isCompleted else { return false }
            if task.postponementCount > 0 { return true }
            guard let deadline = task.deadline else { return false }
            return deadline < Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
        }

        return VStack(alignment: .leading, spacing: 14) {
            SectionTitle(
                eyebrow: "Radar suave",
                title: "Lo que podría acumularse",
                trailing: risky.isEmpty ? "Sin riesgos" : "\(risky.count) para mirar"
            )

            if risky.isEmpty {
                Text("La semana está respirando bien. No hace falta agregar más por ahora.")
                    .font(.subheadline)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lumaCard()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    ForEach(risky.prefix(3)) { task in
                        VStack(alignment: .leading, spacing: 9) {
                            AreaPill(area: task.area)
                            Text(task.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(LumaPalette.ink)
                                .lineLimit(2)
                            Text(task.postponementCount > 0 ? "Postergada \(task.postponementCount) veces" : "Vence pronto")
                                .font(.caption)
                                .foregroundStyle(LumaPalette.terracotta)
                        }
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                        .lumaCard(padding: 14)
                    }
                }
            }
        }
    }

    private var agendaSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(
                eyebrow: "Agenda dinámica",
                title: "Cuándo hacerlo hoy",
                trailing: appState.dailyAgendaLabel
            )

            if !appState.isTodayAvailabilityConfirmed {
                EmptyStateView(
                    symbol: "calendar.day.timeline.left",
                    title: "¿Cuándo tenés tiempo hoy?",
                    message: "Elegí una opción rápida o armá varios bloques. No se repetirá mañana."
                )
            } else if !hasTimeToday {
                EmptyStateView(
                    symbol: "moon.zzz.fill",
                    title: "Hoy queda libre",
                    message: "No voy a programar tareas. Podés agregar tiempo si tu día cambia."
                )
            } else if agendaItems.isEmpty {
                EmptyStateView(
                    symbol: "clock.badge.checkmark",
                    title: "No hay bloques pendientes",
                    message: "Tu disponibilidad está guardada. Cuando aparezca una prioridad, Luma va a ubicarla ahí."
                )
            } else {
                agendaTimeline
            }

            if calendarService.isEnabled, !calendarService.commitments.isEmpty {
                Label(
                    "Respeté \(calendarService.commitments.count) compromisos de tu calendario",
                    systemImage: "calendar.badge.checkmark"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(LumaPalette.sage)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    agendaActionButtons
                    Spacer(minLength: 8)
                    if calendarService.isAuthorized, calendarService.isEnabled { calendarButton }
                }
                VStack(alignment: .leading, spacing: 9) {
                    agendaActionButtons
                    if calendarService.isAuthorized, calendarService.isEnabled { calendarButton }
                }
            }

            if !calendarFeedback.isEmpty {
                Text(calendarFeedback)
                    .font(.caption)
                    .foregroundStyle(calendarFeedback.hasPrefix("Listo") ? LumaPalette.sage : LumaPalette.terracotta)
            }
        }
    }

    @ViewBuilder
    private var agendaActionButtons: some View {
        if appState.isTodayAvailabilityConfirmed {
            shortDayButton
            extendDayButton
            agendaSettingsButton
        } else {
            quickAvailabilityButton(30)
            quickAvailabilityButton(60)
            quickAvailabilityButton(120)
            dayFreeButton
            agendaSettingsButton
        }
    }

    private func quickAvailabilityButton(_ minutes: Int) -> some View {
        Button { setAvailableMinutes(minutes) } label: {
            Text(minutes == 60 ? "1 hora" : minutes == 120 ? "2 horas" : "30 min")
        }
        .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
    }

    private var dayFreeButton: some View {
        Button { setAvailableMinutes(0) } label: {
            Label("Día libre", systemImage: "moon.zzz.fill")
        }
        .buttonStyle(SoftButtonStyle(color: LumaPalette.lavender))
    }

    private var shortDayButton: some View {
        Button {
            proposeReplan(
                preference: appState.energyPreference,
                availableMinutes: 30,
                message: "Reducir el día a un solo avance posible de 30 minutos."
            )
        } label: {
            Label("Solo tengo 30 min", systemImage: "hourglass.bottomhalf.filled")
        }
        .buttonStyle(SoftButtonStyle(color: LumaPalette.lavender))
    }

    private var extendDayButton: some View {
        Button {
            let current = appState.dailyAgenda?.availableMinutes ?? 120
            proposeReplan(
                preference: appState.energyPreference,
                availableMinutes: min(480, current + 30),
                message: "Sumar 30 minutos y repartirlos sin llenar cada hueco."
            )
        } label: {
            Label("Sumar 30 min", systemImage: "plus.circle")
        }
        .buttonStyle(SoftButtonStyle(color: LumaPalette.mustard))
    }

    private var agendaSettingsButton: some View {
        Button { agendaSettingsPresented = true } label: {
            Label("Ajustar disponibilidad", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
    }

    private var calendarButton: some View {
        Button { syncCalendar() } label: {
            Label("Enviar al Calendario", systemImage: "calendar.badge.plus")
        }
        .buttonStyle(SoftButtonStyle(color: LumaPalette.sage))
    }

    private var agendaTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { timelineMetrics }
                VStack(alignment: .leading, spacing: 8) { timelineMetrics }
            }

            HStack(spacing: 6) {
                Image(systemName: "hand.draw")
                Text("Arrastrá un bloque hacia arriba o abajo para moverlo; el resto se acomoda solo.")
            }
            .font(.caption)
            .foregroundStyle(LumaPalette.secondaryInk)

            VStack(spacing: 0) {
                ForEach(Array(timelineItems.enumerated()), id: \.element.id) { index, entry in
                    timelineRow(entry)
                    if index < timelineItems.count - 1 {
                        let gap = max(0, Int(timelineItems[index + 1].start.timeIntervalSince(entry.end) / 60))
                        if gap >= 10 {
                            HStack(spacing: 10) {
                                Rectangle()
                                    .fill(LumaPalette.sage.opacity(0.28))
                                    .frame(width: 2, height: 22)
                                    .padding(.leading, 32)
                                Text(gap >= 30 ? "\(gap) min libres" : "Pausa de \(gap) min")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(LumaPalette.sage)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        } else {
                            Divider().opacity(0.36).padding(.vertical, 5)
                        }
                    }
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private var timelineMetrics: some View {
        timelineMetric(
            "Disponible",
            minutes: appState.dailyAgenda?.availableMinutes ?? 0,
            color: LumaPalette.sage
        )
        timelineMetric(
            "Planificado",
            minutes: agendaItems.reduce(0) { $0 + $1.block.durationMinutes },
            color: LumaPalette.indigo
        )
        timelineMetric(
            "Compromisos",
            minutes: calendarService.commitments.reduce(0) {
                $0 + max(0, Int($1.end.timeIntervalSince($1.start) / 60))
            },
            color: LumaPalette.lavender
        )
    }

    private func timelineMetric(_ title: String, minutes: Int, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(title) · \(durationTitle(minutes))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LumaPalette.secondaryInk)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.46), in: Capsule())
    }

    @ViewBuilder
    private func timelineRow(_ entry: AgendaTimelineItem) -> some View {
        switch entry {
        case let .task(item):
            DraggableAgendaRow(
                item: item,
                onStart: {
                    appState.startFocus(
                        for: item.task.id,
                        durationMinutes: item.block.durationMinutes
                    )
                },
                onMove: { moveAgenda(item, to: $0) }
            )
        case let .commitment(commitment):
            HStack(spacing: 14) {
                timelineTime(start: commitment.start, end: commitment.end)
                RoundedRectangle(cornerRadius: 3)
                    .fill(LumaPalette.lavender)
                    .frame(width: 5, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(commitment.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                    Label("Compromiso del calendario", systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
            }
            .padding(.vertical, 8)
        }
    }

    private func timelineTime(start: Date, end: Date) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(start, format: .dateTime.hour().minute())
                .font(.caption.weight(.semibold).monospacedDigit())
            Text(end, format: .dateTime.hour().minute())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(LumaPalette.secondaryInk)
        }
        .foregroundStyle(LumaPalette.ink)
        .frame(width: 58, alignment: .trailing)
    }

    private func agendaRow(_ item: AgendaDisplayItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                agendaTime(item)
                agendaAccent(item)
                agendaTaskInfo(item)
                Spacer(minLength: 8)
                agendaStartButton(item)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    agendaTime(item)
                    agendaAccent(item)
                    agendaTaskInfo(item)
                }
                agendaStartButton(item)
            }
        }
        .lumaCard(padding: 14)
    }

    private func agendaTime(_ item: AgendaDisplayItem) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(item.start, format: .dateTime.hour().minute())
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(LumaPalette.ink)
            Text(item.end, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(LumaPalette.secondaryInk)
        }
        .frame(width: 66, alignment: .trailing)
    }

    private func agendaAccent(_ item: AgendaDisplayItem) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(item.task.area.color)
            .frame(width: 5, height: 44)
    }

    private func agendaTaskInfo(_ item: AgendaDisplayItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.task.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LumaPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { agendaMetadata(item) }
                VStack(alignment: .leading, spacing: 5) { agendaMetadata(item) }
            }
        }
        .layoutPriority(1)
    }

    @ViewBuilder
    private func agendaMetadata(_ item: AgendaDisplayItem) -> some View {
        AreaPill(area: item.task.area)
        Text("\(item.block.durationMinutes) min")
            .font(.caption)
            .foregroundStyle(LumaPalette.secondaryInk)
        if item.task.focusedMinutes > 0 {
            Text("\(item.task.focusedMinutes) min avanzados")
                .font(.caption)
                .foregroundStyle(LumaPalette.sage)
        }
    }

    private func agendaStartButton(_ item: AgendaDisplayItem) -> some View {
        Button {
            appState.startFocus(
                for: item.task.id,
                durationMinutes: item.block.durationMinutes
            )
        } label: {
            Label("Empezar", systemImage: "play.fill")
        }
        .buttonStyle(SoftButtonStyle(color: item.task.area.color))
    }

    private func preparePlan(now: Date = .now) {
        calendarService.refreshCommitments(for: now)
        let update = appState.prepareDailyPlan(from: tasks, planner: planner, now: now)
        appState.prepareDailyAgenda(
            from: tasks,
            planner: planner,
            scheduler: scheduler,
            now: now,
            force: update.rolledOver,
            preferredStartMinuteOfDay: preferredAgendaStart,
            busyBlocks: calendarService.busyBlocks(for: now)
        )
        Task { await notificationService.scheduleAgenda(appState.dailyAgenda, tasks: tasks, now: now) }
        guard update.rolledOver else { return }

        if update.postponedCount > 0 {
            let noun = update.postponedCount == 1 ? "prioridad" : "prioridades"
            appState.coachMessage = "No pasa nada. Reacomodé \(update.postponedCount) \(noun) que quedó pendiente y bajé la presión del día anterior."
        } else {
            appState.coachMessage = "Nuevo día, plan nuevo. Elegí tres avances posibles sin arrastrar carga innecesaria."
        }
        try? modelContext.save()
    }

    private func proposeReplan(
        preference: EnergyPreference,
        availableMinutes: Int? = nil,
        message: String
    ) {
        presentReplan(replanProposal(
            preference: preference,
            availableMinutes: availableMinutes,
            message: message
        ))
    }

    private func replanProposal(
        preference: EnergyPreference,
        availableMinutes: Int? = nil,
        message: String
    ) -> ReplanProposal {
        ReplanProposalBuilder.make(
            source: .dashboard,
            explanation: message,
            tasks: tasks,
            currentPlan: appState.dailyPlan,
            currentAgenda: appState.dailyAgenda,
            currentEnergy: appState.energyPreference,
            proposedEnergy: preference,
            proposedAvailableMinutes: availableMinutes,
            planner: planner,
            scheduler: scheduler,
            busyBlocks: calendarService.busyBlocks()
        )
    }

    private func presentReplan(_ proposal: ReplanProposal) {
        guard proposal.changesCurrentPlan else { return }
        appState.pendingReplanProposal = proposal
        appState.pendingReplanCoachMessage = proposal.explanation
    }

    private func applyReplan(_ proposal: ReplanProposal) {
        appState.applyReplan(proposal)
        modelContext.insert(LumaReplanRecord(proposal: proposal))
        try? modelContext.save()
        appState.coachMessage = appState.pendingReplanCoachMessage.isEmpty
            ? "Listo. Apliqué únicamente los cambios que revisaste."
            : appState.pendingReplanCoachMessage
        appState.pendingReplanProposal = nil
        appState.pendingReplanCoachMessage = ""
        Task { await notificationService.scheduleAgenda(appState.dailyAgenda, tasks: tasks) }
        appState.registerUndo(message: "Plan reacomodado") {
            appState.restoreReplan(proposal)
            Task { await notificationService.scheduleAgenda(appState.dailyAgenda, tasks: tasks) }
        }
    }

    private func setAvailableMinutes(_ minutes: Int) {
        appState.configureDailyAgenda(
            availableMinutes: minutes,
            startMinuteOfDay: appState.dailyAgenda?.startMinuteOfDay ?? scheduler.defaultStartMinute(),
            tasks: tasks,
            planner: planner,
            scheduler: scheduler,
            busyBlocks: calendarService.busyBlocks()
        )
        appState.coachMessage = minutes == 0
            ? "Listo. Hoy queda libre y no voy a empujarte tareas."
            : "Perfecto. Organicé solamente lo que entra en esos \(minutes) minutos de hoy."
        Task { await notificationService.scheduleAgenda(appState.dailyAgenda, tasks: tasks) }
    }

    private func syncCalendar() {
        do {
            try calendarService.syncAgenda(appState.dailyAgenda, tasks: tasks)
            calendarFeedback = "Listo. El plan de hoy quedó en Calendario."
        } catch {
            calendarFeedback = "No pude enviar el plan: \(error.localizedDescription)"
        }
    }

    private func moveAgenda(_ item: AgendaDisplayItem, to startMinuteOfDay: Int) {
        guard let before = appState.dailyAgenda else { return }
        appState.moveAgendaBlock(
            taskID: item.task.id,
            to: startMinuteOfDay,
            scheduler: scheduler,
            busyBlocks: calendarService.busyBlocks()
        )
        guard appState.dailyAgenda != before else { return }
        Task { await notificationService.scheduleAgenda(appState.dailyAgenda, tasks: tasks) }
        appState.registerUndo(message: "Bloque movido en la agenda") {
            appState.restoreAgenda(before)
            Task { await notificationService.scheduleAgenda(appState.dailyAgenda, tasks: tasks) }
        }
    }

    private func durationTitle(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) min" }
        if remainder == 0 { return hours == 1 ? "1 h" : "\(hours) h" }
        return "\(hours) h \(remainder) min"
    }

    private var preferredAgendaStart: Int? {
        guard appState.learningEnabled, rhythmProfile.isReady,
              let hour = rhythmProfile.bestStartHour
        else { return nil }
        return hour * 60
    }
}

private struct AgendaDisplayItem: Identifiable {
    let task: LumaTask
    let block: AgendaBlockSnapshot
    let start: Date
    let end: Date

    var id: UUID { task.id }
}

private enum AgendaTimelineItem: Identifiable {
    case task(AgendaDisplayItem)
    case commitment(CalendarCommitment)

    var id: String {
        switch self {
        case let .task(item): "task-\(item.id.uuidString)"
        case let .commitment(item): "calendar-\(item.id)"
        }
    }

    var start: Date {
        switch self {
        case let .task(item): item.start
        case let .commitment(item): item.start
        }
    }

    var end: Date {
        switch self {
        case let .task(item): item.end
        case let .commitment(item): item.end
        }
    }
}

private struct DraggableAgendaRow: View {
    let item: AgendaDisplayItem
    let onStart: () -> Void
    let onMove: (Int) -> Void

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.start, format: .dateTime.hour().minute())
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text(item.end, format: .dateTime.hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
            .foregroundStyle(LumaPalette.ink)
            .frame(width: 58, alignment: .trailing)

            RoundedRectangle(cornerRadius: 3)
                .fill(item.task.area.color)
                .frame(width: 5, height: 44)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.task.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    AreaPill(area: item.task.area)
                    Text("\(item.block.durationMinutes) min")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Image(systemName: "line.3.horizontal")
                .foregroundStyle(LumaPalette.secondaryInk.opacity(0.7))
                .help("Arrastrar para mover")

            Button(action: onStart) {
                Image(systemName: "play.fill")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(item.task.area.color)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(item.task.area.color.opacity(dragOffset == 0 ? 0.03 : 0.11), in: RoundedRectangle(cornerRadius: 12))
        .offset(y: dragOffset)
        .zIndex(dragOffset == 0 ? 0 : 3)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { dragOffset = $0.translation.height }
                .onEnded { value in
                    let stepCount = Int((value.translation.height / 26).rounded())
                    dragOffset = 0
                    guard stepCount != 0 else { return }
                    onMove(item.block.startMinuteOfDay + stepCount * 15)
                }
        )
        .contextMenu {
            Button("Mover 15 min antes", systemImage: "arrow.up") {
                onMove(item.block.startMinuteOfDay - 15)
            }
            Button("Mover 15 min después", systemImage: "arrow.down") {
                onMove(item.block.startMinuteOfDay + 15)
            }
        }
    }
}

private struct PriorityCard: View {
    @Environment(AppState.self) private var appState
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    let index: Int
    let recommendation: PlanRecommendation
    @State private var editingTask = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                priorityNumber
                taskSummary
                Spacer(minLength: 10)
                priorityActions
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    priorityNumber
                    taskSummary
                }
                priorityActions
            }
        }
        .lumaCard(padding: 15)
        .sheet(isPresented: $editingTask) {
            TaskEditorView(task: recommendation.task)
                .frame(width: 720, height: 690)
        }
    }

    private var priorityNumber: some View {
        Text("\(index)")
            .font(.title3.weight(.bold))
            .foregroundStyle(recommendation.task.area.color)
            .frame(width: 38, height: 38)
            .background(recommendation.task.area.color.opacity(0.12), in: Circle())
    }

    private var taskSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    AreaPill(area: recommendation.task.area)
                    Label("\(recommendation.suggestedMinutes) min", systemImage: "timer")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                VStack(alignment: .leading, spacing: 5) {
                    AreaPill(area: recommendation.task.area)
                    Label("\(recommendation.suggestedMinutes) min", systemImage: "timer")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
            }
            Text(recommendation.task.title)
                .font(.headline)
                .foregroundStyle(LumaPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(recommendation.reason)
                .font(.subheadline)
                .foregroundStyle(LumaPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .layoutPriority(1)
    }

    private var priorityActions: some View {
        HStack(spacing: 7) {
            Button {
                editingTask = true
            } label: {
                Image(systemName: "pencil")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .help("Editar pendiente")

            Button {
                appState.startFocus(
                    for: recommendation.task.id,
                    durationMinutes: recommendation.suggestedMinutes
                )
            } label: {
                Image(systemName: "play.fill")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    recommendation.task.markCompleted()
                    appState.refreshPlan()
                }
                try? modelContext.save()
                try? calendarService.syncTask(recommendation.task)
                appState.registerUndo(message: "Tarea completada") {
                    recommendation.task.restore()
                    try? modelContext.save()
                    try? calendarService.syncTask(recommendation.task)
                    appState.refreshPlan()
                }
            } label: {
                Image(systemName: "checkmark")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(LumaPalette.sage)
        }
        .fixedSize()
    }
}
