import Foundation
import CoreGraphics
import AppKit

enum MovementCommand {
    case walk(direction: CGFloat)
    case jump(to: Surface)
    case fall
    case follow(WindowInfo)
    case stop
}

class MovementController {
    var currentPosition: CGPoint = .zero
    var currentSurface: Surface?
    var isOnSurface: Bool = true
    var direction: CGFloat = 0  // -1 left, 1 right
    
    var onPositionChanged: ((CGPoint) -> Void)?
    
    private var timer: Timer?
    private var lastUpdate: Date = Date()
    private let speed: CGFloat = 40.0 // px/sec
    private var velocity: CGPoint = .zero
    private let gravity: CGFloat = 400.0 // px/sec^2
    
    private var targetSurface: Surface?
    private var targetPosition: CGPoint?
    
    init(surfaces: SurfaceGraph, topology: DesktopTopology) {
        // Find initial surface to land on
        let screen = NSScreen.main?.visibleFrame ?? .zero
        self.currentPosition = CGPoint(x: screen.midX, y: screen.midY)
    }
    
    func start() {
        stop()
        lastUpdate = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    func execute(_ command: MovementCommand) {
        switch command {
        case .walk(let dir):
            self.direction = dir
            self.velocity.x = dir * speed
            self.targetPosition = nil
            
        case .jump(let surface):
            self.targetSurface = surface
            self.isOnSurface = false
            // Calculate initial velocity for jump
            let dx = surface.rect.midX - currentPosition.x
            let dy = surface.rect.origin.y - currentPosition.y
            self.velocity = CGPoint(x: dx / 1.0, y: dy / 1.0 + 0.5 * gravity * 1.0) // 1 second jump
            
        case .fall:
            self.isOnSurface = false
            self.velocity = .zero
            
        case .follow(let window):
            // Walk toward the window's top edge
            self.targetPosition = CGPoint(x: window.bounds.midX, y: window.bounds.maxY)
            self.direction = (targetPosition!.x > currentPosition.x) ? 1 : -1
            self.velocity.x = direction * speed
            
        case .stop:
            self.velocity = .zero
            self.direction = 0
            self.targetPosition = nil
        }
    }
    
    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastUpdate)
        lastUpdate = now
        
        if !isOnSurface {
            // Apply gravity
            velocity.y -= gravity * CGFloat(dt)
            currentPosition.x += velocity.x * CGFloat(dt)
            currentPosition.y += velocity.y * CGFloat(dt)
            
            // Check for landing
            // (Simulate landing on screen bottom if nothing else)
            let screenBottom = NSScreen.main?.visibleFrame.minY ?? 0
            if currentPosition.y <= screenBottom {
                currentPosition.y = screenBottom
                isOnSurface = true
                velocity = .zero
            }
        } else {
            // Horizontal movement on surface
            currentPosition.x += velocity.x * CGFloat(dt)
            
            // Keep on current surface bounds
            if let surface = currentSurface {
                if currentPosition.x < surface.rect.origin.x {
                    currentPosition.x = surface.rect.origin.x
                    velocity.x = 0
                } else if currentPosition.x > surface.rect.maxX {
                    currentPosition.x = surface.rect.maxX
                    velocity.x = 0
                }
            }
            
            // Check for reaching target
            if let target = targetPosition {
                let dx = target.x - currentPosition.x
                if abs(dx) < 5 {
                    velocity.x = 0
                    direction = 0
                    targetPosition = nil
                }
            }
        }
        
        onPositionChanged?(currentPosition)
    }
}
