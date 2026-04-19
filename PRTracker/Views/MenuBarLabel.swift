import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "arrow.triangle.pull")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
                .symbolEffect(.bounce, value: model.awaitingCount)

            if model.awaitingCount > 0 {
                Text("\(model.awaitingCount)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.gradient))
                    .offset(x: 8, y: -6)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .accessibilityLabel("Pending reviews: \(model.awaitingCount)")
        .animation(.snappy(duration: 0.18), value: model.awaitingCount)
        .overlay {
            GeometryReader { proxy in
                StatusBarContextMenuOverlay(
                    onOpenSettings: {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "settings")
                    },
                    onExit: { NSApp.terminate(nil) }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .onAppear {
            model.startIfNeeded()
        }
    }

    private var iconColor: Color {
        switch model.menuBarIconState {
        case .idle:
            return .secondary
        case .hasAwaiting:
            return .blue
        case .hasStaleOrUpdated:
            return .orange
        case .error:
            return .red
        }
    }
}

private struct StatusBarContextMenuOverlay: NSViewRepresentable {
    let onOpenSettings: () -> Void
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenSettings: onOpenSettings, onExit: onExit)
    }

    func makeNSView(context: Context) -> StatusBarRightClickView {
        let view = StatusBarRightClickView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: StatusBarRightClickView, context: Context) {
        context.coordinator.onOpenSettings = onOpenSettings
        context.coordinator.onExit = onExit
        nsView.coordinator = context.coordinator
    }

    final class Coordinator: NSObject {
        var onOpenSettings: () -> Void
        var onExit: () -> Void

        lazy var menu: NSMenu = {
            let menu = NSMenu()

            let settingsItem = NSMenuItem(
                title: "Settings",
                action: #selector(openSettings),
                keyEquivalent: ""
            )
            settingsItem.target = self
            menu.addItem(settingsItem)

            let exitItem = NSMenuItem(
                title: "Exit",
                action: #selector(exitApplication),
                keyEquivalent: "q"
            )
            exitItem.target = self
            exitItem.keyEquivalentModifierMask = [.command]
            menu.addItem(exitItem)

            return menu
        }()

        init(onOpenSettings: @escaping () -> Void, onExit: @escaping () -> Void) {
            self.onOpenSettings = onOpenSettings
            self.onExit = onExit
        }

        @objc private func openSettings() {
            onOpenSettings()
        }

        @objc private func exitApplication() {
            onExit()
        }
    }
}

private final class StatusBarRightClickView: NSView {
    weak var coordinator: StatusBarContextMenuOverlay.Coordinator?

    private var eventMonitor: Any?

    deinit {
        removeEventMonitor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installEventMonitorIfNeeded()
        } else {
            removeEventMonitor()
        }
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown, .leftMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return handleRightClick(event)
        }
    }

    private func removeEventMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private func handleRightClick(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window == window else { return event }
        guard shouldPresentContextMenu(for: event) else { return event }

        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), let coordinator else {
            return event
        }

        NSMenu.popUpContextMenu(coordinator.menu, with: event, for: self)
        return nil
    }

    private func shouldPresentContextMenu(for event: NSEvent) -> Bool {
        switch event.type {
        case .rightMouseDown:
            return true
        case .leftMouseDown:
            return event.modifierFlags.contains(.control)
        default:
            return false
        }
    }
}

