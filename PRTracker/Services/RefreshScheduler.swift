import Foundation

@MainActor
final class RefreshScheduler {
    private var loopTask: Task<Void, Never>?
    private var action: (() async -> Bool)?
    private var baseIntervalSeconds: Double = AppSettings.defaultRefreshIntervalSeconds
    private let minimumIntervalSeconds: Double
    private let maximumBackoffSeconds: Double

    init(
        minimumIntervalSeconds: Double = 60,
        maximumBackoffSeconds: Double = 1_800
    ) {
        self.minimumIntervalSeconds = minimumIntervalSeconds
        self.maximumBackoffSeconds = maximumBackoffSeconds
    }

    func start(
        intervalSeconds: Double,
        action: @escaping () async -> Bool
    ) {
        stop()
        self.baseIntervalSeconds = max(minimumIntervalSeconds, intervalSeconds)
        self.action = action

        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func runLoop() async {
        var failures = 0

        while Task.isCancelled == false {
            let didSucceed = await action?() ?? true

            if didSucceed {
                failures = 0
            } else {
                failures = min(failures + 1, 5)
            }

            let delay = delayForNextTick(failures: failures)
            let nanoseconds = UInt64(delay * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
        }
    }

    private func delayForNextTick(failures: Int) -> Double {
        guard failures > 0 else {
            return baseIntervalSeconds
        }
        let multiplier = pow(2.0, Double(failures))
        return min(baseIntervalSeconds * multiplier, maximumBackoffSeconds)
    }
}

