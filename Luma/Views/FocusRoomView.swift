import Combine
import SwiftData
import SwiftUI

struct FocusRoomView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]
    @Query(sort: \DailyPlanningContext.updatedAt) private var dailyContexts: [DailyPlanningContext]

    private var viewModel: FocusRoomViewModel { appState.focusSession }
    @State private var sessionSaveFailed = false
    @State private var completedTaskID: UUID?

    private var selectedTaskID: UUID? {
        get { viewModel.selectedTaskID }
        nonmutating set { viewModel.selectedTaskID = newValue }
    }
    private var durationMinutes: Int {
        get { viewModel.durationMinutes }
        nonmutating set { viewModel.durationMinutes = newValue }
    }
    private var remainingSeconds: Int {
        get { viewModel.remainingSeconds }
        nonmutating set { viewModel.remainingSeconds = newValue }
    }
    private var isRunning: Bool {
        get { viewModel.isRunning }
        nonmutating set { viewModel.isRunning = newValue }
    }
    private var completedSession: Bool {
        get { viewModel.completedSession }
        nonmutating set { viewModel.completedSession = newValue }
    }
    private var elapsedSeconds: Int {
        get { viewModel.elapsedSeconds }
        nonmutating set { viewModel.elapsedSeconds = newValue }
    }
    private var lastRecordedMinutes: Int {
        get { viewModel.lastRecordedMinutes }
        nonmutating set { viewModel.lastRecordedMinutes = newValue }
    }
    private var sessionStartedAt: Date? {
        get { viewModel.sessionStartedAt }
        nonmutating set { viewModel.sessionStartedAt = newValue }
    }
    private var recordedSession: FocusSession? {
        get { viewModel.recordedSession }
        nonmutating set { viewModel.recordedSession = newValue }
    }
    private var ambientAudio: FocusAmbientAudioPlayer { viewModel.ambientAudio }

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var pendingTasks: [LumaTask] {
        viewModel.pendingTasks(from: tasks)
    }
    private var selectedTask: LumaTask? {
        viewModel.selectedTask(from: tasks)
    }
    private var displayedTask: LumaTask? {
        completedSession ? tasks.first { $0.id == completedTaskID } : selectedTask
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 760 {
                HStack(spacing: 0) {
                    focusPanel(compact: false)
                        .frame(width: max(0, proxy.size.width - 320))
                        .frame(maxHeight: .infinity)
                    ScrollView { sidePanel }
                        .frame(width: 320)
                        .background(Color.white.opacity(0.30))
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        focusPanel(compact: true)
                            .frame(maxWidth: .infinity, minHeight: 510)
                        Divider()
                        sidePanel
                            .background(Color.white.opacity(0.30))
                    }
                    .lumaScrollContent()
                }
                .lumaScrollSurface()
            }
        }
        .background(LumaBackground())
        .navigationTitle("Focus Room")
        .onReceive(timer) { _ in tick() }
        .onChange(of: durationMinutes) { _, newValue in
            guard !isRunning, elapsedSeconds == 0 else { return }
            remainingSeconds = newValue * 60
        }
        .onChange(of: selectedTaskID) { _, newValue in
            appState.focusTaskID = newValue
            reset()
            viewModel.checkpoint()
        }
        .onChange(of: isRunning) { _, _ in viewModel.checkpoint() }
        .onChange(of: completedSession) { _, _ in viewModel.checkpoint() }
        .onAppear {
            viewModel.checkpoint(now: .now, advance: true)
            if (elapsedSeconds == 0 || completedSession), selectedTaskID == nil || !pendingTasks.contains(where: { $0.id == selectedTaskID }) {
                selectedTaskID = appState.focusTaskID ?? pendingTasks.first?.id
                if !pendingTasks.contains(where: { $0.id == selectedTaskID }) {
                    selectedTaskID = pendingTasks.first?.id
                }
            }
            if let requestedDuration = appState.focusDurationMinutes, elapsedSeconds == 0 {
                durationMinutes = requestedDuration
                remainingSeconds = requestedDuration * 60
                appState.focusDurationMinutes = nil
            }
        }
        .onDisappear {
            viewModel.checkpoint(now: .now, advance: true)
            ambientAudio.stop()
        }
        .alert("No se pudo guardar la sesión", isPresented: $sessionSaveFailed) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text("Tu tiempo no cambió. Usá Terminar sesión para volver a intentar guardarla.")
        }
    }

    private func focusPanel(compact: Bool) -> some View {
        let centerDiameter: CGFloat = compact ? 205 : 260
        let firstRingDiameter: CGFloat = compact ? 245 : 300
        let ringSpacing: CGFloat = compact ? 48 : 75

        return VStack(spacing: compact ? 20 : 26) {
            Spacer()

            ZStack {
                ForEach(0 ..< 3) { ring in
                    Circle()
                        .stroke(LumaPalette.lavender.opacity(0.10 - Double(ring) * 0.02), lineWidth: 28)
                        .frame(
                            width: firstRingDiameter + CGFloat(ring) * ringSpacing,
                            height: firstRingDiameter + CGFloat(ring) * ringSpacing
                        )
                }

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [LumaPalette.indigo.opacity(0.92), LumaPalette.lavender.opacity(0.82)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: centerDiameter, height: centerDiameter)
                    .shadow(color: LumaPalette.indigo.opacity(0.22), radius: 30, y: 18)

                VStack(spacing: 10) {
                    Image(systemName: completedSession ? "sparkles" : "moon.stars.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.82))
                    Text(timeString)
                        .font(.system(size: compact ? 42 : 52, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Text(isRunning ? "Una cosa a la vez" : "Listo cuando vos estés")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.76))
                }
            }

            VStack(spacing: 8) {
                Text(displayedTask?.title ?? "Elegí un pendiente para empezar")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let area = displayedTask?.area {
                    AreaPill(area: area)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    primaryFocusButton
                    resetButton
                    if elapsedSeconds > 0, !completedSession { finishButton }
                }
                VStack(spacing: 9) {
                    primaryFocusButton
                    resetButton
                    if elapsedSeconds > 0, !completedSession { finishButton }
                }
            }

            Spacer()
        }
        .padding(compact ? 20 : 30)
        .clipped()
    }

    private var primaryFocusButton: some View {
        Button {
            if completedSession { reset() }
            if !isRunning, sessionStartedAt == nil {
                if viewModel.plannedBlockID == nil { viewModel.plannedBlockID = selectedTaskID.flatMap { appState.workBlocks(on: .now, taskID: $0).first { $0.status == .confirmed }?.id } }
                sessionStartedAt = .now
            }
            if isRunning {
                isRunning = false
                ambientAudio.pause()
            } else {
                isRunning = true
                ambientAudio.play()
            }
        } label: {
            Label(
                isRunning ? "Pausar" : (completedSession ? "Otra sesión" : "Empezar"),
                systemImage: isRunning ? "pause.fill" : "play.fill"
            )
            .frame(minWidth: 100)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(LumaPalette.indigo)
        .disabled(selectedTask == nil)
    }

    private var resetButton: some View {
        Button(elapsedSeconds > 0 && !completedSession ? "Guardar y reiniciar" : "Reiniciar") {
            if elapsedSeconds > 0 && !completedSession { finishSessionEarly() }
            if !sessionSaveFailed { reset() }
        }
            .buttonStyle(.bordered)
            .controlSize(.large)
    }

    private var finishButton: some View {
        Button("Terminar sesión") { finishSessionEarly() }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(completedSession)
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("FOCUS ROOM")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(LumaPalette.lavender)
                Text("Tu rincón tranquilo")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                Text("Sin rachas rígidas. Una sesión cuenta aunque sea corta.")
                    .font(.subheadline)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }

            if selectedTask == nil, elapsedSeconds > 0, !completedSession {
                Text("El pendiente de esta sesión ya no está disponible.").font(.caption)
                Button("Cerrar esta sesión") { completedSession = true; reset() }
            }
            taskSelector
                .disabled(elapsedSeconds > 0 && !completedSession)
            if elapsedSeconds > 0 && !completedSession { Text("Terminá esta sesión para cambiar de tarea. Tu avance queda guardado aunque salgas de Focus.").font(.caption).foregroundStyle(LumaPalette.secondaryInk) }

            VStack(alignment: .leading, spacing: 10) {
                Text("Duración")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.secondaryInk)
                durationSelector.disabled(elapsedSeconds > 0 && !completedSession)
            }

            ambienceCard

            if completedSession {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Sesión completada", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(LumaPalette.sage)
                    Text(sessionSummary)
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                    Button("Marcar como hecho") {
                        guard let task = tasks.first(where: { $0.id == completedTaskID }),
                              !task.isCompleted
                        else { return }
                        task.markCompleted()
                        recordedSession?.completedTask = true
                        recordedSession?.updatedAt = .now
                        try? modelContext.save()
                        appState.refreshPlan()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.sage)
                    .disabled(displayedTask?.isCompleted != false)
                    Button("Volver a Hoy") { appState.selection = .today }
                    if let task = displayedTask, !task.isCompleted, task.focusedMinutes >= task.estimatedMinutes {
                        Button("Todavía falta · sumar 25 min estimados") {
                            task.estimatedMinutes = task.focusedMinutes + 25
                            task.touch()
                            do { try modelContext.save(); appState.refreshPlan() } catch { sessionSaveFailed = true }
                        }.font(.caption)
                    }
                }
                .lumaCard(padding: 14)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var taskSelector: some View {
        if pendingTasks.isEmpty {
            taskSelectorLabel(title: "Sin pendientes disponibles")
        } else {
            Menu {
                ForEach(pendingTasks) { task in
                    Button(task.title) { selectedTaskID = task.id }
                }
            } label: {
                taskSelectorLabel(title: selectedTask?.title ?? "Elegí un pendiente")
            }
            .menuStyle(.borderlessButton)
        }
    }

    private func taskSelectorLabel(title: String) -> some View {
        HStack(spacing: 10) {
            Text("Pendiente")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LumaPalette.secondaryInk)
            Spacer()
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(selectedTask == nil ? LumaPalette.secondaryInk : LumaPalette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 40)
        .background(Color.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(LumaPalette.indigo.opacity(0.12))
        }
    }

    private var durationSelector: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 7)], spacing: 7) {
            ForEach(durationOptions, id: \.self) { minutes in
                Button {
                    durationMinutes = minutes
                } label: {
                    Text("\(minutes) min")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(durationMinutes == minutes ? Color.white : LumaPalette.secondaryInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            durationMinutes == minutes
                                ? LumaPalette.indigo
                                : Color.white.opacity(0.42),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(isRunning)
        .opacity(isRunning ? 0.65 : 1)
    }

    private var ambienceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: ambientAudio.selectedAmbience.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(LumaPalette.indigo)
                    .frame(width: 22)

                Menu {
                    ForEach(RainAmbience.allCases) { ambience in
                        Button {
                            ambientAudio.selectedAmbience = ambience
                        } label: {
                            if ambientAudio.selectedAmbience == ambience {
                                Label(ambience.title, systemImage: "checkmark")
                            } else {
                                Text(ambience.title)
                            }
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ambientAudio.selectedAmbience.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LumaPalette.ink)
                        Text(ambientAudio.selectedAmbience.detail)
                            .font(.caption2)
                            .foregroundStyle(LumaPalette.secondaryInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)

                Button {
                    if ambientAudio.isEnabled {
                        ambientAudio.isEnabled = false
                    } else {
                        ambientAudio.isEnabled = true
                        if isRunning { ambientAudio.play() }
                    }
                } label: {
                    Image(systemName: ambientAudio.isEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ambientAudio.isEnabled ? LumaPalette.indigo : LumaPalette.secondaryInk)
                .help(ambientAudio.isEnabled ? "Silenciar lluvia" : "Activar lluvia")
            }

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(LumaPalette.secondaryInk)

                Slider(
                    value: Binding(
                        get: { ambientAudio.volume },
                        set: { ambientAudio.setVolume($0) }
                    ),
                    in: 0 ... 1
                )
                .disabled(!ambientAudio.isEnabled)
            }

            Text(ambientAudio.loadError ?? "Se reproduce en loop durante tu sesión y funciona sin internet.")
                .font(.caption2)
                .foregroundStyle(ambientAudio.loadError == nil ? LumaPalette.secondaryInk : Color.red.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .lumaCard(padding: 14)
    }

    private var timeString: String {
        viewModel.timeString
    }

    private var durationOptions: [Int] {
        viewModel.durationOptions
    }

    private var sessionSummary: String {
        guard let task = displayedTask else {
            return "Bien ahí. Una sesión corta también cuenta."
        }
        return "Registré \(lastRecordedMinutes) min. Llevás \(task.focusedMinutes) de \(task.estimatedMinutes) min estimados."
    }

    private func tick() {
        guard isRunning else { return }
        viewModel.checkpoint(now: .now, advance: true)
        if remainingSeconds == 0 { completeSession(minutes: max(1, Int(ceil(Double(elapsedSeconds) / 60)))) }
    }

    private func reset() {
        viewModel.reset()
    }

    private func finishSessionEarly() {
        viewModel.checkpoint(now: .now, advance: true)
        let minutes = max(1, Int(ceil(Double(elapsedSeconds) / 60.0)))
        completeSession(minutes: minutes)
    }

    private func completeSession(minutes: Int) {
        guard !completedSession, elapsedSeconds > 0, minutes > 0, let selectedTask else { return }
        let endedAt = Date.now
        let eventID = viewModel.sessionID
        sessionSaveFailed = false
        let initialAvailableMinutes = dailyContexts.first {
            Calendar.current.isDate($0.day, inSameDayAs: endedAt)
        }?.availableMinutes ?? 120
        appState.ensureDailyTimeBudget(availableMinutes: initialAvailableMinutes, now: endedAt)
        if let existing = (try? modelContext.fetch(FetchDescriptor<FocusSession>()))?.first(where: { $0.id == eventID }) {
            _ = appState.recordTimeSpent(eventID: eventID, minutes: existing.actualMinutes, initialAvailableMinutes: initialAvailableMinutes, now: existing.endedAt)
            completedTaskID = existing.taskID
            completedSession = true
            isRunning = false
            lastRecordedMinutes = existing.actualMinutes
            recordedSession = existing
            appState.finishPlannedBlock(for: existing.taskID, blockID: viewModel.plannedBlockID, workedMinutes: existing.actualMinutes, taskCompleted: existing.completedTask, now: existing.endedAt)
            viewModel.checkpoint()
            return
        }
        let previousTask = LumaTaskSnapshot(task: selectedTask)
        isRunning = false
        ambientAudio.stop()
        selectedTask.recordFocusSession(minutes: minutes, at: endedAt)
        let isRest = selectedTask.academicSourceType == .rest
        if isRest, minutes >= (appState.dailyPlan?.restMinutes ?? durationMinutes) {
            selectedTask.markCompleted()
        }

        var newSession: FocusSession?
        do {
            let session = FocusSession(
                id: eventID,
                taskID: selectedTask.id,
                taskTitle: selectedTask.title,
                area: selectedTask.area,
                plannedMinutes: durationMinutes,
                actualMinutes: minutes,
                startedAt: sessionStartedAt ?? endedAt,
                endedAt: endedAt,
                energyPreference: appState.energyPreference,
                completedTask: selectedTask.isCompleted,
                ignoredFromLearning: !appState.learningEnabled || isRest,
                origin: isRest ? .rest : .focus
            )
            modelContext.insert(session)
            newSession = session
        }

        do {
            try modelContext.save()
        } catch {
            if let newSession { modelContext.delete(newSession) }
            selectedTask.status = previousTask.status
            selectedTask.completedAt = previousTask.completedAt
            selectedTask.focusedMinutes = previousTask.focusedMinutes
            selectedTask.focusSessionCount = previousTask.focusSessionCount
            selectedTask.lastFocusedAt = previousTask.lastFocusedAt
            selectedTask.updatedAt = previousTask.updatedAt
            sessionSaveFailed = true
            return
        }
        _ = appState.recordTimeSpent(
            eventID: eventID,
            minutes: minutes,
            initialAvailableMinutes: initialAvailableMinutes,
            now: endedAt
        )
        if isRest { appState.finishRest(minutes: minutes) }
        appState.finishPlannedBlock(for: selectedTask.id, blockID: viewModel.plannedBlockID, workedMinutes: minutes, taskCompleted: selectedTask.isCompleted, now: endedAt)
        completedTaskID = selectedTask.id
        completedSession = true
        remainingSeconds = 0
        lastRecordedMinutes = minutes
        recordedSession = newSession
        viewModel.checkpoint()
        appState.refreshPlan()
    }
}
