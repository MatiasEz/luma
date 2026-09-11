import SwiftData
import SwiftUI

@main
struct LumaApp: App {
    // Hosted unit tests must not open the user's store or start dashboard sync.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

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
            SubjectClassMeeting.self,
            AcademicRoutine.self,
            AcademicExam.self,
            DailyPlanningContext.self,
        ])
        let configuration = SwiftData.ModelConfiguration(schema: schema, isStoredInMemoryOnly: LumaApp.isRunningTests)
        do {
            return try SwiftData.ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("No se pudo abrir la base local de Luma: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup(id: "main") {
            if Self.isRunningTests {
                Color.clear
            } else {
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
            if !Self.isRunningTests {
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
        }
        .menuBarExtraStyle(.window)

        Settings {
            if !Self.isRunningTests {
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
}
