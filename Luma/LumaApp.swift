import SwiftData
import SwiftUI

@main
struct LumaApp: App {
    @State private var appState = AppState()
    @State private var aiEngine = LocalAIEngine()
    @State private var notificationService = NotificationService()
    @State private var calendarService = CalendarIntegrationService()
    @State private var updateService = UpdateService()
    @State private var cloudSyncService = CloudSyncService()

    private let modelContainer: SwiftData.ModelContainer = {
        let schema = Schema([
            LumaTask.self,
            FocusSession.self,
            StudyGuide.self,
            LumaProfile.self,
            LumaChatRecord.self,
            LumaReplanRecord.self,
            AcademicSubject.self,
            SubjectGradeItem.self,
        ])
        let configuration = SwiftData.ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try SwiftData.ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("No se pudo abrir la base local de Luma: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup(id: "main") {
            AppShellView()
                .environment(appState)
                .environment(aiEngine)
                .environment(notificationService)
                .environment(calendarService)
                .environment(updateService)
                .environment(cloudSyncService)
                .environment(\.colorScheme, .light)
                .environment(\.locale, Locale(identifier: "es_AR"))
                .preferredColorScheme(.light)
                .frame(minWidth: 980, minHeight: 680)
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandMenu("Luma") {
                Button("Nuevo pendiente") {
                    appState.quickCapturePresented = true
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Ir al plan de hoy") {
                    appState.selection = .today
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Preguntale a Luma") {
                    appState.assistantPresented.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("Luma", systemImage: "moon.stars.fill") {
            MenuBarCaptureView()
                .environment(appState)
                .environment(aiEngine)
                .environment(notificationService)
                .environment(calendarService)
                .environment(updateService)
                .environment(cloudSyncService)
                .environment(\.colorScheme, .light)
                .environment(\.locale, Locale(identifier: "es_AR"))
                .preferredColorScheme(.light)
                .tint(LumaPalette.indigo)
                .modelContainer(modelContainer)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
                .environment(aiEngine)
                .environment(notificationService)
                .environment(calendarService)
                .environment(updateService)
                .environment(cloudSyncService)
                .environment(\.colorScheme, .light)
                .environment(\.locale, Locale(identifier: "es_AR"))
                .preferredColorScheme(.light)
                .tint(LumaPalette.indigo)
                .frame(width: 720, height: 650)
                .modelContainer(modelContainer)
        }
    }
}
