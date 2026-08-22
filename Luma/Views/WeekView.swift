import SwiftData
import SwiftUI

struct WeekView: View {
    @Query(sort: \LumaTask.deadline) private var tasks: [LumaTask]
    @State private var viewModel = WeekViewModel()

    private let calendar = Calendar.current

    private var days: [Date] {
        viewModel.days(calendar: calendar)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionTitle(
                    eyebrow: "Panorama",
                    title: "Tu semana sin ruido",
                    trailing: "Próximos 7 días"
                )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(days, id: \.self) { day in
                            dayColumn(day)
                                .frame(width: 138)
                        }
                    }
                    .padding(.vertical, 2)
                }

                tasksWithoutDate
            }
            .padding(30)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .navigationTitle("Semana")
    }

    private func dayColumn(_ day: Date) -> some View {
        let dayTasks = viewModel.tasks(on: day, from: tasks, calendar: calendar)

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(day, format: .dateTime.weekday(.abbreviated))
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(calendar.isDateInToday(day) ? LumaPalette.indigo : LumaPalette.secondaryInk)
                Text(day, format: .dateTime.day())
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(LumaPalette.ink)
            }

            if dayTasks.isEmpty {
                Text("Libre")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.sage)
                    .padding(.vertical, 8)
            } else {
                ForEach(dayTasks.prefix(3)) { task in
                    VStack(alignment: .leading, spacing: 5) {
                        Circle().fill(task.area.color).frame(width: 7, height: 7)
                        Text(task.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LumaPalette.ink)
                            .lineLimit(3)
                        Text("\(task.estimatedMinutes) min")
                            .font(.caption2)
                            .foregroundStyle(LumaPalette.secondaryInk)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(task.area.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        .lumaCard(padding: 12)
    }

    private var tasksWithoutDate: some View {
        let undated = viewModel.tasksWithoutDate(from: tasks)

        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle(
                eyebrow: "Sin fecha",
                title: "Pendientes flexibles",
                trailing: "\(undated.count) tareas"
            )
            if undated.isEmpty {
                Text("No hay tareas flotando sin fecha.")
                    .foregroundStyle(LumaPalette.secondaryInk)
                    .lumaCard()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                    ForEach(undated.prefix(4)) { task in
                        VStack(alignment: .leading, spacing: 8) {
                            AreaPill(area: task.area)
                            Text(task.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(LumaPalette.ink)
                        }
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                        .lumaCard(padding: 13)
                    }
                }
            }
        }
    }
}
