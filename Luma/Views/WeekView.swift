import SwiftData
import SwiftUI

private struct MonthDaySelection: Identifiable {
    let day: Date
    var id: Date { day }
}

struct WeekView: View {
    @Environment(AppState.self) private var appState
    @Environment(CalendarIntegrationService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LumaTask.deadline) private var tasks: [LumaTask]
    @Query(sort: \AcademicSubject.name) private var subjects: [AcademicSubject]
    @Query(sort: \SubjectClassMeeting.startMinuteOfDay) private var classMeetings: [SubjectClassMeeting]
    @Query(sort: \AcademicExam.date) private var exams: [AcademicExam]
    @Query(sort: \DailyPlanningContext.day) private var dailyContexts: [DailyPlanningContext]
    @State private var viewModel = WeekViewModel()
    @State private var selectedTimelineTaskGroup: TimelineTaskGroupSelection?
    @State private var selectedMonthDay: MonthDaySelection?
    @State private var newTaskMonthDay: MonthDaySelection?
    @State private var newExamDay: MonthDaySelection?
    @State private var selectedWorkBlock: PlannedWorkBlock?
    @State private var availabilityPresented = false

    // La bandeja de tareas sin fecha queda implementada, pero oculta temporalmente.
    private let showsUndatedTaskTray = true

