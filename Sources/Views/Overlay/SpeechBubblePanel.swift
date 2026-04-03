import SwiftUI
import AppKit

private let speechBubbleMaxWidth: CGFloat = 260
private let speechBubbleHorizontalPadding: CGFloat = 16

private struct SpeechBubbleView: View {
    let event: SpeechEvent
    let onCommentTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.text)
                .font(
                    event.tier == .emote
                        ? .system(size: 24)
                        : (event.tier == .mutter ? Constants.body(size: 13).italic() : Constants.body(size: 13))
                )
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: speechBubbleMaxWidth - speechBubbleHorizontalPadding, alignment: .leading)
                .foregroundColor(Constants.textPrimary)
                .padding(event.tier == .emote ? 4 : 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(event.tier == .mutter ? Color(red: 1.0, green: 0.97, blue: 0.88) : Color.white)
                        .shadow(color: Color.black.opacity(event.tier == .comment ? 0.16 : 0.1), radius: event.tier == .comment ? 8 : 4, x: 0, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Constants.border, lineWidth: event.tier == .comment ? 1 : 0)
                )
        }
        .padding(4)
        .contentShape(Rectangle())
        .onTapGesture {
            if event.tier == .comment {
                onCommentTap()
            }
        }
    }
}

class SpeechBubblePanel: OverlayPanel {
    private var autoDismissTask: DispatchWorkItem?
    private var dismissHandler: ((Bool) -> Void)?
    private var currentToken = UUID()
    private var hostingController: TransparentHostingController<SpeechBubbleView>?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100))
        level = .screenSaver
        isMovableByWindowBackground = false
    }

    func show(
        event: SpeechEvent,
        above point: CGPoint,
        onDismiss: ((Bool) -> Void)? = nil
    ) {
        dismiss(false)
        dismissHandler = onDismiss

        let token = UUID()
        currentToken = token

        let view = SpeechBubbleView(event: event) { [weak self] in
            guard let self, self.currentToken == token else { return }
            self.dismiss(true)
        }
        let controller = TransparentHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: speechBubbleMaxWidth, height: 120)
        contentView = controller.view
        contentViewController = controller
        hostingController = controller

        controller.view.layoutSubtreeIfNeeded()
        let fittingSize = controller.view.fittingSize
        let desiredRect = NSRect(
            x: point.x - fittingSize.width / 2,
            y: point.y + 10,
            width: fittingSize.width,
            height: fittingSize.height
        )
        setFrame(clamped(rect: desiredRect), display: true)
        orderFrontRegardless()

        let duration: TimeInterval = {
            switch event.tier {
            case .emote:
                return 2
            case .mutter:
                return 3
            case .comment:
                return 4
            }
        }()

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.currentToken == token else { return }
            self.dismiss(false)
        }
        autoDismissTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    func dismiss(_ userInitiated: Bool) {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        orderOut(nil)
        contentViewController = nil
        hostingController = nil
        dismissHandler?(userInitiated)
        dismissHandler = nil
    }

    private func clamped(rect: NSRect) -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let minX = screen.minX
        let maxX = max(screen.minX, screen.maxX - rect.width)
        let minY = screen.minY
        let maxY = max(screen.minY, screen.maxY - rect.height)

        let clampedX = min(max(rect.origin.x, minX), maxX)
        let clampedY = min(max(rect.origin.y, minY), maxY)
        return NSRect(x: clampedX, y: clampedY, width: rect.width, height: rect.height)
    }
}
