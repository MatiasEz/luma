import SwiftUI

struct TaskDependencyPicker: View {
    let sourceTaskID: UUID?
    let tasks: [LumaTask]
    @Binding var selectedTaskID: UUID?

    private var availableTasks: [LumaTask] {
        TaskDependencyResolver.availableTargets(
            for: sourceTaskID,
            selectedTaskID: selectedTaskID,
            in: tasks
        )
    }

    private var selectedTask: LumaTask? {
        selectedTaskID.flatMap { id in tasks.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Dependencia")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LumaPalette.secondaryInk)

            Picker("Al completar, desbloquear", selection: $selectedTaskID) {
                Text("Ninguna tarea").tag(UUID?.none)
                ForEach(availableTasks) { task in
                    Text(task.title).tag(Optional(task.id))
                }
            }
            .pickerStyle(.menu)

            if let selectedTask {
                Label(
                    "“\(selectedTask.title)” no entrará en el plan hasta completar esta tarea.",
                    systemImage: "lock.open.fill"
                )
                .font(.caption)
                .foregroundStyle(LumaPalette.sage)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Elegí una tarea solo si realmente depende de terminar esta primero.")
                    .font(.caption)
                    .foregroundStyle(LumaPalette.secondaryInk)
            }
        }
        .padding(14)
        .background(LumaPalette.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}
