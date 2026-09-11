import SwiftData
import SwiftUI

struct AppShellView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalAIEngine.self) private var aiEngine
    @Environment(NotificationService.self) private var notificationService
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(CloudSyncService.self) private var cloudSyncService
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]
    @Query(sort: \FocusSession.endedAt, order: .reverse) private var focusSessions: [FocusSession]
    @Query(sort: \LumaProfile.createdAt) private var profiles: [LumaProfile]
    @Query(sort: \LumaChatRecord.createdAt) private var chatMessages: [LumaChatRecord]
    @Query(sort: \LumaReplanRecord.createdAt) private var replanRecords: [LumaReplanRecord]
    @Query(sort: \AcademicSubject.updatedAt) private var subjects: [AcademicSubject]
    @Query(sort: \SubjectGradeItem.updatedAt) private var subjectGradeItems: [SubjectGradeItem]
    @Query(sort: \SubjectClassMeeting.updatedAt) private var classMeetings: [SubjectClassMeeting]
    @Query(sort: \AcademicRoutine.updatedAt) private var routines: [AcademicRoutine]
    @Query(sort: \AcademicExam.updatedAt) private var exams: [AcademicExam]
    @Query(sort: \DailyPlanningContext.updatedAt) private var dailyContexts: [DailyPlanningContext]
    @State private var viewModel = AppShellViewModel()
    @FocusState private var focusedNavigation: NavigationItem?

    private let learningEngine = BehaviorLearningEngine()
    private let scheduler = DailyScheduler()

    private var todayContext: DailyPlanningContext? {
        dailyContexts.first { Calendar.current.isDateInToday($0.day) }
    }

    var body: some View {
        @Bindable var appState = appState

        ZStack {
            LumaBackground()

            NavigationSplitView {
                sidebar(selection: $appState.selection)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
            } detail: {
                detail
                    .frame(minWidth: 0, maxWidth: .infinity)
            }
            .navigationSplitViewStyle(.balanced)
            .inspector(isPresented: $appState.assistantPresented) {
                LumaAssistantView()
                    .inspectorColumnWidth(min: 310, ideal: 360, max: 420)
            }

            if let undoMessage = appState.undoMessage {
                VStack {
                    Spacer()
                    HStack(spacing: 14) {
                        Label(undoMessage, systemImage: "arrow.uturn.backward.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LumaPalette.ink)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Button("Deshacer") { appState.performUndo() }
                            .buttonStyle(.borderedProminent)
                            .tint(LumaPalette.indigo)
                        Button {
                            appState.clearUndo()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(LumaPalette.secondaryInk)
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.7))
                    }
                    .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(20)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: appState.undoMessage)
        .tint(LumaPalette.indigo)
        .sheet(isPresented: $appState.quickCapturePresented) {
            QuickCaptureView(initialText: appState.quickCaptureSeed)
                .environment(aiEngine)
                .frame(width: 720, height: 700)
        }
        .sheet(isPresented: Binding(
            get: { !appState.onboardingCompleted || profiles.isEmpty },
            set: { _ in }
        )) {
            OnboardingView()
                .interactiveDismissDisabled()
        }
        .task {
            GlobalShortcutController.shared.register()
            calendarService.refreshCommitments()
        }
        .task(id: cloudFingerprint) {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            // The fingerprint task is only the debounce. The sync itself must not
            // inherit its cancellation: pulling or repairing SwiftData changes the
            // fingerprint and would otherwise cancel the request halfway through.
            Task { @MainActor in
                await cloudSyncService.sync(
                    tasks: tasks,
                    sessions: focusSessions,
                    profiles: profiles,
                    messages: chatMessages,
                    replans: replanRecords,
                    subjects: subjects,
                    subjectGradeItems: subjectGradeItems,
                    classMeetings: classMeetings,
                    routines: routines,
                    exams: exams,
                    dailyContexts: dailyContexts,
                    context: modelContext
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumaQuickCaptureRequested)) { _ in
            NSApp.activate(ignoringOtherApps: true)
            appState.quickCapturePresented = true
        }
        .onChange(of: notificationService.lastAction?.id) { _, _ in
            handleNotificationAction()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appState.assistantPresented.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left")
                        Text("Asistente")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(LumaHomeStyle.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .help(appState.assistantPresented ? "Cerrar el asistente" : "Abrir el asistente")

                Button {
                    appState.quickCapturePresented = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Nuevo pendiente")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(LumaHomeStyle.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(LumaHomeStyle.paper, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(LumaHomeStyle.line, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .help("Anotar un nuevo pendiente")
            }
        }
    }

    private func handleNotificationAction() {
        guard let action = notificationService.lastAction else { return }
        let profile = learningEngine.profile(from: focusSessions)
        let context = todayContext
        let planner = TaskPlanner(
            rhythmProfile: appState.learningEnabled ? profile : nil,
            preferredBlockOverride: appState.preferredBlockOverride,
            preferredAreas: Set(profiles.first?.selectedAreas ?? []),
            energyPeak: profiles.first?.energyPeak,
            availableMinutes: appState.remainingAvailableMinutes(fallback: context?.availableMinutes ?? 120),
            planningMode: context?.planningMode ?? .realistic,
            classMeetings: classMeetings,
            subjectNames: Dictionary(uniqueKeysWithValues: subjects.map { ($0.id, $0.name) }),
            weeklyAvailability: appState.weeklyAvailability,
            restCounts: context?.restCounts ?? true
        )

        switch action.kind {
        case .start:
            if let taskID = action.taskID { appState.startFocus(for: taskID) }
        case .snooze:
            appState.coachMessage = "Listo. Te aviso de nuevo en 15 minutos, sin mover el resto del día."
            appState.selection = .today
        case .tired:
            proposeNotificationReplan(
                planner: planner,
                preference: .tired,
                explanation: "Bajar la carga y elegir avances cortos para tu energía actual."
            )
        case .replan:
            proposeNotificationReplan(
                planner: planner,
                preference: appState.energyPreference,
                explanation: "Reordenar lo pendiente sin tocar lo que ya terminaste."
            )
        }
    }

    private func proposeNotificationReplan(
        planner: TaskPlanner,
        preference: EnergyPreference,
        explanation: String
    ) {
        appState.pendingReplanProposal = ReplanProposalBuilder.make(
            source: .notification,
            explanation: explanation,
            tasks: tasks,
            currentPlan: appState.dailyPlan,
            currentAgenda: appState.dailyAgenda,
            currentEnergy: appState.energyPreference,
            proposedEnergy: preference,
            currentAvailableMinutes: appState.remainingAvailableMinutes(fallback: todayContext?.availableMinutes ?? 120),
            timeBudget: appState.dailyTimeBudget,
            planner: planner,
            scheduler: scheduler,
            busyBlocks: calendarService.busyBlocks()
        )
        appState.pendingReplanCoachMessage = explanation
        appState.selection = .today
    }

    private func rebuildAgenda(planner: TaskPlanner) {
        appState.prepareDailyAgenda(
            from: tasks,
            planner: planner,
            scheduler: scheduler,
            force: true,
            busyBlocks: calendarService.busyBlocks()
        )
        appState.selection = .today
        Task { await notificationService.scheduleAgenda(appState.dailyAgenda, tasks: tasks) }
    }

    private func sidebar(selection: Binding<NavigationItem?>) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    navigationGroup("Tu día", items: [.today, .inbox, .week, .focus], selection: selection)
                    navigationGroup("Estudio y hábitos", items: [.subjects, .exams, .routines], selection: selection)
                }
                .padding(.horizontal, 14)
                .padding(.top, 24)
                .padding(.bottom, 18)
            }
            .onMoveCommand { direction in
                let items: [NavigationItem] = [.today, .inbox, .week, .focus, .subjects, .exams, .routines]
                guard let focusedNavigation,
                      let index = items.firstIndex(of: focusedNavigation) else { return }
                let nextIndex: Int
                switch direction {
                case .up: nextIndex = max(0, index - 1)
                case .down: nextIndex = min(items.count - 1, index + 1)
                default: return
                }
                self.focusedNavigation = items[nextIndex]
                selection.wrappedValue = items[nextIndex]
            }

            sidebarStatus
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Luma")
        .background(LumaHomeStyle.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(LumaHomeStyle.line)
                .frame(width: 1)
                .allowsHitTesting(false)
        }
    }

    private func navigationGroup(
        _ title: String,
        items: [NavigationItem],
        selection: Binding<NavigationItem?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(LumaHomeStyle.muted)
                .padding(.horizontal, 12)
                .padding(.bottom, 3)
                .accessibilityAddTraits(.isHeader)

            ForEach(items) { item in
                let isSelected = (selection.wrappedValue ?? .today) == item
                Button {
                    selection.wrappedValue = item
                    focusedNavigation = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: navigationSymbol(for: item))
                            .font(.system(size: 15, weight: .regular))
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text(item.title)
                            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(isSelected ? LumaHomeStyle.accent : LumaHomeStyle.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isSelected ? LumaHomeStyle.tint : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedNavigation, equals: item)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("sidebar-\(item.rawValue)")
            }
        }
    }

    private func navigationSymbol(for item: NavigationItem) -> String {
        switch item {
        case .today: "sun.max"
        case .inbox: "tray"
        case .week: "calendar"
        case .focus: "headphones"
        case .subjects: "book"
        case .exams: "graduationcap"
        case .routines: "repeat"
        }
    }

    private var sidebarStatus: some View {
        VStack(alignment: .leading, spacing: 14) {
            if aiEngine.state.isBusy {
                Label(aiEngine.state.title, systemImage: "ellipsis.bubble")
                    .font(.system(size: 12))
            } else if case let .failed(message) = aiEngine.state {
                Label("El asistente necesita atención", systemImage: "exclamationmark.bubble")
                    .font(.system(size: 12))
                    .help(message)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 13))
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Guardado en esta Mac")
                        .font(.system(size: 11))
                    if let cloudStatusDetail {
                        Text(cloudStatusDetail)
                            .font(.system(size: 11))
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .help(cloudSyncService.lastErrorMessage ?? cloudStatusDetail ?? "Tus datos se guardan en esta Mac.")
        }
        .foregroundStyle(LumaHomeStyle.muted)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cloudStatusDetail: String? {
        guard cloudSyncService.isConfigured else { return nil }
        switch cloudSyncService.state {
        case .unconfigured: return nil
        case .offline: return "Sin conexión con la nube"
        case .connecting: return "Conectando con la nube…"
        case .syncing: return "Sincronizando cambios…"
        case .synced: return "También en la nube"
        case .failed: return "No se pudo sincronizar"
        }
    }

    private var cloudFingerprint: String {
        viewModel.cloudFingerprint(
            tasks: tasks,
            sessions: focusSessions,
            profiles: profiles,
            messages: chatMessages,
            replans: replanRecords,
            subjects: subjects,
            gradeItems: subjectGradeItems,
            classMeetings: classMeetings,
            routines: routines,
            exams: exams,
            dailyContexts: dailyContexts
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selection ?? .today {
        case .today: DashboardView()
        case .inbox: InboxView()
        case .week: WeekView()
        case .subjects: SubjectsView()
        case .focus: FocusRoomView()
        case .routines: RoutinesView()
        case .exams: ExamsView()
        }
    }
}
