import Foundation

class BehaviorScheduler {
    private var task: Task<Void, Never>?
    var onTick: (() -> Void)?
    
    func start() {
        stop()
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = Double.random(in: Constants.behaviorTickRange)
                let duration = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: duration)
                if Task.isCancelled { break }
                self.onTick?()
            }
        }
    }
    
    func stop() {
        task?.cancel()
        task = nil
    }
}
