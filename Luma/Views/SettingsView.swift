import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalAIEngine.self) private var aiEngine
    @Environment(NotificationService.self) private var notificationService
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(UpdateService.self) private var updateService
    @Environment(CloudSyncService.self) private var cloudSyncService
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LumaTask.createdAt) private var tasks: [LumaTask]
    @Query(sort: \FocusSession.endedAt) private var sessions: [FocusSession]
    @Query(sort: \StudyGuide.importedAt) private var studyGuides: [StudyGuide]
    @Query(sort: \LumaProfile.createdAt) private var profiles: [LumaProfile]
    @Query(sort: \LumaChatRecord.createdAt) private var chatMessages: [LumaChatRecord]
    @Query(sort: \LumaReplanRecord.createdAt) private var replanRecords: [LumaReplanRecord]
    @Query(sort: \AcademicSubject.updatedAt) private var subjects: [AcademicSubject]
    @Query(sort: \SubjectGradeItem.updatedAt) private var subjectGradeItems: [SubjectGradeItem]

    @State private var viewModel = SettingsViewModel()

    private var backupDocument: LumaBackupDocument {
        get { viewModel.backupDocument }
        nonmutating set { viewModel.backupDocument = newValue }
    }
    private var isExporting: Bool {
        get { viewModel.isExporting }
        nonmutating set { viewModel.isExporting = newValue }
    }
    private var isImporting: Bool {
        get { viewModel.isImporting }
        nonmutating set { viewModel.isImporting = newValue }
    }
    private var backupMessage: String {
        get { viewModel.backupMessage }
        nonmutating set { viewModel.backupMessage = newValue }
    }

    var body: some View {
        TabView {
            generalPane
                .tabItem { Label("Rutina", systemImage: "clock.badge.checkmark") }
            aiPane
                .tabItem { Label("Funciones", systemImage: "sparkles") }
            cloudPane
                .tabItem { Label("Nube", systemImage: "icloud") }
            dataPane
                .tabItem { Label("Datos", systemImage: "externaldrive") }
            aboutPane
                .tabItem { Label("Luma", systemImage: "info.circle") }
        }
        .padding(22)
        .background(LumaBackground())
        .fileExporter(
            isPresented: Binding(
                get: { viewModel.isExporting },
                set: { viewModel.isExporting = $0 }
            ),
            document: backupDocument,
            contentType: .json,
            defaultFilename: "Luma-respaldo"
        ) { result in
            backupMessage = result.isSuccess ? "Respaldo guardado." : "No se pudo guardar el respaldo."
        }
        .fileImporter(isPresented: Binding(
            get: { viewModel.isImporting },
            set: { viewModel.isImporting = $0 }
        ), allowedContentTypes: [.json]) { result in
            importBackup(result)
        }
    }

    private var generalPane: some View {
        @Bindable var appState = appState

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                paneHeader("Tu día", "La disponibilidad se decide para cada fecha desde el panel Hoy.")

                VStack(alignment: .leading, spacing: 12) {
                    Label("Sin una semana rígida", systemImage: "calendar.day.timeline.left")
                        .font(.headline)
                        .foregroundStyle(LumaPalette.indigo)
                    Text("Luma no repite automáticamente la hora de un día en los demás. Cada mañana podés elegir una opción rápida, marcar Día libre o crear varios bloques.")
                        .font(.subheadline)
                        .foregroundStyle(LumaPalette.secondaryInk)
                    Text("Los bloques se cambian en Hoy → Ajustar disponibilidad.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LumaPalette.sage)
                }
                .lumaCard(padding: 18)

                integrationRow(
                    symbol: "bell.badge.fill",
                    title: "Avisos tranquilos",
                    detail: notificationService.isAuthorized ? "Hasta tres avisos por día." : "macOS necesita tu permiso.",
                    active: notificationService.isAuthorized && notificationService.isEnabled,
                    button: notificationService.isAuthorized ? (notificationService.isEnabled ? "Pausar" : "Activar") : "Permitir"
                ) {
                    if notificationService.isAuthorized {
                        notificationService.isEnabled.toggle()
                        if !notificationService.isEnabled { notificationService.clearAgendaNotifications() }
                    } else {
                        Task { await notificationService.requestAuthorization() }
                    }
                }

                integrationRow(
                    symbol: "calendar.badge.clock",
                    title: "Calendario de macOS",
                    detail: calendarService.statusTitle,
                    active: calendarService.isAuthorized && calendarService.isEnabled,
                    button: calendarService.isAuthorized ? (calendarService.isEnabled ? "Pausar" : "Activar") : "Conectar"
                ) {
                    if calendarService.isAuthorized {
                        calendarService.isEnabled.toggle()
                        calendarService.refreshCommitments()
                    } else {
                        Task { await calendarService.requestAccess() }
                    }
                }

                if calendarService.isAuthorized {
                    calendarPreferencesCard
                }

                Label("Captura global: ⌘ ⇧ Espacio", systemImage: "keyboard")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.indigo)
                    .lumaCard(padding: 15)
            }
        }
    }

    private var calendarPreferencesCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("Destino de las tareas", systemImage: "calendar.badge.plus")
                    .font(.headline)
                    .foregroundStyle(LumaPalette.ink)
                Spacer()
                Button("Actualizar") { calendarService.refreshCalendars() }
                    .buttonStyle(.borderless)
            }

            if calendarService.availableCalendars.isEmpty {
                Text("No encontré calendarios editables en esta Mac.")
                    .font(.subheadline)
                    .foregroundStyle(LumaPalette.secondaryInk)
            } else {
                Picker(
                    "Calendario",
                    selection: Binding(
                        get: { calendarService.selectedCalendarIdentifier },
                        set: { calendarService.selectedCalendarIdentifier = $0 }
                    )
                ) {
                    ForEach(calendarService.availableCalendars) { destination in
                        Text(destination.displayName).tag(destination.id as String?)
                    }
                }
                .pickerStyle(.menu)

                Toggle(
                    "Sincronizar automáticamente las tareas con fecha",
                    isOn: Binding(
                        get: { calendarService.autoSyncTasks },
                        set: { calendarService.autoSyncTasks = $0 }
                    )
                )
                .toggleStyle(.switch)
                .disabled(!calendarService.isEnabled)

                Text("Las tareas se agregan como eventos de día completo. Los bloques del plan diario conservan su horario.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                if !calendarService.availableCalendars.contains(where: \.isGoogle) {
                    Label(
                        "Para usar Google Calendar, agregá tu cuenta de Google en Calendario de macOS y tocá Actualizar.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(LumaPalette.indigo)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .lumaCard(padding: 17)
    }

    private var aiPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                paneHeader("Funciones de Luma", "Prepará las respuestas y el análisis avanzado cuando quieras usarlos.")
                if aiEngine.state.isDownloading {
                    AIDownloadProgressView()
                        .lumaCard(padding: 16)
                }
                if case let .failed(message) = aiEngine.state {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Luma necesita atención", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LumaPalette.terracotta)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(LumaPalette.secondaryInk)
                        Button("Cerrar aviso") {
                            aiEngine.clearFailure()
                        }
                        .buttonStyle(.bordered)
                    }
                    .lumaCard(padding: 16)
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        Image(systemName: "memorychip.fill")
                            .font(.title2).foregroundStyle(LumaPalette.indigo)
                            .frame(width: 46, height: 46)
                            .background(LumaPalette.indigo.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Respuestas rápidas").font(.headline)
                            Text(aiEngine.isInstalled ? "Instalado · aproximadamente 1,1 GB" : "Descarga opcional · aproximadamente 1,1 GB")
                                .font(.caption).foregroundStyle(LumaPalette.secondaryInk)
                        }
                        Spacer()
                    }
                    Divider()
                    Label(aiEngine.isInstalled ? "Lista para consultas y cambios desde el chat" : "Todavía no preparada", systemImage: aiEngine.isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(aiEngine.isInstalled ? LumaPalette.sage : LumaPalette.secondaryInk)
                    if !aiEngine.isInstalled {
                        Button { Task { await aiEngine.install() } } label: {
                            if aiEngine.state.isBusy { ProgressView().controlSize(.small) }
                            else { Label("Preparar respuestas", systemImage: "arrow.down.circle.fill") }
                        }
                        .buttonStyle(.borderedProminent).tint(LumaPalette.indigo)
                        .disabled(aiEngine.state.isBusy)
                    }
                }
                .lumaCard()
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Image(systemName: "bubble.left.fill")
                            .font(.title2).foregroundStyle(LumaPalette.lavender)
                            .frame(width: 46, height: 46)
                            .background(LumaPalette.lavender.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Análisis avanzado").font(.headline)
                            Text(aiEngine.isStudyModelInstalled
                                 ? "Instalado · 4,3 GB"
                                 : "Mejores respuestas del chat · descarga de 4,3 GB")
                                .font(.caption).foregroundStyle(LumaPalette.secondaryInk)
                        }
                        Spacer()
                    }
                    Text("Mejora las preguntas complejas, el contexto de tu semana y el análisis del material de estudio.")
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                    if !aiEngine.isStudyModelInstalled {
                        Button {
                            Task { await aiEngine.installStudyModel() }
                        } label: {
                            if aiEngine.state.isBusy { ProgressView().controlSize(.small) }
                            else { Label("Preparar análisis avanzado", systemImage: "arrow.down.circle.fill") }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(LumaPalette.indigo)
                        .disabled(aiEngine.state.isBusy)
                    }
                }
                .lumaCard()
                VStack(alignment: .leading, spacing: 11) {
                    Label("Integrado dentro de Luma", systemImage: "checkmark.circle.fill")
                    Label("Sin pagos por consulta", systemImage: "checkmark.circle.fill")
                    Label("Funciona offline después de descargar", systemImage: "checkmark.circle.fill")
                    Label("Se activa solo cuando lo usás", systemImage: "checkmark.circle.fill")
                }
                .font(.subheadline).foregroundStyle(LumaPalette.sage)
            }
        }
    }

    private var dataPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                paneHeader(
                    "Tus datos",
                    cloudSyncService.isConfigured
                        ? "Luma mantiene una copia local y otra sincronizada en Supabase."
                        : "Todo queda en esta Mac. Podés llevarte una copia cuando quieras."
                )
                HStack(spacing: 12) {
                    metricCard("Pendientes", value: "\(tasks.filter { !$0.isCompleted }.count)", symbol: "tray.full")
                    metricCard("Completados", value: "\(tasks.filter(\.isCompleted).count)", symbol: "checkmark.circle")
                    metricCard("Sesiones", value: "\(sessions.count)", symbol: "timer")
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Respaldo portátil").font(.headline)
                    Text("Incluye pendientes, tareas completadas y sesiones de Focus Room. Al importar, Luma conserva lo existente y agrega solo lo que falta.")
                        .font(.subheadline).foregroundStyle(LumaPalette.secondaryInk)
                    HStack {
                        Button("Exportar respaldo") { exportBackup() }
                            .buttonStyle(.borderedProminent).tint(LumaPalette.indigo)
                        Button("Importar respaldo") { isImporting = true }
                            .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
                        Spacer()
                    }
                    if !backupMessage.isEmpty {
                        Text(backupMessage).font(.caption).foregroundStyle(LumaPalette.sage)
                    }
                }
                .lumaCard()
                Label("Luma no incluye contraseñas, calendarios ni archivos externos en el respaldo.", systemImage: "lock.shield.fill")
                    .font(.caption).foregroundStyle(LumaPalette.sage)
            }
        }
    }

    private var cloudPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                paneHeader("Respaldo en Supabase", "Luma sigue funcionando desde la base local y sincroniza cuando vuelve Internet.")

                HStack(spacing: 14) {
                    Image(systemName: cloudSyncService.state == .synced ? "checkmark.icloud.fill" : "icloud.and.arrow.up.fill")
                        .font(.title2)
                        .foregroundStyle(cloudSyncService.state == .synced ? LumaPalette.sage : LumaPalette.indigo)
                        .frame(width: 48, height: 48)
                        .background(LumaPalette.indigo.opacity(0.11), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cloudSyncService.state.title).font(.headline)
                        Text(cloudStatusDetail)
                            .font(.caption)
                            .foregroundStyle(LumaPalette.secondaryInk)
                    }
                    Spacer()
                    if cloudSyncService.isConfigured {
                        Button {
                            Task { await syncCloudNow() }
                        } label: {
                            if cloudSyncService.state.isBusy { ProgressView().controlSize(.small) }
                            else { Label("Sincronizar", systemImage: "arrow.triangle.2.circlepath") }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(LumaPalette.indigo)
                        .disabled(cloudSyncService.state.isBusy)
                    }
                }
                .lumaCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Qué se guarda").font(.headline).foregroundStyle(LumaPalette.ink)
                    Label("Pendientes, fechas y progreso", systemImage: "tray.full.fill")
                    Label("Materias y porcentajes de evaluación", systemImage: "books.vertical.fill")
                    Label("Preferencias del onboarding", systemImage: "person.crop.circle.fill")
                    Label("Conversaciones y acciones confirmadas", systemImage: "bubble.left.fill")
                    Label("Historial de reacomodos aceptados", systemImage: "clock.arrow.circlepath")
                }
                .font(.subheadline)
                .foregroundStyle(LumaPalette.sage)
                .lumaCard()

                VStack(alignment: .leading, spacing: 10) {
                    Label("Privacidad y seguridad", systemImage: "lock.shield.fill")
                        .font(.headline)
                        .foregroundStyle(LumaPalette.indigo)
                    Text("Cada instalación usa una identidad autenticada y las reglas de Supabase permiten acceder únicamente a sus propios datos.")
                        .font(.subheadline)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                .lumaCard()
            }
        }
    }

    private var aboutPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                paneHeader("Luma", "Una organizadora personal tranquila para macOS.")
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Versión \(updateService.currentVersion)").font(.headline)
                            Text(updateStatusText).font(.caption).foregroundStyle(LumaPalette.secondaryInk)
                        }
                        Spacer()
                        if case .available = updateService.state {
                            Button("Descargar") { updateService.openDownload() }
                                .buttonStyle(.borderedProminent).tint(LumaPalette.indigo)
                        } else {
                            Button("Buscar actualizaciones") { Task { await updateService.check() } }
                                .buttonStyle(SoftButtonStyle(color: LumaPalette.indigo))
                                .disabled(updateService.state == .checking)
                        }
                    }
                    Divider()
                    Label("Sin seguimiento publicitario", systemImage: "hand.raised.fill")
                    Label("Sin métricas enviadas a servidores", systemImage: "network.slash")
                    Label("Procesamiento privado en esta Mac", systemImage: "lock.macwindow")
                }
                .lumaCard()
                VStack(alignment: .leading, spacing: 9) {
                    Text("Privacidad en una frase").font(.headline)
                    Text(cloudSyncService.isConfigured
                         ? "Luma mantiene una copia en esta Mac y sincroniza tus datos con Supabase."
                         : "Luma guarda tareas, preferencias e historial en esta Mac y solo se conecta cuando vos lo pedís.")
                        .font(.subheadline).foregroundStyle(LumaPalette.secondaryInk)
                }
                .lumaCard()
                Button("Volver a mostrar la bienvenida") { appState.restartOnboarding() }
                    .buttonStyle(SoftButtonStyle(color: LumaPalette.secondaryInk))
            }
        }
    }

    private func paneHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title2.weight(.semibold)).foregroundStyle(LumaPalette.ink)
            Text(subtitle).font(.subheadline).foregroundStyle(LumaPalette.secondaryInk)
        }
    }

    private func integrationRow(symbol: String, title: String, detail: String, active: Bool, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(active ? LumaPalette.sage : LumaPalette.indigo)
                .frame(width: 42, height: 42).background((active ? LumaPalette.sage : LumaPalette.indigo).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(LumaPalette.ink)
                Text(detail).font(.caption).foregroundStyle(LumaPalette.secondaryInk)
            }
            Spacer()
            Button(button, action: action).buttonStyle(SoftButtonStyle(color: active ? LumaPalette.sage : LumaPalette.indigo))
        }
        .lumaCard(padding: 15)
    }

    private func metricCard(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(LumaPalette.secondaryInk)
            Text(value).font(.title2.weight(.semibold)).foregroundStyle(LumaPalette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading).lumaCard(padding: 15)
    }

    private func exportBackup() {
        do {
            backupDocument = try BackupService.document(
                tasks: tasks,
                sessions: sessions,
                studyGuides: studyGuides,
                subjects: subjects,
                subjectGradeItems: subjectGradeItems
            )
            isExporting = true
        } catch {
            backupMessage = "No se pudo preparar el respaldo."
        }
    }

    private func importBackup(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let restored = try BackupService.restore(
                data: Data(contentsOf: url),
                existingTasks: tasks,
                existingSessions: sessions,
                existingStudyGuides: studyGuides,
                existingSubjects: subjects,
                existingSubjectGradeItems: subjectGradeItems,
                context: modelContext
            )
            backupMessage = "Listo: \(restored.tasks) tareas, \(restored.sessions) sesiones y \(restored.subjects) materias agregadas."
            appState.refreshPlan()
        } catch {
            backupMessage = "Ese archivo no parece ser un respaldo válido de Luma."
        }
    }

    private var updateStatusText: String {
        switch updateService.state {
        case .idle: "Canal beta · comprobación manual"
        case .checking: "Buscando una versión nueva…"
        case .current: "Tenés la versión más reciente."
        case let .available(version, notes): "Versión \(version) disponible · \(notes)"
        case let .unavailable(message): message
        }
    }

    private var cloudStatusDetail: String {
        if let date = cloudSyncService.lastSyncedAt {
            return "Última sincronización: \(date.formatted(date: .omitted, time: .shortened))"
        }
        if case let .failed(message) = cloudSyncService.state { return message }
        return cloudSyncService.isConfigured
            ? "La primera copia se hará automáticamente."
            : "Falta asociar el proyecto de Supabase a esta beta."
    }

    private func syncCloudNow() async {
        await cloudSyncService.sync(
            tasks: tasks,
            sessions: sessions,
            profiles: profiles,
            messages: chatMessages,
            replans: replanRecords,
            subjects: subjects,
            subjectGradeItems: subjectGradeItems,
            context: modelContext
        )
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
