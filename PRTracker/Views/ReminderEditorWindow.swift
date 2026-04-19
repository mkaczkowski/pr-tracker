import SwiftUI

@MainActor
struct ReminderEditorWindow: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let draft = model.reminderEditorDraft {
                editorBody(draft: draft)
            } else {
                EmptyStateView(
                    title: "No reminder selected",
                    subtitle: "Choose Custom from a PR row to set a reminder."
                )
                .padding()
            }
        }
        .frame(width: 360)
        .onChange(of: model.reminderEditorDraft?.id) { _, newID in
            if newID == nil {
                dismiss()
            }
        }
    }

    private func editorBody(draft: ReminderEditorDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set reminder")
                .font(.headline)
            Text("\(draft.pullRequest.repository) #\(draft.pullRequest.number)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            DatePicker(
                "Reminder time",
                selection: selectedDateBinding,
                in: draft.minimumDate...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .labelsHidden()

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelReminderEditor()
                    dismiss()
                }
                Button("Set reminder") {
                    model.confirmReminderEditor()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private var selectedDateBinding: Binding<Date> {
        Binding(
            get: { model.reminderEditorDraft?.scheduledAt ?? Date() },
            set: { model.updateReminderEditorDate($0) }
        )
    }
}
