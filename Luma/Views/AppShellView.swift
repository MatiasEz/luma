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
    @State private var viewModel = AppShellViewModel()

    private let learningEngine = BehaviorLearningEngine()
    private let scheduler = DailyScheduler()

    var body: some View {
        @Bindable var appState = appState

        ZStack {
            LumaBackground()

            NavigationSplitView {
                sidebar(selection: $appState.selection)
                    .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
            } detail: {
                detail
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
            QuickCaptureView()
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
            try? await Task.sleep(for: .seconds(1))
            await cloudSyncService.sync(
                tasks: tasks,
                sessions: focusSessions,
                profiles: profiles,
                messages: chatMessages,
                replans: replanRecords,
                subjects: subjects,
                subjectGradeItems: subjectGradeItems,
                context: modelContext
            )
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
                    Label("Preguntale a Luma", systemImage: "bubble.left.fill")
                }

                Button {
                    appState.quickCapturePresented = true
                } label: {
                    Label("Nuevo pendiente", systemImage: "plus")
                }
            }
        }
    }

    private func handleNotificationAction() {
        guard let action = notificationService.lastAction else { return }
        let profile = learningEngine.profile(from: focusSessions)
        let planner = TaskPlanner(
            rhythmProfile: appState.learningEnabled ? profile : nil,
            preferredBlockOverride: appState.preferredBlockOverride,
            preferredAreas: Set(profiles.first?.selectedAreas ?? []),
            energyPeak: profiles.first?.energyPeak,
            academicContexts: AcademicPriorityEngine.contexts(
                subjects: subjects,
                items: subjectGradeItems,
                tasks: tasks
            )
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
        List(selection: selection) {
            Section {
                ForEach(NavigationItem.allCases) { item in
                    HStack(spacing: 8) {
                        Label(item.title, systemImage: item.symbol)
                        Spacer(minLength: 6)
                        if item == .attention, attentionCount > 0 {
                            Text("\(attentionCount)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(LumaPalette.terracotta, in: Capsule())
                        }
                    }
                        .tag(item)
                        .padding(.vertical, 5)
                }
            }

            Section("Estado") {
                HStack(spacing: 9) {
                    Circle()
                        .fill(aiEngine.state.isBusy ? LumaPalette.mustard : LumaPalette.sage)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(aiEngine.state.isBusy ? "Luma trabajando" : "Todo listo")
                            .font(.caption.weight(.semibold))
                        Text(aiEngine.isInstalled || aiEngine.isStudyModelInstalled ? "Funciones preparadas" : "Organización básica")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)

                HStack(spacing: 9) {
                    Circle()
                        .fill(cloudSyncService.state == .synced ? LumaPalette.sage : LumaPalette.lavender)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cloudSyncService.state.title)
                            .font(.caption.weight(.semibold))
                        Text(cloudSyncService.isConfigured ? "Supabase · caché local activa" : "Solo en esta Mac")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
            }
        }
        .navigationTitle("Luma")
        .scrollContentBackground(.hidden)
        .background(Color.white.opacity(0.22))
    }

    private var cloudFingerprint: String {
        viewModel.cloudFingerprint(
            tasks: tasks,
            sessions: focusSessions,
            profiles: profiles,
            messages: chatMessages,
            replans: replanRecords,
            subjects: subjects,
            gradeItems: subjectGradeItems
        )
    }

    private var attentionCount: Int {
        viewModel.attentionCount(
            tasks: tasks,
            subjects: subjects,
            gradeItems: subjectGradeItems,
            cloudState: cloudSyncService.state,
            calendarError: calendarService.lastError
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selection ?? .today {
        case .today: DashboardView()
        case .inbox: InboxView()
        case .attention: AttentionView()
        case .week: WeekView()
        case .subjects: SubjectsView()
        case .balance: BalanceView()
        case .insights: InsightsView()
        case .focus: FocusRoomView()
        }
    }
}
