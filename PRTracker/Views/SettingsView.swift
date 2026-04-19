import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    @AppStorage(AppSettings.Keys.host) private var host = AppSettings.defaultHost
    @AppStorage(AppSettings.Keys.org) private var org = ""
    @AppStorage(AppSettings.Keys.requiredApprovals) private var requiredApprovals = AppSettings.defaultRequiredApprovals
    @AppStorage(AppSettings.Keys.refreshIntervalSeconds) private var refreshIntervalSeconds = AppSettings.defaultRefreshIntervalSeconds
    @AppStorage(AppSettings.Keys.notificationsEnabled) private var notificationsEnabled = AppSettings.defaultNotificationsEnabled
    @AppStorage(AppSettings.Keys.launchAtLoginEnabled) private var launchAtLoginEnabled = AppSettings.defaultLaunchAtLoginEnabled

    var body: some View {
        Form {
            Section("GitHub") {
                TextField("Host", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { settingsDidChange() }
                TextField("Org (optional)", text: $org)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { settingsDidChange() }

                HStack {
                    Button("Copy login command") {
                        copy(model.authLoginCommand(hostOverride: host))
                    }
                    .buttonStyle(.bordered)
                    Button("Refresh now") {
                        settingsDidChange()
                        model.manualRefresh()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section("Review rules") {
                Stepper("Required approvals: \(requiredApprovals)", value: $requiredApprovals, in: 1 ... 10)
                    .onChange(of: requiredApprovals) { _, _ in settingsDidChange() }

                Stepper(
                    "Refresh interval: \(Int(refreshIntervalSeconds / 60)) min",
                    value: $refreshIntervalSeconds,
                    in: 60 ... 3600,
                    step: 60
                )
                .onChange(of: refreshIntervalSeconds) { _, _ in settingsDidChange() }
            }

            Section("System") {
                Toggle("Enable notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, _ in settingsDidChange() }
                Toggle("Launch at login", isOn: $launchAtLoginEnabled)
                    .onChange(of: launchAtLoginEnabled) { _, _ in settingsDidChange() }
            }

            Section("Diagnostics") {
                Button("Copy log command") {
                    copy("log stream --style compact --predicate 'subsystem == \"PRTracker\"'")
                }
                if let remaining = model.rateLimitRemaining {
                    Text("Rate limit remaining: \(remaining)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .controlSize(.small)
        .padding()
        .frame(width: 520)
        .onAppear {
            model.refreshFromStoredSettings()
        }
        .onDisappear {
            settingsDidChange()
        }
    }

    private func settingsDidChange() {
        model.refreshFromStoredSettings()
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

