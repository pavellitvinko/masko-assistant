import Foundation

class BehaviorScheduler {
    private var timer: Timer?
    var onTick: (() -> Void)?
    
    func start() {
        stop()
        scheduleNext()
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    private func scheduleNext() {
        let interval = Double.random(in: Constants.behaviorTickRange)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.onTick?()
            self?.scheduleNext()
        }
    }
}
