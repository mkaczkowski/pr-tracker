import AppKit
import Foundation
import Network

protocol ReachabilityServing {
    func start(onUpdate: @escaping @MainActor (Bool) -> Void)
    func stop()
}

final class Reachability: ReachabilityServing {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "PRTracker.Reachability")

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
    }

    func start(onUpdate: @escaping @MainActor (Bool) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { @MainActor in
                onUpdate(path.status == .satisfied)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}

protocol SleepWakeObserving {
    func start(onWillSleep: @escaping () -> Void, onDidWake: @escaping () -> Void)
    func stop()
}

final class SleepWakeObserver: SleepWakeObserving {
    private var onWillSleep: (() -> Void)?
    private var onDidWake: (() -> Void)?
    private var tokens: [NSObjectProtocol] = []

    func start(
        onWillSleep: @escaping () -> Void,
        onDidWake: @escaping () -> Void
    ) {
        self.onWillSleep = onWillSleep
        self.onDidWake = onDidWake

        let center = NSWorkspace.shared.notificationCenter
        let willSleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onWillSleep?()
        }

        let didWake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onDidWake?()
        }

        tokens = [willSleep, didWake]
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll()
    }
}

