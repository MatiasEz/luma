import Combine
import SwiftData
import SwiftUI

struct FocusRoomView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]

    @State private var selectedTaskID: UUID?
    @State private var durationMinutes = 25
    @State private var remainingSeconds = 25 * 60
    @State private var isRunning = false
    @State private var completedSession = false
    @State private var elapsedSeconds = 0
    @State private var lastRecordedMinutes = 0
    @State private var sessionStartedAt: Date?
    @State private var recordedSession: FocusSession?
    @State private var ambientAudio = FocusAmbientAudioPlayer()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var pendingTasks: [LumaTask] {
        tasks.filter { !$0.isCompleted && !TaskDependencyResolver.isBlocked($0, in: tasks) }
    }
    private var selectedTask: LumaTask? {
        pendingTasks.first { $0.id == selectedTaskID } ?? pendingTasks.first
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 760 {
                HStack(spacing: 0) {
                    focusPanel(compact: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    sidePanel
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
                }
            }
        }
        .background(LumaBackground())
        .navigationTitle("Focus Room")
        .onReceive(timer) { _ in tick() }
        .onChange(of: durationMinutes) { _, newValue in
            guard !isRunning else { return }
            remainingSeconds = newValue * 60
        }
        .onChange(of: selectedTaskID) { _, newValue in
            appState.focusTaskID = newValue
            reset()
        }
        .onAppear {
            if selectedTaskID == nil || !pendingTasks.contains(where: { $0.id == selectedTaskID }) {
                selectedTaskID = appState.focusTaskID ?? pendingTasks.first?.id
                if !pendingTasks.contains(where: { $0.id == selectedTaskID }) {
                    selectedTaskID = pendingTasks.first?.id
                }
            }
            if let requestedDuration = appState.focusDurationMinutes {
                durationMinutes = requestedDuration
                remainingSeconds = requestedDuration * 60
                appState.focusDurationMinutes = nil
            }
        }
        .onDisappear {
            ambientAudio.stop()
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
                Text(selectedTask?.title ?? "Elegí un pendiente para empezar")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let area = selectedTask?.area {
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
        Button("Reiniciar") { reset() }
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

            taskSelector

            VStack(alignment: .leading, spacing: 10) {
                Text("Duración")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.secondaryInk)
                durationSelector
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
                        guard let task = selectedTask else { return }
                        task.markCompleted()
                        recordedSession?.completedTask = true
                        try? modelContext.save()
                        appState.refreshPlan()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LumaPalette.sage)
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

                if !isRunning {
                    Button(ambientAudio.isPlaying ? "Detener" : "Probar") {
                        ambientAudio.togglePreview()
                    }
                    .buttonStyle(.borderless)
                    .disabled(!ambientAudio.isEnabled || ambientAudio.loadError != nil)
                }
            }

            Text(ambientAudio.loadError ?? "Se reproduce en loop durante tu sesión y funciona sin internet.")
                .font(.caption2)
                .foregroundStyle(ambientAudio.loadError == nil ? LumaPalette.secondaryInk : Color.red.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .lumaCard(padding: 14)
    }

    private var timeString: String {
        String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    private var durationOptions: [Int] {
        Array(Set([15, 25, 45, 60, durationMinutes])).sorted()
    }

    private var sessionSummary: String {
        guard let task = selectedTask else {
            return "Bien ahí. Una sesión corta también cuenta."
        }
        return "Registré \(lastRecordedMinutes) min. Llevás \(task.focusedMinutes) de \(task.estimatedMinutes) min estimados."
    }

    private func tick() {
        guard isRunning else { return }
        if remainingSeconds > 1 {
            remainingSeconds -= 1
            elapsedSeconds += 1
        } else {
            remainingSeconds = 0
            elapsedSeconds += 1
            completeSession(minutes: durationMinutes)
        }
    }

    private func reset() {
        isRunning = false
        ambientAudio.stop()
        completedSession = false
        elapsedSeconds = 0
        lastRecordedMinutes = 0
        sessionStartedAt = nil
        recordedSession = nil
        remainingSeconds = durationMinutes * 60
    }

    private func finishSessionEarly() {
        let minutes = max(1, Int(ceil(Double(elapsedSeconds) / 60.0)))
        completeSession(minutes: minutes)
    }

    private func completeSession(minutes: Int) {
        guard !completedSession, let selectedTask else { return }
        isRunning = false
        ambientAudio.stop()
        completedSession = true
        remainingSeconds = 0
        lastRecordedMinutes = minutes
        selectedTask.recordFocusSession(minutes: minutes)

        if appState.learningEnabled {
            let endedAt = Date.now
            let session = FocusSession(
                taskID: selectedTask.id,
                taskTitle: selectedTask.title,
                area: selectedTask.area,
                plannedMinutes: durationMinutes,
                actualMinutes: minutes,
                startedAt: sessionStartedAt ?? endedAt,
                endedAt: endedAt,
                energyPreference: appState.energyPreference
            )
            modelContext.insert(session)
            recordedSession = session
        }

        try? modelContext.save()
        appState.refreshPlan()
    }
}
