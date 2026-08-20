import SwiftData
import SwiftUI

struct LumaAssistantView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalAIEngine.self) private var aiEngine
    @Environment(NotificationService.self) private var notificationService
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @Query(sort: \SubjectGradeItem.createdAt) private var gradeItems: [SubjectGradeItem]
    @Query(sort: \FocusSession.endedAt, order: .reverse) private var focusSessions: [FocusSession]
    @Query(sort: \LumaProfile.createdAt) private var profiles: [LumaProfile]
    @Query(sort: \LumaChatRecord.createdAt) private var messages: [LumaChatRecord]

    @State private var draft = ""
    @State private var isSending = false
    @State private var errorMessage = ""
    @State private var confirmingRecordID: UUID?
    @State private var replanProposal: ReplanProposal?
    @State private var replanRecordID: UUID?
    @FocusState private var composerFocused: Bool

    private let learningEngine = BehaviorLearningEngine()
    private let scheduler = DailyScheduler()
    private let suggestions = [
        "¿Por dónde empiezo?",
        "Estoy cansada, ¿qué puedo hacer?",
        "Tengo una hora libre",
        "¿Qué se está acumulando?",
    ]

    private var planner: TaskPlanner {
        let rhythm = learningEngine.profile(from: focusSessions)
        return TaskPlanner(
            rhythmProfile: appState.learningEnabled ? rhythm : nil,
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

    private var recommendations: [PlanRecommendation] {
        appState.dailyRecommendations(from: tasks, planner: planner)
    }

    private var hasChatModel: Bool {
        aiEngine.isStudyModelInstalled || aiEngine.isInstalled
    }

    private var confirmationRecord: LumaChatRecord? {
        guard let confirmingRecordID else { return nil }
        return messages.first(where: { $0.id == confirmingRecordID })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)

            if hasChatModel {
                conversation
                composer
            } else {
                modelRequiredState
            }
        }
        .background(LumaBackground())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .confirmationDialog(
            "Confirmá la acción",
            isPresented: Binding(
                get: { confirmingRecordID != nil },
                set: { if !$0 { confirmingRecordID = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let record = confirmationRecord, let action = record.suggestedAction {
                Button(actionButtonTitle(action)) { applyConfirmed(action, from: record) }
            }
            Button("Cancelar", role: .cancel) { confirmingRecordID = nil }
        } message: {
            Text(confirmationRecord.flatMap { $0.suggestedAction }.map(actionDescription) ?? "Nada cambiará sin tu confirmación.")
        }
        .sheet(item: $replanProposal) { proposal in
            ReplanPreviewView(
                proposal: proposal,
                tasks: tasks,
                onCancel: {
                    replanProposal = nil
                    replanRecordID = nil
                },
                onApply: { applyReplan(proposal) }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(LumaPalette.indigo.opacity(0.13))
                Image(systemName: "sparkles")
                    .foregroundStyle(LumaPalette.indigo)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Preguntale a Luma")
                    .font(.headline)
                    .foregroundStyle(LumaPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text("Lista para ayudarte")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .layoutPriority(1)
            Spacer()
            if !messages.isEmpty {
                Button(action: deleteConversation) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(LumaPalette.secondaryInk)
                .help("Borrar esta conversación")
            }
            Button {
                appState.assistantPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(LumaPalette.secondaryInk)
            .help("Cerrar")
        }
        .padding(18)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if messages.isEmpty { welcome }

                    ForEach(messages) { record in
                        messageBubble(record)
                            .id(record.id)
                    }

                    if isSending {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Luma está preparando la respuesta…")
                                .font(.caption)
                                .foregroundStyle(LumaPalette.secondaryInk)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .id("thinking")
                    }

                    if !errorMessage.isEmpty {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(LumaPalette.terracotta)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(LumaPalette.terracotta.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(18)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: isSending) { _, sending in
                if sending { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("¿Qué necesitás ordenar?")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                Text("Conozco tus pendientes, el plan de hoy, tu energía, tu perfil y los compromisos que compartiste con Luma.")
                    .font(.subheadline)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        draft = suggestion
                        sendCurrentDraft()
                    } label: {
                        Text(suggestion)
                            .font(.caption.weight(.medium))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    }
                    .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
                    .frame(maxWidth: .infinity)
                    .disabled(isSending || aiEngine.state.isBusy)
                }
            }
        }
        .lumaCard(padding: 16)
    }

    private func messageBubble(_ record: LumaChatRecord) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            if record.role == .user { Spacer(minLength: 38) }

            VStack(alignment: record.role == .user ? .trailing : .leading, spacing: 9) {
                Text(record.role == .assistant
                     ? LumaChatTextCleaner.finalAnswer(from: record.text)
                     : record.text)
                    .font(.subheadline)
                    .foregroundStyle(record.role == .user ? Color.white : LumaPalette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        record.role == .user ? LumaPalette.indigo : Color.white.opacity(0.78),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .layoutPriority(1)

                if record.role == .assistant, !record.evidence.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(record.evidence, id: \.self) { item in
                                Label(item, systemImage: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(LumaPalette.secondaryInk)
                            }
                        }
                        .padding(.top, 7)
                    } label: {
                        Label("Usé este contexto", systemImage: "scope")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LumaPalette.sage)
                    }
                    .padding(11)
                    .background(Color.white.opacity(0.56), in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let action = record.suggestedAction,
                   isActionRelevant(action, for: record)
                {
                    actionCard(action, record: record)
                }
            }

            if record.role == .assistant { Spacer(minLength: 38) }
        }
        .frame(maxWidth: .infinity)
    }

    private func actionCard(_ action: LumaChatSuggestedAction, record: LumaChatRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Acción propuesta", systemImage: actionSymbol(action.kind))
                .font(.caption.weight(.bold))
                .foregroundStyle(LumaPalette.indigo)
            Text(actionDescription(action))
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
            Button {
                beginConfirmation(for: record, action: action)
            } label: {
                Label(
                    record.appliedAt == nil ? actionButtonTitle(action) : "Aplicado",
                    systemImage: record.appliedAt == nil ? "checkmark.shield" : "checkmark.circle.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(record.appliedAt == nil ? LumaPalette.indigo : LumaPalette.sage)
            .disabled(record.appliedAt != nil || !canApply(action))
        }
        .padding(12)
        .background(LumaPalette.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            Divider().opacity(0.55)
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Preguntá sobre tu día…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 5)
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 15))
                    .onSubmit { sendCurrentDraft() }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .layoutPriority(1)

                Button(action: sendCurrentDraft) {
                    Image(systemName: "arrow.up")
                        .font(.headline)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .tint(LumaPalette.indigo)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending || aiEngine.state.isBusy)
                .fixedSize()
            }

            Text("Nada cambia sin tu confirmación.")
                .font(.caption2)
                .foregroundStyle(LumaPalette.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    private var modelRequiredState: some View {
        VStack(spacing: 16) {
            Image(systemName: "memorychip")
                .font(.system(size: 36))
                .foregroundStyle(LumaPalette.indigo)
            Text("Prepará el chat de Luma")
                .font(.title3.weight(.semibold))
            Text("Descargá el complemento desde Ajustes para conversar y modificar tus pendientes.")
                .font(.subheadline)
                .foregroundStyle(LumaPalette.secondaryInk)
                .multilineTextAlignment(.center)
            Button("Abrir Ajustes") { openSettings() }
                .buttonStyle(.borderedProminent)
                .tint(LumaPalette.indigo)
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sendCurrentDraft() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending, !aiEngine.state.isBusy else { return }

        let previousConversation = messages.suffix(12).map(\.message)
        modelContext.insert(LumaChatRecord(role: .user, text: question))
        trimConversationIfNeeded()
        try? modelContext.save()
        draft = ""
        errorMessage = ""
        isSending = true

        let context = LumaAssistantContextBuilder.makeContext(
            tasks: tasks,
            subjects: subjects,
            recommendations: recommendations,
            agenda: appState.dailyAgenda,
            commitments: calendarService.commitments,
            energyPreference: appState.energyPreference,
            workload: planner.workload(from: tasks),
            profile: profiles.first
        )
        let evidence = LumaAssistantContextBuilder.makeEvidence(
            tasks: tasks,
            recommendations: recommendations,
            agenda: appState.dailyAgenda,
            commitments: calendarService.commitments,
            energyPreference: appState.energyPreference,
            profile: profiles.first
        )

        Task {
            defer { isSending = false }
            do {
                let reply = try await aiEngine.askLuma(
                    question: question,
                    context: context,
                    conversation: previousConversation
                )
                let resolvedReply = resolveFlexibleFocusIntent(
                    question: question,
                    reply: reply
                )
                modelContext.insert(
                    LumaChatRecord(
                        role: .assistant,
                        text: resolvedReply.message,
                        evidence: evidence,
                        suggestedAction: validated(resolvedReply.suggestedAction, for: question)
                    )
                )
                trimConversationIfNeeded()
                try? modelContext.save()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resolveFlexibleFocusIntent(
        question: String,
        reply: LumaChatReply
    ) -> LumaChatReply {
        switch LumaChatIntentResolver.resolveFocus(
            question: question,
            modelAction: reply.suggestedAction,
            tasks: tasks,
            subjects: subjects,
            recommendations: recommendations
        ) {
        case .notRequested:
            return reply
        case let .resolved(message, action):
            return LumaChatReply(message: message, suggestedAction: action)
        case let .needsClarification(message):
            return LumaChatReply(message: message, suggestedAction: nil)
        }
    }

    private func validated(
        _ action: LumaChatSuggestedAction?,
        for question: String
    ) -> LumaChatSuggestedAction? {
        guard let action else { return nil }
        switch action.kind {
        case .replan:
            return hasReplanIntent(question) ? action : nil
        case .startFocus:
            guard let taskID = action.taskID,
                  let task = tasks.first(where: { $0.id == taskID && !$0.isCompleted }),
                  !TaskDependencyResolver.isBlocked(task, in: tasks)
            else { return nil }
            return action
        case .completeTask:
            guard let taskID = action.taskID,
                  tasks.contains(where: { $0.id == taskID && !$0.isCompleted })
            else { return nil }
            return action
        case .renameTask:
            guard hasRenameIntent(question),
                  let taskID = action.taskID,
                  let task = tasks.first(where: { $0.id == taskID }),
                  !action.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  task.title.compare(
                      action.label,
                      options: [.caseInsensitive, .diacriticInsensitive]
                  ) != .orderedSame
            else { return nil }
            var validated = action
            validated.label = String(
                action.label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
            )
            return validated
        }
    }

    private func isActionRelevant(
        _ action: LumaChatSuggestedAction,
        for record: LumaChatRecord
    ) -> Bool {
        guard let question = question(before: record) else { return true }
        return switch action.kind {
        case .replan: hasReplanIntent(question)
        case .renameTask: hasRenameIntent(question)
        case .startFocus, .completeTask: true
        }
    }

    private func question(before record: LumaChatRecord) -> String? {
        guard let index = messages.firstIndex(where: { $0.id == record.id }) else { return nil }
        return messages[..<index].reversed().first(where: { $0.role == .user })?.text
    }

    private func hasRenameIntent(_ text: String) -> Bool {
        let normalized = normalizedIntent(text)
        return [
            "renombr", "cambiar el nombre", "cambia el nombre", "cambiale el nombre",
            "que pase de", "se llame", "nuevo nombre",
        ].contains(where: normalized.contains)
    }

    private func hasReplanIntent(_ text: String) -> Bool {
        let normalized = normalizedIntent(text)
        return [
            "reacomod", "replan", "ordenar mi dia", "ordenar el dia", "estoy cansad",
            "tengo mas tiempo", "hora libre", "minutos libres", "tiempo disponible",
            "cambiar prioridad", "cambia la prioridad", "energia",
        ].contains(where: normalized.contains)
    }

    private func normalizedIntent(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "es_AR")
        )
    }

    private func canApply(_ action: LumaChatSuggestedAction) -> Bool {
        switch action.kind {
        case .replan:
            return true
        case .startFocus:
            return action.taskID.flatMap { id in tasks.first(where: { $0.id == id && !$0.isCompleted }) }
                .map { !TaskDependencyResolver.isBlocked($0, in: tasks) } ?? false
        case .completeTask:
            return action.taskID.map { id in
                tasks.contains(where: { $0.id == id && !$0.isCompleted })
            } ?? false
        case .renameTask:
            guard let taskID = action.taskID,
                  let task = tasks.first(where: { $0.id == taskID })
            else { return false }
            let newTitle = action.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return !newTitle.isEmpty
                && task.title.compare(
                    newTitle,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != .orderedSame
        }
    }

    private func beginConfirmation(for record: LumaChatRecord, action: LumaChatSuggestedAction) {
        guard canApply(action), record.appliedAt == nil else { return }
        if action.kind == .replan {
            replanRecordID = record.id
            replanProposal = ReplanProposalBuilder.make(
                source: .assistant,
                explanation: record.text,
                tasks: tasks,
                currentPlan: appState.dailyPlan,
                currentAgenda: appState.dailyAgenda,
                currentEnergy: appState.energyPreference,
                proposedEnergy: action.energyPreference ?? appState.energyPreference,
                proposedAvailableMinutes: action.availableMinutes,
                planner: planner,
                scheduler: scheduler,
                busyBlocks: calendarService.busyBlocks()
            )
        } else {
            confirmingRecordID = record.id
        }
    }

    private func applyReplan(_ proposal: ReplanProposal) {
        appState.applyReplan(proposal)
        modelContext.insert(LumaReplanRecord(proposal: proposal))
        if let replanRecordID,
           let record = messages.first(where: { $0.id == replanRecordID })
        {
            record.appliedAt = .now
            appState.coachMessage = record.text
        }
        try? modelContext.save()
        replanProposal = nil
        replanRecordID = nil
        Task { await notificationService.scheduleAgenda(appState.dailyAgenda, tasks: tasks) }
    }

    private func applyConfirmed(_ action: LumaChatSuggestedAction, from record: LumaChatRecord) {
        guard canApply(action), record.appliedAt == nil else { return }

        switch action.kind {
        case .replan:
            return
        case .startFocus:
            guard let taskID = action.taskID else { return }
            appState.startFocus(for: taskID, durationMinutes: action.durationMinutes)
            appState.assistantPresented = false
        case .completeTask:
            guard let taskID = action.taskID,
                  let task = tasks.first(where: { $0.id == taskID })
            else { return }
            task.markCompleted()
            appState.replanDaily(from: tasks, planner: planner, preference: appState.energyPreference)
            rebuildAgenda()
        case .renameTask:
            guard let taskID = action.taskID,
                  let task = tasks.first(where: { $0.id == taskID })
            else { return }
            task.title = action.label.trimmingCharacters(in: .whitespacesAndNewlines)
            try? calendarService.syncTask(task)
            appState.refreshPlan()
        }

        record.appliedAt = .now
        confirmingRecordID = nil
        try? modelContext.save()
    }

    private func rebuildAgenda() {
        appState.prepareDailyAgenda(
            from: tasks,
            planner: planner,
            scheduler: scheduler,
            force: true,
            busyBlocks: calendarService.busyBlocks()
        )
        Task { await notificationService.scheduleAgenda(appState.dailyAgenda, tasks: tasks) }
    }

    private func actionDescription(_ action: LumaChatSuggestedAction) -> String {
        switch action.kind {
        case .replan:
            let energy = action.energyPreference?.title ?? appState.energyPreference.title
            let time = action.availableMinutes.map { " con \($0) minutos disponibles" } ?? ""
            return "Preparar un nuevo plan con \(energy.lowercased())\(time). Vas a ver el antes y el después."
        case .startFocus:
            let task = action.taskID.flatMap { id in tasks.first(where: { $0.id == id })?.title } ?? "la tarea elegida"
            let duration = action.durationMinutes.map { " durante \($0) minutos" } ?? ""
            return "Abrir Focus Room\(duration) para \(task)."
        case .completeTask:
            let task = action.taskID.flatMap { id in tasks.first(where: { $0.id == id })?.title } ?? "la tarea elegida"
            return "Marcar “\(task)” como completada y actualizar el plan."
        case .renameTask:
            let currentTitle = action.taskID.flatMap { id in
                tasks.first(where: { $0.id == id })?.title
            } ?? "la tarea elegida"
            return "Cambiar “\(currentTitle)” por “\(action.label)”."
        }
    }

    private func actionButtonTitle(_ action: LumaChatSuggestedAction) -> String {
        switch action.kind {
        case .replan: "Revisar cambio"
        case .renameTask: "Cambiar nombre"
        case .startFocus:
            action.durationMinutes.map { "Iniciar \($0) min" } ?? "Iniciar sesión"
        case .completeTask: "Confirmar acción"
        }
    }

    private func actionSymbol(_ kind: LumaChatActionKind) -> String {
        switch kind {
        case .replan: "arrow.triangle.2.circlepath"
        case .startFocus: "timer"
        case .completeTask: "checkmark.circle"
        case .renameTask: "pencil"
        }
    }

    private func deleteConversation() {
        messages.forEach(modelContext.delete)
        try? modelContext.save()
    }

    private func trimConversationIfNeeded() {
        guard messages.count > 100 else { return }
        messages.prefix(messages.count - 100).forEach(modelContext.delete)
    }
}
