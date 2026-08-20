import SwiftData
import SwiftUI

struct InsightsView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalAIEngine.self) private var aiEngine
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FocusSession.endedAt, order: .reverse) private var sessions: [FocusSession]

    @State private var aiSummary: String?
    @State private var deleteConfirmationPresented = false
    @State private var ignoreWeekConfirmationPresented = false

    private let engine = BehaviorLearningEngine()

    private var profile: UserRhythmProfile {
        engine.profile(from: sessions)
    }

    var body: some View {
        @Bindable var appState = appState

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionTitle(
                    eyebrow: "Aprendizaje local",
                    title: "Lo que Luma aprendió",
                    trailing: sessions.isEmpty ? "Sin historial" : "\(profile.sessionCount) sesiones útiles"
                )

                privacyCard

                if !appState.learningEnabled {
                    disabledCard
                } else if !profile.isReady {
                    learningProgressCard
                } else {
                    learnedPatterns
                }

                weeklyReview
                recentSessions
                controls(appState: $appState)
            }
            .padding(30)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle("Aprendizajes")
        .alert("¿Ignorar esta semana?", isPresented: $ignoreWeekConfirmationPresented) {
            Button("Cancelar", role: .cancel) {}
            Button("Ignorar semana") { ignoreCurrentWeek() }
        } message: {
            Text("Las sesiones seguirán guardadas, pero no influirán en las recomendaciones.")
        }
        .alert("¿Borrar todo el historial?", isPresented: $deleteConfirmationPresented) {
            Button("Cancelar", role: .cancel) {}
            Button("Borrar historial", role: .destructive) { deleteHistory() }
        } message: {
            Text("Se eliminarán los patrones y las sesiones registradas. Tus tareas no se borrarán.")
        }
    }

    private var privacyCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(LumaPalette.sage)
                .frame(width: 46, height: 46)
                .background(LumaPalette.sage.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text("Aprende solo en esta Mac")
                    .font(.headline)
                    .foregroundStyle(LumaPalette.ink)
                Text("Tus hábitos se calculan de forma privada y se usan para adaptar el plan a tu ritmo.")
                    .font(.subheadline)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
            Spacer()
        }
        .lumaCard(padding: 18)
    }

    private var disabledCard: some View {
        EmptyStateView(
            symbol: "pause.circle.fill",
            title: "Aprendizaje pausado",
            message: "Focus Room sigue funcionando, pero las nuevas sesiones no se usan para adaptar tu plan."
        )
    }

    private var learningProgressCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    learningProgressDescription
                    Spacer(minLength: 12)
                    learningProgressCount
                }
                VStack(alignment: .leading, spacing: 8) {
                    learningProgressDescription
                    learningProgressCount
                }
            }

            ProgressView(value: profile.learningProgress)
                .tint(LumaPalette.indigo)

            Text(
                profile.sessionsUntilReady == 1
                    ? "Falta una sesión para empezar a adaptar el plan."
                    : "Faltan \(profile.sessionsUntilReady) sesiones para empezar a adaptar el plan."
            )
            .font(.caption)
            .foregroundStyle(LumaPalette.secondaryInk)
        }
        .lumaCard(padding: 18)
    }

    private var learningProgressDescription: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Luma todavía está observando")
                .font(.headline)
                .foregroundStyle(LumaPalette.ink)
            Text("No va a cambiar tus recomendaciones con muy poca información.")
                .font(.subheadline)
                .foregroundStyle(LumaPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var learningProgressCount: some View {
        Text("\(profile.sessionCount)/\(UserRhythmProfile.minimumSessionCount)")
            .font(.title2.weight(.semibold).monospacedDigit())
            .foregroundStyle(LumaPalette.indigo)
    }

    private var learnedPatterns: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(
                eyebrow: "Patrones con confianza",
                title: "Tu ritmo más probable",
                trailing: "Últimos 30 días"
            )

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                LearningInsightCard(
                    symbol: "timer",
                    title: "Bloque que mejor encaja",
                    value: "\(appState.preferredBlockOverride ?? profile.preferredBlockMinutes) min",
                    detail: appState.preferredBlockOverride == nil ? "Detectado por tus sesiones" : "Elegido por vos",
                    color: LumaPalette.indigo
                )
                LearningInsightCard(
                    symbol: "clock.fill",
                    title: "Horario más frecuente",
                    value: profile.bestWindowTitle,
                    detail: "Luma lo usa como sugerencia, no como obligación",
                    color: LumaPalette.mustard
                )
                LearningInsightCard(
                    symbol: profile.topArea?.symbol ?? "square.grid.2x2.fill",
                    title: "Área más trabajada",
                    value: profile.topArea?.title ?? "Variada",
                    detail: "Según minutos reales de concentración",
                    color: profile.topArea?.color ?? LumaPalette.sage
                )
                LearningInsightCard(
                    symbol: "chart.line.uptrend.xyaxis",
                    title: "Estimaciones",
                    value: profile.estimationTitle,
                    detail: "Comparación entre tiempo planeado y real",
                    color: LumaPalette.terracotta
                )
            }
        }
    }

    private var weeklyReview: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(
                eyebrow: "Revisión semanal",
                title: "Una lectura breve, sin juicio",
                trailing: "\(profile.weeklyMinutes) min"
            )

            VStack(alignment: .leading, spacing: 14) {
                Text(aiSummary ?? engine.weeklySummary(for: profile))
                    .font(.body)
                    .foregroundStyle(LumaPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if aiEngine.isInstalled, profile.weeklySessionCount > 0 {
                    HStack {
                        Spacer()
                        Button {
                            Task { await rewriteWeeklySummary() }
                        } label: {
                            if aiEngine.state.isBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Mejorar explicación", systemImage: "sparkles")
                            }
                        }
                        .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
                        .disabled(aiEngine.state.isBusy)
                    }
                }
            }
            .lumaCard(padding: 18)
        }
    }

    @ViewBuilder
    private var recentSessions: some View {
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(
                    eyebrow: "Historial",
                    title: "Sesiones recientes",
                    trailing: "Todo queda local"
                )

                ForEach(sessions.prefix(5)) { session in
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) {
                            sessionIdentity(session)
                            Spacer(minLength: 10)
                            sessionStats(session)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            sessionIdentity(session)
                            sessionStats(session)
                        }
                    }
                    .lumaCard(padding: 13)
                }
            }
        }
    }

    private func sessionIdentity(_ session: FocusSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: session.completedTask ? "checkmark.circle.fill" : "timer")
                .foregroundStyle(session.completedTask ? LumaPalette.sage : session.area.color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.taskTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(session.endedAt, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
        }
        .layoutPriority(1)
    }

    private func sessionStats(_ session: FocusSession) -> some View {
        HStack(spacing: 8) {
            if session.ignoredFromLearning {
                Text("Ignorada")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
            Text("\(session.actualMinutes) de \(session.plannedMinutes) min")
                .font(.caption.monospacedDigit())
                .foregroundStyle(LumaPalette.secondaryInk)
        }
    }

    private func controls(appState: Bindable<AppState>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(
                eyebrow: "Vos tenés el control",
                title: "Corregir o pausar conclusiones"
            )

            VStack(alignment: .leading, spacing: 16) {
                Toggle("Permitir que Luma aprenda de Focus Room", isOn: appState.learningEnabled)
                    .font(.subheadline.weight(.semibold))

                ViewThatFits(in: .horizontal) {
                    HStack {
                        blockDurationDescription
                        Spacer(minLength: 12)
                        blockDurationPicker(appState: appState)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        blockDurationDescription
                        blockDurationPicker(appState: appState)
                    }
                }

                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack {
                        ignoreWeekButton
                        restoreSessionsButton
                        Spacer(minLength: 10)
                        deleteHistoryButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ignoreWeekButton
                        restoreSessionsButton
                        deleteHistoryButton
                    }
                }
                .buttonStyle(.bordered)
            }
            .lumaCard(padding: 18)
        }
    }

    private var blockDurationDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Duración de bloque")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LumaPalette.ink)
            Text("Elegí una duración si la conclusión automática no te representa.")
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func blockDurationPicker(appState: Bindable<AppState>) -> some View {
        Picker("Duración de bloque", selection: appState.preferredBlockOverrideMinutes) {
            Text("Automática").tag(0)
            Text("15 min").tag(15)
            Text("25 min").tag(25)
            Text("45 min").tag(45)
            Text("60 min").tag(60)
        }
        .labelsHidden()
        .frame(width: 150)
    }

    private var ignoreWeekButton: some View {
        Button("Ignorar esta semana") {
            ignoreWeekConfirmationPresented = true
        }
        .disabled(!hasUsableSessionsThisWeek)
    }

    private var restoreSessionsButton: some View {
        Button("Volver a usar todas") { restoreIgnoredSessions() }
            .disabled(!sessions.contains(where: \.ignoredFromLearning))
    }

    private var deleteHistoryButton: some View {
        Button("Borrar historial", role: .destructive) {
            deleteConfirmationPresented = true
        }
        .disabled(sessions.isEmpty)
    }

    private var hasUsableSessionsThisWeek: Bool {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        return sessions.contains { !$0.ignoredFromLearning && $0.endedAt >= start }
    }

    private func rewriteWeeklySummary() async {
        do {
            aiSummary = try await aiEngine.rhythmSummary(
                profile: profile,
                facts: engine.weeklySummary(for: profile)
            )
        } catch {
            aiSummary = engine.weeklySummary(for: profile)
        }
    }

    private func ignoreCurrentWeek() {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        sessions.filter { $0.endedAt >= start }.forEach { $0.ignoredFromLearning = true }
        try? modelContext.save()
        aiSummary = nil
        appState.refreshPlan()
    }

    private func restoreIgnoredSessions() {
        sessions.forEach { $0.ignoredFromLearning = false }
        try? modelContext.save()
        aiSummary = nil
        appState.refreshPlan()
    }

    private func deleteHistory() {
        sessions.forEach(modelContext.delete)
        try? modelContext.save()
        aiSummary = nil
        appState.preferredBlockOverrideMinutes = 0
        appState.refreshPlan()
    }
}

private struct LearningInsightCard: View {
    let symbol: String
    let title: String
    let value: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(color.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.secondaryInk)
                Text(value)
                    .font(.headline)
                    .foregroundStyle(LumaPalette.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .lumaCard(padding: 15)
    }
}