    private let calendar: Calendar = {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "es_AR")
        return calendar
    }()
    private let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 7)
    private let timelineTimeGutter: CGFloat = 64
    private let timelineHourHeight: CGFloat = 68
    private let timelineDayMinimumWidth: CGFloat = 96
    private let timelineViewportHeight: CGFloat = 640

    private var days: [Date] {
        viewModel.visibleDays(calendar: calendar)
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    calendarHeader
                    HStack {
                        Button { newExamDay = MonthDaySelection(day: viewModel.referenceDate) } label: { Label("Agregar examen", systemImage: "graduationcap") }
                        Button("Definir horarios de hoy") { availabilityPresented = true }
                        Spacer()
                    }.tint(LumaPalette.indigo)

                    if !viewModel.scheduleFeedback.isEmpty {
                        Label(viewModel.scheduleFeedback, systemImage: "calendar.badge.checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LumaPalette.sage)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(LumaPalette.sage.opacity(0.09), in: Capsule())
                    }

                    if viewModel.span == .week {
                        SharedWeekPlanView(days: days, tasks: tasks) { task, block in selectedWorkBlock = block; viewModel.selectedTask = task }
                    }
                    calendarGrid(availableHeight: viewport.size.height)
                    if showsUndatedTaskTray {
                        tasksWithoutDate
                    }
                }
                .padding(28)
                .lumaScrollContent()
            }
            .lumaScrollSurface()
        }
        .navigationTitle("Calendario")
        .sheet(isPresented: $availabilityPresented) { AgendaSettingsView().frame(width: 700, height: 680) }
        .task(id: tasks.map { "\($0.id):\($0.updatedAt)" }.joined() + "\(appState.planRevision)") {
            calendarService.refreshCommitments()
            let planner = TaskPlanner(availableMinutes: appState.remainingAvailableMinutes(fallback: appState.availability().availableMinutes),
                classMeetings: classMeetings, subjectNames: Dictionary(uniqueKeysWithValues: subjects.map { ($0.id, $0.name) }),
                weeklyAvailability: appState.weeklyAvailability, restCounts: dailyContexts.first { Calendar.current.isDateInToday($0.day) }?.restCounts ?? true)
            _ = appState.prepareDailyPlan(from: tasks, planner: planner)
            appState.refreshSharedPlan(tasks: tasks, planner: planner, busyBlocks: calendarService.busyBlocks())
        }
        .sheet(isPresented: Binding(
            get: { viewModel.isTimePickerPresented },
            set: { isPresented in
                if !isPresented { viewModel.cancelScheduling() }
            }
        )) {
            timePickerSheet
        }
        .sheet(isPresented: Binding(
            get: { viewModel.selectedTask != nil },
            set: { if !$0 { viewModel.selectedTask = nil } }
        )) {
            if let task = viewModel.selectedTask {
                TaskDetailPanel(
                    task: task,
                    subjectName: viewModel.subjectName(for: task, subjects: subjects),
                    blockers: viewModel.blockerNames(for: task, tasks: tasks),
                    unlockedTaskName: viewModel.unlockedTaskName(for: task, tasks: tasks),
                    isCalendarSynced: calendarService.isTaskSynced(task.id),
                    onClose: { viewModel.selectedTask = nil },
                    onEdit: { openEditor(for: task) },
                    onStart: {
                        viewModel.selectedTask = nil
                        appState.startFocus(for: task.id, durationMinutes: selectedWorkBlock?.taskID == task.id ? selectedWorkBlock?.minutes : nil, plannedBlockID: selectedWorkBlock?.taskID == task.id ? selectedWorkBlock?.id : nil)
                    },
                    onToggleCompletion: { toggleCompletion(task) }
                )
                .frame(width: 430, height: 700)
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.selectedExam != nil },
            set: { if !$0 { viewModel.selectedExam = nil } }
        )) {
            if let exam = viewModel.selectedExam {
                examDetailSheet(exam)
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.editingTask != nil },
            set: { if !$0 { viewModel.editingTask = nil } }
        )) {
            if let task = viewModel.editingTask {
                TaskEditorView(task: task)
                    .frame(width: 720, height: 690)
            }
        }
        .sheet(item: $selectedTimelineTaskGroup) { selection in
            timelineTaskGroupSheet(selection)
        }
        .sheet(item: $selectedMonthDay) { selection in
            monthDayItemsSheet(selection.day)
        }
        .sheet(item: $newExamDay) { selection in
            ExamEditorView(exam: nil, initialDate: selection.day) { exam, topics, fileName in
                modelContext.insert(exam)
                if exam.shouldPrepare {
                    AcademicPlanningService().materializeGeneratedExamStudy(exam: exam, topics: topics, sourceFileName: fileName, tasks: tasks, in: modelContext)
                    AcademicPlanningService().materialize(routines: [], exams: [exam], tasks: tasks, dailyContext: nil, in: modelContext, saveChanges: false)
                }
                try modelContext.save()
                appState.refreshPlan()
            }
        }
        .sheet(item: $newTaskMonthDay) { selection in
            QuickCaptureView(scheduledDate: defaultTaskDate(on: selection.day))
                .frame(width: 720, height: 700)
        }
    }

    private var calendarHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 18) {
                    periodHeading
                    Spacer(minLength: 20)
                    calendarControls
                }
                VStack(alignment: .leading, spacing: 14) {
                    periodHeading
                    calendarControls
                }
            }

            if showsUndatedTaskTray {
                Text("Arrastrá una tarea sin fecha al día que quieras y elegí la hora.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
        }
    }

    private var periodHeading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(viewModel.span == .week ? "CALENDARIO SEMANAL" : "CALENDARIO MENSUAL")
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(LumaPalette.sage)
            Text(viewModel.periodTitle(calendar: calendar))
                .font(.title2.weight(.semibold))
                .foregroundStyle(LumaPalette.ink)
                .textCase(nil)
        }
    }

    private var calendarControls: some View {
        HStack(spacing: 9) {
            Picker("Vista", selection: Binding(
                get: { viewModel.span },
                set: {
                    viewModel.span = $0
                    viewModel.scheduleFeedback = ""
                }
            )) {
                ForEach(CalendarSpan.allCases) { span in
                    Text(span.title).tag(span)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            Button {
                viewModel.movePeriod(-1, calendar: calendar)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .help(viewModel.span == .week ? "Semana anterior" : "Mes anterior")

            Button("Hoy") {
                viewModel.showToday()
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.movePeriod(1, calendar: calendar)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .help(viewModel.span == .week ? "Semana siguiente" : "Mes siguiente")
        }
    }

    @ViewBuilder
    private func calendarGrid(availableHeight: CGFloat) -> some View {
        if viewModel.span == .week {
            weeklyTimeline
        } else {
            monthlyCalendarGrid(availableHeight: availableHeight)
        }
    }

    private func monthlyCalendarGrid(availableHeight: CGFloat) -> some View {
        let rowCount = max(1, Int(ceil(Double(days.count) / 7.0)))
        let availableForDays = max(0, availableHeight - 190 - CGFloat(max(0, rowCount - 1)) * 8)
        let dayHeight = max(124, min(150, availableForDays / CGFloat(rowCount)))

        return VStack(spacing: 10) {
            weekdayHeader

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(days, id: \.self) { day in
                    dayCell(day, fixedHeight: dayHeight)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(Color.white.opacity(0.30), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(0.72), lineWidth: 1)
        }
    }

    private var weeklyTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            weeklyTimelineLegend

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    weeklyTimelineDayHeader
                    if hasUntimedItemsInVisibleWeek {
                        Divider().opacity(0.45)
                        weeklyUntimedTasksRow
                    }
                    Divider().opacity(0.55)
                    weeklyScrollableHours
                }
                .containerRelativeFrame(.horizontal)
                .frame(minWidth: timelineTimeGutter + timelineDayMinimumWidth * 7)
            }
            .background(Color.white.opacity(0.34), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.74), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var weeklyTimelineLegend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                timelineLegendItem(title: "Clases", color: LumaPalette.indigo, symbol: "person.3.fill")
                timelineLegendItem(title: "Tareas", color: LumaPalette.sage, symbol: "checklist")
                timelineLegendItem(title: "Tiempo libre", color: LumaPalette.sage.opacity(0.22), symbol: "circle.dashed")
                Spacer(minLength: 16)
                Text("Los espacios sin bloques son tus huecos disponibles.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    timelineLegendItem(title: "Clases", color: LumaPalette.indigo, symbol: "person.3.fill")
                    timelineLegendItem(title: "Tareas", color: LumaPalette.sage, symbol: "checklist")
                    timelineLegendItem(title: "Libre", color: LumaPalette.sage.opacity(0.22), symbol: "circle.dashed")
                }
                Text("Los espacios sin bloques son tus huecos disponibles.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
        }
    }

    private func timelineLegendItem(title: String, color: Color, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(LumaPalette.secondaryInk)
            .symbolRenderingMode(.monochrome)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.16), in: Capsule())
    }

    private var weeklyTimelineDayHeader: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: timelineTimeGutter, height: 66)

            ForEach(days, id: \.self) { day in
                let isToday = calendar.isDateInToday(day)
                VStack(spacing: 4) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "es_AR"))).uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(0.7)
                        .foregroundStyle(isToday ? LumaPalette.indigo : LumaPalette.secondaryInk)
                    Text(day, format: .dateTime.day())
                        .font(.headline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isToday ? Color.white : LumaPalette.ink)
                        .frame(width: 31, height: 31)
                        .background(isToday ? LumaPalette.indigo : Color.clear, in: Circle())
                }
                .frame(maxWidth: .infinity)
                .frame(height: 66)
                .background(isToday ? LumaPalette.indigo.opacity(0.035) : Color.clear)
                .overlay(alignment: .trailing) {
                    Divider().opacity(0.35)
                }
            }
        }
    }

    private var hasUntimedItemsInVisibleWeek: Bool {
        days.contains {
            !untimedTasks(on: $0).isEmpty || !examOccurrences(on: $0).isEmpty
        }
    }

    private var weeklyUntimedTasksRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("SIN HORA")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(LumaPalette.secondaryInk)
                .frame(width: timelineTimeGutter - 8, alignment: .trailing)
                .padding(.top, 10)
                .padding(.trailing, 8)

            ForEach(days, id: \.self) { day in
                let dayTasks = untimedTasks(on: day)
                let dayExams = examOccurrences(on: day)
                let visibleExams = Array(dayExams.prefix(1))
                let remainingTaskSlots = max(0, 2 - visibleExams.count)
                let visibleTasks = Array(dayTasks.prefix(remainingTaskSlots))
                let hiddenCount = dayExams.count + dayTasks.count - visibleExams.count - visibleTasks.count
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleExams) { occurrence in
                        weeklyExamChip(occurrence)
                    }

                    ForEach(visibleTasks) { task in
                        Button {
                            viewModel.selectedTask = task
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : taskCalendarSymbol(task))
                                    .font(.system(size: task.isCompleted ? 10 : 8))
                                Text(task.title)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(taskCalendarAccent(task))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(taskCalendarAccent(task).opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }
                    if hiddenCount > 0 {
                        Text("+\(hiddenCount) más")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(LumaPalette.indigo)
                    }
                }
                .padding(5)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
                .overlay(alignment: .trailing) {
                    Divider().opacity(0.35)
                }
            }
        }
        .background(Color.white.opacity(0.18))
    }

    private func weeklyExamChip(_ occurrence: CalendarExamOccurrence) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 9))
            Text(occurrence.exam.title)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
        }
        .foregroundStyle(LumaPalette.terracotta)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LumaPalette.terracotta.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(LumaPalette.terracotta.opacity(0.28), lineWidth: 1)
        }
        .help("Examen · \(occurrence.subject.name) · \(occurrence.exam.title)")
    }

    private var weeklyScrollableHours: some View {
        ScrollView(.vertical, showsIndicators: true) {
            GeometryReader { geometry in
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    weeklyTimelineCanvas(width: geometry.size.width, now: timeline.date)
                }
            }
            .frame(height: visibleTimelineHeight + 1)
        }
        .frame(height: timelineViewportHeight)
    }

    private func weeklyTimelineCanvas(width: CGFloat, now: Date) -> some View {
        let usableWidth = max(1, width - timelineTimeGutter)
        let dayWidth = usableWidth / 7

        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.white.opacity(0.16)
                    .frame(width: timelineTimeGutter)

                ForEach(days, id: \.self) { day in
                    Rectangle()
                        .fill(calendar.isDateInToday(day) ? LumaPalette.indigo.opacity(0.035) : Color.white.opacity(0.12))
                        .frame(width: dayWidth)
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(LumaPalette.ink.opacity(0.08))
                                .frame(width: 1)
                        }
                }
            }
            .frame(height: visibleTimelineHeight)

            ForEach(visibleTimelineStartHour ..< 24, id: \.self) { hour in
                HStack(spacing: 0) {
                    Text(String(format: "%02d:00", hour))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(LumaPalette.secondaryInk)
                        .frame(width: timelineTimeGutter - 8, alignment: .trailing)
                        .padding(.trailing, 8)
                    Rectangle()
                        .fill(LumaPalette.ink.opacity(0.11))
                        .frame(height: 1)
                }
                .frame(width: width)
                .offset(y: CGFloat(hour - visibleTimelineStartHour) * timelineHourHeight)
            }

            ForEach(visibleTimelineStartHour ..< 24, id: \.self) { hour in
                Rectangle()
                    .fill(LumaPalette.ink.opacity(0.045))
                    .frame(width: usableWidth, height: 1)
                    .offset(
                        x: timelineTimeGutter,
                        y: (CGFloat(hour - visibleTimelineStartHour) + 0.5) * timelineHourHeight
                    )
            }

            ForEach(Array(days.enumerated()), id: \.offset) { dayIndex, day in
                ForEach(positionedTimelineEntries(on: day)) { positioned in
                    positionedTimelineEntryView(
                        positioned,
                        dayIndex: dayIndex,
                        dayWidth: dayWidth
                    )
                }
            }

            currentTimeIndicator(width: width, dayWidth: dayWidth, now: now)
        }
        .frame(width: width, height: visibleTimelineHeight, alignment: .topLeading)
        .clipped()
    }

    private func positionedTimelineEntryView(
        _ positioned: PositionedWeekTimelineEntry,
        dayIndex: Int,
        dayWidth: CGFloat
    ) -> some View {
        // Nunca dejamos que una tarjeta invada el día siguiente. Cuando hay demasiadas
        // superposiciones, las tareas se agrupan antes de llegar a este punto.
        let laneWidth = max(1, (dayWidth - 8) / CGFloat(max(1, positioned.laneCount)))
        let x = timelineTimeGutter
            + CGFloat(dayIndex) * dayWidth
            + 4
            + CGFloat(positioned.lane) * laneWidth
        let y = CGFloat(positioned.entry.startMinute - visibleTimelineStartMinute) / 60 * timelineHourHeight + 2
        let durationHeight = CGFloat(positioned.entry.endMinute - positioned.entry.startMinute) / 60 * timelineHourHeight
        let height = max(28, durationHeight - 4)

        return timelineEntryContent(positioned.entry, height: height)
            .frame(width: max(1, laneWidth - 4), height: height, alignment: .topLeading)
            .offset(x: x, y: y)
            .zIndex(positioned.entry.isTask ? 2 : 1)
    }

    @ViewBuilder
    private func timelineEntryContent(_ entry: WeekTimelineEntry, height: CGFloat) -> some View {
        switch entry.content {
        case let .task(task):
            let accent = taskCalendarAccent(task)
            Button {
                viewModel.selectedTask = task
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: task.isCompleted ? "checkmark.circle.fill" : taskCalendarSymbol(task))
                            .font(.caption2)
                        if height >= 43 {
                            Text(String(format: "%02d:%02d · %d min", entry.startMinute / 60, entry.startMinute % 60, entry.endMinute - entry.startMinute))
                                .font(.caption2.weight(.bold).monospacedDigit())
                        }
                    }
                    .foregroundStyle(accent)

                    Text(task.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(task.isCompleted ? LumaPalette.secondaryInk : LumaPalette.ink)
                        .strikethrough(task.isCompleted, color: LumaPalette.secondaryInk)
                        .lineLimit(height >= 66 ? 2 : 1)

                    if height >= 88 {
                        Text("\(task.estimatedMinutes) min")
                            .font(.caption2)
                            .foregroundStyle(LumaPalette.secondaryInk)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(accent.opacity(task.isCompleted ? 0.10 : 0.13), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(accent.opacity(0.30), lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                Capsule().fill(accent).frame(width: 3).padding(.vertical, 5).padding(.leading, 3)
            }
            .opacity(task.isCompleted ? 0.78 : 1)
            .help(task.title)

        case let .taskGroup(tasks):
            Button {
                selectedTimelineTaskGroup = TimelineTaskGroupSelection(tasks: tasks)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.caption2)
                        Text("\(tasks.count) tareas")
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(LumaPalette.indigo)

                    if height >= 54 {
                        Text("A la misma hora")
                            .font(.caption2)
                            .foregroundStyle(LumaPalette.secondaryInk)
                            .lineLimit(1)
                    }

                    if height >= 86 {
                        Text("Abrir lista")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(LumaPalette.indigo)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(LumaPalette.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(LumaPalette.indigo.opacity(0.32), lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(LumaPalette.indigo)
                    .frame(width: 3)
                    .padding(.vertical, 5)
                    .padding(.leading, 3)
            }
            .help("\(tasks.count) tareas superpuestas. Hacé clic para verlas.")

        case let .classMeeting(occurrence):
            let accent = subjectColor(for: occurrence.subject.colorHex)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "person.3.fill")
                        .font(.caption2)
                    Text(classTimeLabel(occurrence.meeting))
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .lineLimit(1)
                }
                .foregroundStyle(accent)

                Text(occurrence.subject.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
                    .lineLimit(height >= 68 ? 2 : 1)

                if height >= 92 {
                    Text(occurrence.meeting.location.isEmpty ? "Clase" : occurrence.meeting.location)
                        .font(.caption2)
                        .foregroundStyle(LumaPalette.secondaryInk)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(accent.opacity(0.36), lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                Capsule().fill(accent).frame(width: 3).padding(.vertical, 5).padding(.leading, 3)
            }
            .help(classHelpText(occurrence))
        }
    }

    @ViewBuilder
    private func currentTimeIndicator(width: CGFloat, dayWidth: CGFloat, now: Date) -> some View {
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        if minute >= visibleTimelineStartMinute,
           let dayIndex = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: now) }) {
            let y = CGFloat(minute - visibleTimelineStartMinute) / 60 * timelineHourHeight
            let x = timelineTimeGutter + CGFloat(dayIndex) * dayWidth

            HStack(spacing: 0) {
                Circle()
                    .fill(LumaPalette.terracotta)
                    .frame(width: 7, height: 7)
                Rectangle()
                    .fill(LumaPalette.terracotta)
                    .frame(height: 1.5)
            }
            .frame(width: dayWidth, alignment: .leading)
            .offset(x: x, y: y - 3)
            .zIndex(5)
        }
    }

    private var visibleTimelineStartHour: Int {
        let earliestMinute = days
            .flatMap { timelineEntries(on: $0) }
            .map(\.startMinute)
            .min() ?? 8 * 60
        return max(0, min(23, earliestMinute / 60))
    }

    private var visibleTimelineStartMinute: Int {
        visibleTimelineStartHour * 60
    }

    private var visibleTimelineHourCount: Int {
        max(1, 24 - visibleTimelineStartHour)
    }

    private var visibleTimelineHeight: CGFloat {
        timelineHourHeight * CGFloat(visibleTimelineHourCount)
    }

    private func untimedTasks(on day: Date) -> [LumaTask] {
        viewModel.tasks(on: day, from: tasks, calendar: calendar)
            .filter { task in
                if task.dueDate.map({ calendar.isDate($0, inSameDayAs: day) }) == true { return true }
                guard let deadline = task.deadline else { return false }
                return isUntimedDeadline(deadline)
            }
    }

    private func examOccurrences(on day: Date) -> [CalendarExamOccurrence] {
        viewModel.examOccurrences(
            on: day,
            from: exams,
            subjects: subjects,
            calendar: calendar
        )
    }

    private func timelineEntries(on day: Date) -> [WeekTimelineEntry] {
        let timed = appState.workBlocks(on: day).filter { $0.startMinute != nil }
        let sharedEntries = timed.compactMap { block -> WeekTimelineEntry? in
            guard let task = tasks.first(where: { $0.id == block.taskID }), let start = block.startMinute else { return nil }
            return WeekTimelineEntry(id: "block-\(block.id)", startMinute: start, endMinute: start + block.minutes, content: .task(task))
        }
        let taskEntries = viewModel.tasks(on: day, from: tasks, calendar: calendar).compactMap { task -> WeekTimelineEntry? in
            guard !timed.contains(where: { $0.taskID == task.id }), let deadline = task.deadline, calendar.isDate(deadline, inSameDayAs: day), !isUntimedDeadline(deadline) else { return nil }
            let start = calendar.component(.hour, from: deadline) * 60
                + calendar.component(.minute, from: deadline)
            let end = min(24 * 60, start + (appState.workBlocks(on: day, taskID: task.id).first(where: { $0.status != .completed })?.minutes ?? min(45, task.remainingEstimatedMinutes)))
            return WeekTimelineEntry(
                id: "task-\(task.id.uuidString)",
                startMinute: start,
                endMinute: max(start + 1, end),
                content: .task(task)
            )
        }
        let meetingEntries = viewModel.classMeetings(
            on: day,
            from: classMeetings,
            subjects: subjects,
            calendar: calendar
        ).map { occurrence in
            WeekTimelineEntry(
                id: "class-\(occurrence.id.uuidString)",
                startMinute: occurrence.meeting.startMinuteOfDay,
                endMinute: occurrence.meeting.endMinuteOfDay,
                content: .classMeeting(occurrence)
            )
        }

        return (meetingEntries + taskEntries + sharedEntries).sorted {
            if $0.startMinute != $1.startMinute { return $0.startMinute < $1.startMinute }
            if $0.endMinute != $1.endMinute { return $0.endMinute < $1.endMinute }
            return $0.id < $1.id
        }
    }

    private func positionedTimelineEntries(on day: Date) -> [PositionedWeekTimelineEntry] {
        let entries = timelineEntries(on: day)
        guard !entries.isEmpty else { return [] }

        var clusters: [[WeekTimelineEntry]] = []
        var current: [WeekTimelineEntry] = []
        var currentEnd = -1

        for entry in entries {
            if current.isEmpty || entry.startMinute < currentEnd {
                current.append(entry)
                currentEnd = max(currentEnd, entry.endMinute)
            } else {
                clusters.append(current)
                current = [entry]
                currentEnd = entry.endMinute
            }
        }
        if !current.isEmpty { clusters.append(current) }

        return clusters.flatMap(positionTimelineCluster)
    }

    private func positionTimelineCluster(_ entries: [WeekTimelineEntry]) -> [PositionedWeekTimelineEntry] {
        let initialLaneCount = timelineLaneCount(for: entries)
        let taskEntries = entries.filter(\.isTask)
        let entriesToPosition: [WeekTimelineEntry]

        if initialLaneCount > 2, taskEntries.count > 1 {
            let groupedTasks = taskEntries.flatMap(\.tasks)
            let groupedEntry = WeekTimelineEntry(
                id: "task-group-" + groupedTasks.map { $0.id.uuidString }.joined(separator: "-"),
                startMinute: taskEntries.map(\.startMinute).min() ?? 0,
                endMinute: taskEntries.map(\.endMinute).max() ?? 1,
                content: .taskGroup(groupedTasks)
            )
            entriesToPosition = (entries.filter { !$0.isTask } + [groupedEntry]).sorted {
                if $0.startMinute != $1.startMinute { return $0.startMinute < $1.startMinute }
                return $0.id < $1.id
            }
        } else {
            entriesToPosition = entries
        }

        var laneEnds: [Int] = []
        var assignments: [(WeekTimelineEntry, Int)] = []

        for entry in entriesToPosition {
            let lane: Int
            if let available = laneEnds.firstIndex(where: { $0 <= entry.startMinute }) {
                lane = available
                laneEnds[available] = entry.endMinute
            } else {
                lane = laneEnds.count
                laneEnds.append(entry.endMinute)
            }
            assignments.append((entry, lane))
        }

        let laneCount = max(1, laneEnds.count)
        return assignments.map {
            PositionedWeekTimelineEntry(entry: $0.0, lane: $0.1, laneCount: laneCount)
        }
    }

    private func timelineLaneCount(for entries: [WeekTimelineEntry]) -> Int {
        var laneEnds: [Int] = []
        for entry in entries {
            if let available = laneEnds.firstIndex(where: { $0 <= entry.startMinute }) {
                laneEnds[available] = entry.endMinute
            } else {
                laneEnds.append(entry.endMinute)
            }
        }
        return max(1, laneEnds.count)
    }

    private func timelineTaskGroupSheet(_ selection: TimelineTaskGroupSelection) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tareas a la misma hora")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                    Text("Elegí una tarea para abrir su detalle.")
                        .font(.subheadline)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                Spacer()
                Button {
                    selectedTimelineTaskGroup = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(selection.tasks) { task in
                        Button {
                            selectedTimelineTaskGroup = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                viewModel.selectedTask = task
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(task.isCompleted ? LumaPalette.sage : task.area.color)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(LumaPalette.ink)
                                        .lineLimit(2)
                                    HStack(spacing: 8) {
                                        if let deadline = task.deadline {
                                            Text(taskTimeLabel(deadline))
                                        }
                                        Text("\(task.estimatedMinutes) min")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(LumaPalette.secondaryInk)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(LumaPalette.secondaryInk)
                            }
                            .padding(14)
                            .background(Color.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 14))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 480, height: min(650, 180 + CGFloat(selection.tasks.count) * 76))
        .background(LumaBackground())
    }

    private func monthDayItemsSheet(_ day: Date) -> some View {
        let items = viewModel.calendarItems(
            on: day,
            tasks: tasks,
            meetings: classMeetings,
            exams: exams,
            subjects: subjects,
            includeClassMeetings: false,
            calendar: calendar
        )

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(day.formatted(
                        .dateTime
                            .weekday(.wide)
                            .day()
                            .month(.wide)
                            .locale(Locale(identifier: "es_AR"))
                    ).capitalized)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)

                    Text(items.count == 1 ? "1 actividad" : "\(items.count) actividades")
                        .font(.subheadline)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }

                Spacer()

                Button {
                    selectedMonthDay = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .help("Cerrar")
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        monthDayItemRow(item)
                    }
                }
            }
        }
        .padding(24)
        .frame(
            width: 520,
            height: min(680, max(280, 150 + CGFloat(items.count) * 72))
        )
        .background(LumaBackground())
    }

    private func examDetailSheet(_ exam: AcademicExam) -> some View {
        let subjectName = subjects.first(where: { $0.id == exam.subjectID })?.name ?? "Materia"
        let studyTasks = tasks
            .filter { $0.sourceID == exam.id && $0.academicSourceType == .examStudy }
            .sorted { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }
        let completedCount = studyTasks.filter(\.isCompleted).count
        let progress = studyTasks.isEmpty ? 0 : Double(completedCount) / Double(studyTasks.count)

        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "graduationcap.fill")
                    .font(.title2)
                    .foregroundStyle(LumaPalette.terracotta)
                    .frame(width: 48, height: 48)
                    .background(LumaPalette.terracotta.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text("EXAMEN")
                        .font(.caption.weight(.bold))
                        .tracking(0.9)
                        .foregroundStyle(LumaPalette.terracotta)
                    Text(exam.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subjectName)
                        .font(.subheadline)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }

                Spacer(minLength: 12)

                Button {
                    viewModel.selectedExam = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .help("Cerrar")
            }
            .padding(24)

            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("DETALLES")
                            .font(.caption.weight(.bold))
                            .tracking(1)
                            .foregroundStyle(LumaPalette.sage)

                        examDetailRow(
                            symbol: "calendar",
                            title: "Fecha",
                            value: exam.date.formatted(
                                .dateTime
                                    .weekday(.wide)
                                    .day()
                                    .month(.wide)
                                    .year()
                                    .locale(Locale(identifier: "es_AR"))
                            ).capitalized
                        )
                        examDetailRow(symbol: "flag.fill", title: "Importancia", value: exam.importance.title)
                        examDetailRow(
                            symbol: "clock",
                            title: "Preparación estimada",
                            value: preparationDurationLabel(exam.preparationMinutes)
                        )
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("TEMARIO")
                            .font(.caption.weight(.bold))
                            .tracking(1)
                            .foregroundStyle(LumaPalette.sage)

                        if exam.topics.isEmpty {
                            Text("Sin temario cargado")
                                .font(.subheadline)
                                .foregroundStyle(LumaPalette.secondaryInk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Color.white.opacity(0.50), in: RoundedRectangle(cornerRadius: 14))
                        } else {
                            VStack(alignment: .leading, spacing: 9) {
                                ForEach(Array(exam.topics.enumerated()), id: \.offset) { index, topic in
                                    HStack(alignment: .top, spacing: 10) {
                                        Text("\(index + 1)")
                                            .font(.caption2.weight(.bold).monospacedDigit())
                                            .foregroundStyle(LumaPalette.indigo)
                                            .frame(width: 24, height: 24)
                                            .background(LumaPalette.indigo.opacity(0.09), in: Circle())
                                        Text(topic)
                                            .font(.subheadline)
                                            .foregroundStyle(LumaPalette.ink)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                            .padding(14)
                            .background(Color.white.opacity(0.50), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("PLAN DE ESTUDIO")
                                .font(.caption.weight(.bold))
                                .tracking(1)
                                .foregroundStyle(LumaPalette.sage)
                            Spacer()
                            if !studyTasks.isEmpty {
                                Text("\(completedCount) de \(studyTasks.count) completadas")
                                    .font(.caption)
                                    .foregroundStyle(LumaPalette.secondaryInk)
                            }
                        }

                        if studyTasks.isEmpty {
                            Text("Este examen todavía no tiene sesiones de estudio asociadas.")
                                .font(.subheadline)
                                .foregroundStyle(LumaPalette.secondaryInk)
                        } else {
                            ProgressView(value: progress)
                                .tint(LumaPalette.sage)

                            VStack(spacing: 0) {
                                ForEach(studyTasks) { task in
                                    HStack(spacing: 10) {
                                        Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(task.isCompleted ? LumaPalette.sage : LumaPalette.indigo)
                                        Text(task.title)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(LumaPalette.ink)
                                            .strikethrough(task.isCompleted, color: LumaPalette.secondaryInk)
                                            .lineLimit(2)
                                        Spacer(minLength: 8)
                                        Text("\(task.estimatedMinutes) min")
                                            .font(.caption)
                                            .foregroundStyle(LumaPalette.secondaryInk)
                                    }
                                    .padding(.vertical, 9)

                                    if task.id != studyTasks.last?.id {
                                        Divider().opacity(0.4)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .background(Color.white.opacity(0.50), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                .padding(24)
            }

            Divider().opacity(0.5)

            HStack {
                Spacer()
                Button("Cerrar") {
                    viewModel.selectedExam = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(LumaPalette.indigo)

                Button {
                    viewModel.selectedExam = nil
                    appState.selection = .exams
                } label: {
                    Label("Ver en Exámenes", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(LumaPalette.indigo)
            }
            .padding(20)
        }
        .frame(width: 560, height: 700)
        .background(LumaBackground())
    }

    private func examDetailRow(symbol: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(LumaPalette.indigo)
                .frame(width: 24)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(LumaPalette.secondaryInk)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(LumaPalette.ink)
                .multilineTextAlignment(.trailing)
        }
    }

    private func preparationDurationLabel(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours == 0 { return "\(remainingMinutes) min" }
        if remainingMinutes == 0 { return hours == 1 ? "1 hora" : "\(hours) horas" }
        return "\(hours) h \(remainingMinutes) min"
    }

    @ViewBuilder
    private func monthDayItemRow(_ item: CalendarDayItem) -> some View {
        switch item {
        case let .task(task):
            Button {
                selectedMonthDay = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    viewModel.selectedTask = task
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : taskCalendarSymbol(task))
                        .font(.title3)
                        .foregroundStyle(taskCalendarAccent(task))
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LumaPalette.ink)
                            .strikethrough(task.isCompleted, color: LumaPalette.secondaryInk)
                            .lineLimit(2)

                        HStack(spacing: 8) {
                            if let deadline = task.deadline {
                                Text(taskTimeLabel(deadline))
                            }
                            Text("\(task.estimatedMinutes) min")
                            if task.academicSourceType == .routine {
                                Label("Rutina", systemImage: "arrow.triangle.2.circlepath")
                            }
                            Text(task.area.title)
                        }
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(LumaPalette.secondaryInk)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        case let .exam(occurrence):
            Button {
                selectedMonthDay = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    viewModel.selectedExam = occurrence.exam
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "graduationcap.fill")
                        .font(.title3)
                        .foregroundStyle(LumaPalette.terracotta)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(occurrence.exam.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LumaPalette.ink)
                            .lineLimit(2)

                        Text(occurrence.subject.name)
                            .font(.caption)
                            .foregroundStyle(LumaPalette.secondaryInk)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Text("EXAMEN")
                        .font(.caption2.weight(.bold))
                        .tracking(0.5)
                        .foregroundStyle(LumaPalette.terracotta)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(LumaPalette.terracotta.opacity(0.12), in: Capsule())
                        .fixedSize()
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LumaPalette.terracotta.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(LumaPalette.terracotta.opacity(0.24), lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        case let .classMeeting(occurrence):
            HStack(spacing: 12) {
                Image(systemName: "person.3.fill")
                    .font(.title3)
                    .foregroundStyle(subjectColor(for: occurrence.subject.colorHex))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(occurrence.subject.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                        .lineLimit(2)
                    Text(classTimeLabel(occurrence.meeting))
                        .font(.caption)
                        .foregroundStyle(LumaPalette.secondaryInk)
                }

                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func isUntimedDeadline(_ date: Date) -> Bool {
        calendar.component(.hour, from: date) == 23
            && calendar.component(.minute, from: date) == 59
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(viewModel.weekdaySymbols(calendar: calendar), id: \.self) { symbol in
                Text(symbol.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
    }

    private func dayCell(_ day: Date, fixedHeight: CGFloat? = nil) -> some View {
        let dayItems = viewModel.calendarItems(
            on: day,
            tasks: tasks,
            meetings: classMeetings,
            exams: exams,
            subjects: subjects,
            includeClassMeetings: false,
            calendar: calendar
        )
        let isToday = calendar.isDateInToday(day)
        let isCurrentMonth = viewModel.span == .week
            || viewModel.isInDisplayedMonth(day, calendar: calendar)
        let isCompactMonth = viewModel.span == .month
        let displayedItems = isCompactMonth ? monthlyPrioritizedItems(dayItems) : dayItems
        let visibleLimit = isCompactMonth ? min(2, displayedItems.count) : 5
        let hiddenItemCount = max(0, displayedItems.count - visibleLimit)

        return VStack(alignment: .leading, spacing: isCompactMonth ? 4 : 8) {
            if isCompactMonth {
                Button {
                    newTaskMonthDay = MonthDaySelection(day: day)
                } label: {
                    dayCellHeader(day, isToday: isToday)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Agregar una tarea el \(day.formatted(date: .long, time: .omitted))")
                .help("Agregar una tarea este día")
            } else {
                dayCellHeader(day, isToday: isToday)
            }

            if !displayedItems.isEmpty {
                ForEach(displayedItems.prefix(visibleLimit)) { item in
                    switch item {
                    case let .exam(occurrence):
                        calendarExamChip(occurrence, compact: viewModel.span == .month)
                    case let .task(task):
                        calendarTaskChip(task, compact: viewModel.span == .month, day: day)
                    case let .classMeeting(occurrence):
                        calendarClassChip(occurrence, compact: viewModel.span == .month)
                    }
                }

                if isCompactMonth, hiddenItemCount > 0 {
                    Button {
                        selectedMonthDay = MonthDaySelection(day: day)
                    } label: {
                        HStack(spacing: 3) {
                            Text("+\(hiddenItemCount) más")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(LumaPalette.indigo)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Ver las \(displayedItems.count) actividades de este día")
                }
            }

            if isCompactMonth {
                Button {
                    newTaskMonthDay = MonthDaySelection(day: day)
                } label: {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Agregar una tarea el \(day.formatted(date: .long, time: .omitted))")
                .help("Agregar una tarea este día")
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(isCompactMonth ? 6 : 10)
        .frame(
            maxWidth: .infinity,
            minHeight: fixedHeight ?? 250,
            maxHeight: fixedHeight,
            alignment: .topLeading
        )
        .background(
            isToday ? LumaPalette.indigo.opacity(0.07) : Color.white.opacity(isCurrentMonth ? 0.38 : 0.16),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isToday ? LumaPalette.indigo.opacity(0.28) : LumaPalette.indigo.opacity(0.07),
                    lineWidth: isToday ? 1.25 : 1
                )
        }
        .opacity(isCurrentMonth ? 1 : 0.52)
        .clipped()
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { payloads, _ in
            prepareSchedule(payloads, on: day)
        }
    }

    private func dayCellHeader(_ day: Date, isToday: Bool) -> some View {
        HStack(alignment: .center, spacing: 5) {
            Text(day, format: .dateTime.day())
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(isToday ? Color.white : LumaPalette.ink)
                .frame(width: 28, height: 28)
                .background(isToday ? LumaPalette.indigo : Color.clear, in: Circle())

            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
    }

    private func defaultTaskDate(on day: Date) -> Date {
        calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day) ?? day
    }

    private func monthlyPrioritizedItems(_ items: [CalendarDayItem]) -> [CalendarDayItem] {
        // En el resumen mensual los exámenes nunca deben quedar escondidos detrás
        // de tareas ordinarias. El orden interno de cada grupo se mantiene estable.
        let exams = items.filter {
            if case .exam = $0 { return true }
            return false
        }
        let remaining = items.filter {
            if case .exam = $0 { return false }
            return true
        }
        return exams + remaining
    }

    @ViewBuilder
    private func calendarTaskChip(_ task: LumaTask, compact: Bool, day: Date) -> some View {
        if compact {
            compactCalendarTaskChip(task, day: day)
        } else {
            expandedCalendarTaskChip(task, day: day)
        }
    }

    private func compactCalendarTaskChip(_ task: LumaTask, day: Date) -> some View {
        let accent = taskCalendarAccent(task)

        return Button {
            viewModel.selectedTask = task
        } label: {
            HStack(spacing: 5) {
                if task.dueDate.map({ calendar.isDate($0, inSameDayAs: day) }) == true {
                    Text("Entrega").font(.caption2.weight(.semibold)).foregroundStyle(LumaPalette.terracotta)
                } else if let deadline = task.deadline {
                    Text(taskTimeLabel(deadline))
                        .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Text(task.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(task.isCompleted ? LumaPalette.secondaryInk : LumaPalette.ink)
                    .strikethrough(task.isCompleted, color: LumaPalette.secondaryInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : taskCalendarSymbol(task))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .padding(.leading, 11)
            .padding(.trailing, 7)
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            task.isCompleted ? LumaPalette.sage.opacity(0.09) : Color.white.opacity(0.52),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(accent.opacity(task.isCompleted ? 0.22 : 0.14), lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(accent)
                .frame(width: 3)
                .padding(.vertical, 5)
                .padding(.leading, 4)
        }
        .opacity(task.isCompleted ? 0.82 : 1)
        .help(task.title)
    }

    private func expandedCalendarTaskChip(_ task: LumaTask, day: Date) -> some View {
        let accent = taskCalendarAccent(task)

        return Button {
            viewModel.selectedTask = task
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if task.dueDate.map({ calendar.isDate($0, inSameDayAs: day) }) == true {
                    Text("Entrega").font(.caption2.weight(.semibold)).foregroundStyle(LumaPalette.terracotta)
                } else if let deadline = task.deadline {
                        Text(taskTimeLabel(deadline))
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(accent)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : taskCalendarSymbol(task))
                        .font(.caption2)
                        .foregroundStyle(accent)
                }

                Text(task.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(task.isCompleted ? LumaPalette.secondaryInk : LumaPalette.ink)
                    .strikethrough(task.isCompleted, color: LumaPalette.secondaryInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(task.isCompleted ? "Completada" : task.dueDate.map({ calendar.isDate($0, inSameDayAs: day) }) == true ? "Fecha límite" : "Bloque de \(appState.workBlocks(on: day, taskID: task.id).first?.minutes ?? min(45, task.remainingEstimatedMinutes)) min")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(task.isCompleted ? LumaPalette.sage : LumaPalette.secondaryInk)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            task.isCompleted ? LumaPalette.sage.opacity(0.09) : Color.white.opacity(0.52),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(accent.opacity(task.isCompleted ? 0.22 : 0.14), lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(accent)
                .frame(width: 3)
                .padding(.vertical, 8)
                .padding(.leading, 5)
        }
        .opacity(task.isCompleted ? 0.82 : 1)
        .help(task.title)
    }

    @ViewBuilder
    private func calendarExamChip(_ occurrence: CalendarExamOccurrence, compact: Bool) -> some View {
        Button {
            viewModel.selectedExam = occurrence.exam
        } label: {
            if compact {
                HStack(spacing: 5) {
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .fixedSize()

                    Text(occurrence.exam.title)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(LumaPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }
                .foregroundStyle(LumaPalette.terracotta)
                .padding(.leading, 11)
                .padding(.trailing, 7)
                .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
                .background(LumaPalette.terracotta.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(LumaPalette.terracotta.opacity(0.38), lineWidth: 1.1)
                }
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LumaPalette.terracotta)
                        .frame(width: 4)
                        .padding(.vertical, 5)
                        .padding(.leading, 4)
                }
                .shadow(color: LumaPalette.terracotta.opacity(0.08), radius: 3, y: 1)
                .help("Examen · \(occurrence.subject.name) · \(occurrence.exam.title)")
            } else {
                expandedCalendarExamChip(occurrence)
            }
        }
        .buttonStyle(.plain)
    }

    private func expandedCalendarExamChip(_ occurrence: CalendarExamOccurrence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "graduationcap.fill")
                    .font(.caption2)
                Text("EXAMEN")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                Spacer(minLength: 2)
            }
            .foregroundStyle(LumaPalette.terracotta)

            Text(occurrence.exam.title)
                .font(.caption.weight(.bold))
                .foregroundStyle(LumaPalette.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(occurrence.subject.name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(LumaPalette.secondaryInk)
                .lineLimit(1)
        }
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(LumaPalette.terracotta.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(LumaPalette.terracotta.opacity(0.38), lineWidth: 1.2)
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(LumaPalette.terracotta)
                .frame(width: 4)
                .padding(.vertical, 7)
                .padding(.leading, 4)
        }
        .shadow(color: LumaPalette.terracotta.opacity(0.10), radius: 5, y: 2)
        .help("Examen · \(occurrence.subject.name) · \(occurrence.exam.title)")
    }

    private func calendarClassChip(_ occurrence: CalendarClassOccurrence, compact: Bool) -> some View {
        let accent = subjectColor(for: occurrence.subject.colorHex)
        let meeting = occurrence.meeting

        return VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 5) {
                Image(systemName: "person.3.fill")
                    .font(.caption2)
                Text(classTimeLabel(meeting))
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                Spacer(minLength: 2)
            }
            .foregroundStyle(accent)

            Text(occurrence.subject.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LumaPalette.ink)
                .lineLimit(compact ? 1 : 2)
                .fixedSize(horizontal: false, vertical: true)

            if !compact {
                Text(meeting.location.isEmpty ? "Clase" : meeting.location)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .padding(.vertical, compact ? 7 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(accent.opacity(0.20), lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(accent)
                .frame(width: 3)
                .padding(.vertical, 8)
                .padding(.leading, 5)
        }
        .help(classHelpText(occurrence))
    }

    private func taskTimeLabel(_ deadline: Date) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: deadline)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        if hour == 23, minute == 59 { return "Sin hora" }
        return String(format: "%02d:%02d", hour, minute)
    }

    private func taskCalendarAccent(_ task: LumaTask) -> Color {
        if task.isCompleted { return LumaPalette.sage }
        if task.academicSourceType == .routine { return LumaPalette.lavender }
        return task.area.color
    }

    private func taskCalendarSymbol(_ task: LumaTask) -> String {
        task.academicSourceType == .routine ? "arrow.triangle.2.circlepath" : "circle.fill"
    }

    private func classTimeLabel(_ meeting: SubjectClassMeeting) -> String {
        "\(minuteLabel(meeting.startMinuteOfDay))–\(minuteLabel(meeting.endMinuteOfDay))"
    }

    private func minuteLabel(_ minuteOfDay: Int) -> String {
        let clamped = max(0, min(23 * 60 + 59, minuteOfDay))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    private func classHelpText(_ occurrence: CalendarClassOccurrence) -> String {
        var parts = [occurrence.subject.name, classTimeLabel(occurrence.meeting)]
        if !occurrence.meeting.location.isEmpty { parts.append(occurrence.meeting.location) }
        return parts.joined(separator: " · ")
    }

    private func subjectColor(for hex: String) -> Color {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let number = Int(value, radix: 16) else { return LumaPalette.indigo }
        return Color(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }

    private var tasksWithoutDate: some View {
        let undated = viewModel.tasksWithoutDate(from: tasks)

        return VStack(alignment: .leading, spacing: 13) {
            SectionTitle(
                eyebrow: "Arrastrá al calendario",
                title: "Pendientes sin fecha",
                trailing: undated.count == 1 ? "1 tarea" : "\(undated.count) tareas"
            )

            if undated.isEmpty {
                Label("Todas las tareas pendientes ya tienen fecha.", systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                    .foregroundStyle(LumaPalette.sage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lumaCard(padding: 16)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 230, maximum: 310), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(undated) { task in
                        undatedTaskCard(task)
                            .draggable(task.id.uuidString) {
                                dragPreview(task)
                            }
                    }
                }
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.24), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.58), lineWidth: 1)
        }
    }

    private func undatedTaskCard(_ task: LumaTask) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                AreaPill(area: task.area)
                Spacer(minLength: 6)
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
            Text(task.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LumaPalette.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Label("\(task.estimatedMinutes) min", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(LumaPalette.secondaryInk)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .lumaCard(padding: 13)
        .help("Arrastrá esta tarea hacia un día del calendario")
    }

    private func dragPreview(_ task: LumaTask) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(task.area.color)
                .frame(width: 8, height: 8)
            Text(task.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(LumaPalette.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }

    private var timePickerSheet: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "calendar.badge.clock")
                    .font(.title2)
                    .foregroundStyle(LumaPalette.indigo)
                    .frame(width: 46, height: 46)
                    .background(LumaPalette.indigo.opacity(0.09), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("Elegí la hora")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(LumaPalette.ink)
                    if let task = viewModel.pendingTask(from: tasks) {
                        Text(task.title)
                            .font(.subheadline)
                            .foregroundStyle(LumaPalette.secondaryInk)
                            .lineLimit(2)
                    }
                }
            }

            if let day = viewModel.pendingDay {
                VStack(alignment: .leading, spacing: 14) {
                    Label(
                        day.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                        systemImage: "calendar"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)

                    HStack {
                        Text("Hora de la tarea")
                            .font(.subheadline)
                            .foregroundStyle(LumaPalette.secondaryInk)
                        Spacer()
                        DatePicker(
                            "Hora de la tarea",
                            selection: Binding(
                                get: { viewModel.pendingTime },
                                set: { viewModel.pendingTime = $0 }
                            ),
                            displayedComponents: [.hourAndMinute]
                        )
                        .labelsHidden()
                    }

                    HStack(spacing: 8) {
                        ForEach([9, 12, 17, 20], id: \.self) { hour in
                            Button(String(format: "%02d:00", hour)) {
                                viewModel.setPendingHour(hour, calendar: calendar)
                            }
                            .buttonStyle(.bordered)
                            .tint(isSelectedHour(hour) ? LumaPalette.indigo : LumaPalette.secondaryInk)
                        }
                    }
                }
                .padding(16)
                .background(Color.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 16))
            }

            HStack {
                Button("Cancelar") {
                    viewModel.cancelScheduling()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Asignar al calendario") {
                    confirmSchedule()
                }
                .buttonStyle(.borderedProminent)
                .tint(LumaPalette.indigo)
            }
        }
        .padding(26)
        .frame(width: 440)
    }

    private func isSelectedHour(_ hour: Int) -> Bool {
        calendar.component(.hour, from: viewModel.pendingTime) == hour
            && calendar.component(.minute, from: viewModel.pendingTime) == 0
    }

    private func openEditor(for task: LumaTask) {
        viewModel.selectedTask = nil
        Task { @MainActor in
            viewModel.editingTask = task
        }
    }

    private func toggleCompletion(_ task: LumaTask) {
        let wasCompleted = task.isCompleted
        withAnimation {
            wasCompleted ? task.restore() : task.markCompleted()
        }
        try? modelContext.save()
        try? calendarService.syncTask(task)
        appState.refreshPlan()
        if task.isCompleted { viewModel.selectedTask = nil }
        appState.registerUndo(message: wasCompleted ? "La tarea volvió a pendientes" : "Tarea completada") {
            wasCompleted ? task.markCompleted() : task.restore()
            try? modelContext.save()
            try? calendarService.syncTask(task)
            appState.refreshPlan()
        }
    }

    private func prepareSchedule(_ payloads: [String], on day: Date) -> Bool {
        guard let rawID = payloads.first,
              let taskID = UUID(uuidString: rawID),
              tasks.contains(where: { $0.id == taskID && !$0.isCompleted })
        else { return false }

        viewModel.beginScheduling(taskID: taskID, on: day, calendar: calendar)
        return true
    }

    private func confirmSchedule() {
        guard let task = viewModel.pendingTask(from: tasks) else {
            viewModel.cancelScheduling()
            return
        }

        let previousDeadline = task.deadline
        guard viewModel.assignPendingTask(from: tasks, calendar: calendar) != nil else { return }

        do {
            try modelContext.save()
        } catch {
            task.deadline = previousDeadline
            task.touch()
            viewModel.scheduleFeedback = "No pude asignar la fecha. Probá de nuevo."
            return
        }

        try? calendarService.syncTask(task)
        appState.refreshPlan()
        appState.registerUndo(message: "Fecha asignada") {
            task.deadline = previousDeadline
            task.touch()
            try? modelContext.save()
            try? calendarService.syncTask(task)
            appState.refreshPlan()
        }
    }
}

private struct WeekTimelineEntry: Identifiable {
    enum Content {
        case task(LumaTask)
        case taskGroup([LumaTask])
        case classMeeting(CalendarClassOccurrence)
    }

    let id: String
    let startMinute: Int
    let endMinute: Int
    let content: Content

    var isTask: Bool {
        switch content {
        case .task, .taskGroup:
            return true
        case .classMeeting:
            return false
        }
    }

    var tasks: [LumaTask] {
        switch content {
        case let .task(task):
            return [task]
        case let .taskGroup(tasks):
            return tasks
        case .classMeeting:
            return []
        }
    }
}

private struct PositionedWeekTimelineEntry: Identifiable {
    let entry: WeekTimelineEntry
    let lane: Int
    let laneCount: Int

    var id: String { entry.id }
}

private struct TimelineTaskGroupSelection: Identifiable {
    let id = UUID()
    let tasks: [LumaTask]
}
