import SwiftUI

@main
struct PRTrackerApp: App {
    private static let settingsWindowID = "settings"
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
    }
}

