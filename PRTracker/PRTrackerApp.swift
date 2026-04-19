import SwiftUI

@main
@MainActor
struct PRTrackerApp: App {
    private static let settingsWindowID = "settings"
    private static let reminderWindowID = "reminder-editor"
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: Self.settingsWindowID) {
            SettingsView(model: model)
        }
        .defaultSize(width: 520, height: 360)

        Window("Set Reminder", id: Self.reminderWindowID) {
            ReminderEditorWindow(model: model)
        }
        .defaultSize(width: 360, height: 200)
        .windowResizability(.contentSize)
    }
}

