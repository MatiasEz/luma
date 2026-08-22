import SwiftData
import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(LocalAIEngine.self) private var aiEngine
    @Environment(NotificationService.self) private var notificationService
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(CloudSyncService.self) private var cloudSyncService
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LumaProfile.createdAt) private var profiles: [LumaProfile]

    @State private var viewModel = OnboardingViewModel()

    private var step: Int {
        get { viewModel.step }
        nonmutating set { viewModel.step = newValue }
    }
    private var selectedAreas: Set<LifeArea> {
        get { viewModel.selectedAreas }
        nonmutating set { viewModel.selectedAreas = newValue }
    }
    private var energyPeak: EnergyPeak {
        get { viewModel.energyPeak }
        nonmutating set { viewModel.energyPeak = newValue }
    }

    private let stepCount = 6

    var body: some View {
        VStack(spacing: 0) {
            progressHeader
            Group {
                switch step {
                case 0: welcome
                case 1: importantAreas
                case 2: routine
                case 3: energyMoment
                case 4: permissions
                default: localAI
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(30)
        .background(LumaBackground())
        .frame(width: 790, height: 660)
        .task { loadProfileIfNeeded() }
    }

    private var progressHeader: some View {
        HStack {
            Label("Luma", systemImage: "moon.stars.fill")
                .font(.headline)
                .foregroundStyle(LumaPalette.indigo)
            Spacer()
            HStack(spacing: 7) {
                ForEach(0 ..< stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? LumaPalette.indigo : LumaPalette.indigo.opacity(0.15))
                        .frame(width: index == step ? 28 : 9, height: 9)
                }
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(LumaPalette.indigo.opacity(0.12)).frame(width: 116, height: 116)
                Image(systemName: "sparkles")
                    .font(.system(size: 42))
                    .foregroundStyle(LumaPalette.indigo)
            }
            Text(profiles.isEmpty ? "Menos organización.\nMás claridad." : "Actualicemos cómo\nquerés usar Luma.")
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(LumaPalette.ink)
            Text("En unos pasos Luma aprende qué áreas te importan y en qué momento rendís mejor. La disponibilidad se define cada día, porque tu semana no tiene por qué repetirse.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(LumaPalette.secondaryInk)
                .frame(maxWidth: 590)
            Label(
                cloudSyncService.isConfigured ? "Tu configuración también se respalda en Supabase" : "Todo empieza guardado de forma segura en esta Mac",
                systemImage: cloudSyncService.isConfigured ? "icloud.and.arrow.up.fill" : "internaldrive.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(LumaPalette.sage)
        }
    }

    private var importantAreas: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionTitle(
                eyebrow: "Tu balance",
                title: "¿Qué querés cuidar especialmente?",
                trailing: "Elegí una o varias"
            )
            Text("Luma no va a ignorar el resto, pero usará estas áreas para desempatar prioridades y detectar descuidos.")
                .foregroundStyle(LumaPalette.secondaryInk)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(LifeArea.allCases) { area in
                    Button {
                        if selectedAreas.contains(area), selectedAreas.count > 1 {
                            selectedAreas.remove(area)
                        } else {
                            selectedAreas.insert(area)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: area.symbol).font(.title2)
                            Text(area.title).font(.headline)
                            Label(
                                selectedAreas.contains(area) ? "Prioridad personal" : "Disponible",
                                systemImage: selectedAreas.contains(area) ? "checkmark.circle.fill" : "circle"
                            )
                            .font(.caption)
                        }
                        .foregroundStyle(selectedAreas.contains(area) ? area.color : LumaPalette.secondaryInk)
                        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
                        .padding(16)
                        .background(
                            selectedAreas.contains(area) ? area.color.opacity(0.11) : Color.white.opacity(0.62),
                            in: RoundedRectangle(cornerRadius: 18)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(selectedAreas.contains(area) ? area.color.opacity(0.45) : Color.clear, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: 670)
    }

    private var routine: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionTitle(
                eyebrow: "Tu disponibilidad",
                title: "Cada día puede ser distinto",
                trailing: "Sin horarios rígidos"
            )

            Text("Luma no va a asumir que todos tus lunes, martes o fines de semana se parecen. Antes de ubicar tareas, usa el tiempo que realmente tenés ese día.")
                .font(.title3)
                .foregroundStyle(LumaPalette.secondaryInk)

            VStack(spacing: 12) {
                availabilityExplanation(
                    symbol: "calendar.day.timeline.left",
                    title: "Decidís el tiempo de hoy",
                    detail: "Elegí 30 min, 1 hora, 2 horas, un día libre o armá varios bloques."
                )
                availabilityExplanation(
                    symbol: "rectangle.split.2x1.fill",
                    title: "Armá varios bloques",
                    detail: "Por ejemplo, una ventana por la mañana y otra al final de la tarde."
                )
                availabilityExplanation(
                    symbol: "calendar.badge.checkmark",
                    title: "El calendario evita choques",
                    detail: "Si lo conectás, Luma descuenta clases, turnos y otros compromisos."
                )
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz.fill")
                        .foregroundStyle(LumaPalette.lavender)
                    Text("Si hoy no tenés tiempo, marcás Día libre y no se programa nada.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(LumaPalette.secondaryInk)
                    Spacer()
                }
                .padding(14)
                .background(LumaPalette.lavender.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .frame(maxWidth: 660)
    }

    private func availabilityExplanation(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 15) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(LumaPalette.indigo)
                .frame(width: 46, height: 46)
                .background(LumaPalette.indigo.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(LumaPalette.ink)
                Text(detail).font(.subheadline).foregroundStyle(LumaPalette.secondaryInk)
            }
            Spacer()
        }
        .lumaCard(padding: 15)
    }

    private var energyMoment: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionTitle(
                eyebrow: "Tu energía",
                title: "¿Cuándo pensás con más claridad?",
                trailing: "Luma ajustará la dificultad"
            )
            Text("En tu mejor momento priorizará tareas exigentes. Fuera de esa franja favorecerá avances más livianos.")
                .foregroundStyle(LumaPalette.secondaryInk)

            VStack(spacing: 12) {
                ForEach(EnergyPeak.allCases) { moment in
                    Button { energyPeak = moment } label: {
                        HStack(spacing: 16) {
                            Image(systemName: moment.symbol)
                                .font(.title2)
                                .foregroundStyle(energyPeak == moment ? LumaPalette.indigo : LumaPalette.secondaryInk)
                                .frame(width: 48, height: 48)
                                .background(LumaPalette.indigo.opacity(energyPeak == moment ? 0.14 : 0.06), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(moment.title).font(.headline).foregroundStyle(LumaPalette.ink)
                                Text(moment.detail).font(.subheadline).foregroundStyle(LumaPalette.secondaryInk)
                            }
                            Spacer()
                            Image(systemName: energyPeak == moment ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(energyPeak == moment ? LumaPalette.sage : LumaPalette.secondaryInk)
                        }
                        .padding(16)
                        .background(Color.white.opacity(energyPeak == moment ? 0.82 : 0.55), in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: 640)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionTitle(
                eyebrow: "Ayuda cuando sirve",
                title: "Dos permisos opcionales",
                trailing: "Nada se activa sin vos"
            )

            permissionCard(
                symbol: "bell.badge.fill",
                title: "Avisos tranquilos",
                detail: "Hasta tres recordatorios según los bloques que aceptaste.",
                status: notificationService.isAuthorized ? "Activados" : "Activar",
                enabled: notificationService.isAuthorized
            ) { Task { await notificationService.requestAuthorization() } }

            permissionCard(
                symbol: "calendar.badge.clock",
                title: "Calendario de macOS",
                detail: "Evita compromisos existentes y permite enviar el plan al calendario.",
                status: calendarService.isAuthorized ? "Conectado" : "Conectar",
                enabled: calendarService.isAuthorized
            ) { Task { await calendarService.requestAccess() } }

            Text("Podés continuar sin ninguno. Luma mantiene todas sus funciones esenciales.")
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
        }
        .frame(maxWidth: 620)
    }

    private var localAI: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionTitle(
                eyebrow: "Funciones opcionales",
                title: "Conversá con Luma",
                trailing: "≈ 1,1 GB"
            )
            Text("Podés preguntarle por tus pendientes, pedirle que ordene el día y confirmar cambios desde el chat.")
                .font(.title3)
                .foregroundStyle(LumaPalette.secondaryInk)

            VStack(alignment: .leading, spacing: 14) {
                Label("Sin pagos por consulta", systemImage: "checkmark.circle.fill")
                Label("Funciona offline después de la descarga", systemImage: "checkmark.circle.fill")
                Label("Se activa solo cuando la necesitás", systemImage: "checkmark.circle.fill")
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(aiEngine.isInstalled ? "Luma ya está lista" : aiEngine.state.title)
                            .font(.headline)
                        Text("El organizador funciona aunque no la instales")
                            .font(.caption)
                            .foregroundStyle(LumaPalette.secondaryInk)
                    }
                    Spacer()
                    if !aiEngine.isInstalled {
                        Button { Task { await aiEngine.install() } } label: {
                            if aiEngine.state.isBusy { ProgressView().controlSize(.small) }
                            else { Label("Descargar", systemImage: "arrow.down.circle.fill") }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(LumaPalette.indigo)
                        .disabled(aiEngine.state.isBusy)
                    } else {
                        Label("Instalada", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(LumaPalette.sage)
                    }
                }
                if aiEngine.state.isDownloading {
                    Divider()
                    AIDownloadProgressView()
                }
            }
            .foregroundStyle(LumaPalette.sage)
            .lumaCard(padding: 22)
        }
        .frame(maxWidth: 620)
    }

    private func permissionCard(
        symbol: String,
        title: String,
        detail: String,
        status: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(enabled ? LumaPalette.sage : LumaPalette.indigo)
                .frame(width: 48, height: 48)
                .background((enabled ? LumaPalette.sage : LumaPalette.indigo).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(LumaPalette.ink)
                Text(detail).font(.subheadline).foregroundStyle(LumaPalette.secondaryInk)
            }
            Spacer()
            Button(status, action: action)
                .buttonStyle(SoftButtonStyle(color: enabled ? LumaPalette.sage : LumaPalette.indigo))
                .disabled(enabled)
        }
        .lumaCard(padding: 18)
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Atrás") { withAnimation { step -= 1 } }
                    .buttonStyle(.plain)
                    .foregroundStyle(LumaPalette.indigo)
            }
            Spacer()
            Button(step == stepCount - 1 ? "Empezar a usar Luma" : "Continuar") {
                if step < stepCount - 1 {
                    withAnimation { step += 1 }
                } else {
                    saveProfile()
                    appState.completeOnboarding()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(LumaPalette.indigo)
        }
    }

    private func saveProfile() {
        let profile: LumaProfile
        if let existing = profiles.first {
            profile = existing
        } else {
            profile = LumaProfile()
            modelContext.insert(profile)
        }
        profile.selectedAreas = selectedAreas.sorted { $0.rawValue < $1.rawValue }
        profile.energyPeak = energyPeak
        profile.updatedAt = .now
        try? modelContext.save()
    }

    private func loadProfileIfNeeded() {
        viewModel.load(profile: profiles.first)
    }
}
