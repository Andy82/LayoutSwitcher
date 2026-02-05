import Cocoa

/// Overlay window that displays the current keyboard layout, always on top and ignores mouse events.
final class KeyboardLayoutOverlayWindow: NSWindow {
    init(screen: NSScreen, initialOrigin: NSPoint) {
        let overlaySize = NSSize(width: 120, height: 60)
        let contentRect = NSRect(origin: .zero, size: overlaySize)
        super.init(contentRect: contentRect,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = false
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.setFrameOrigin(initialOrigin)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class KeyboardLayoutOverlayController: NSWindowController {
    private let overlayView = KeyboardLayoutOverlayView()
    private var initialDragLocation: NSPoint?
    
    let screenID: String
    var onPositionChanged: ((NSPoint) -> Void)?

    init(screen: NSScreen, initialOrigin: NSPoint) {
        self.screenID = screen.localizedName
        let window = KeyboardLayoutOverlayWindow(screen: screen, initialOrigin: initialOrigin)
        window.contentView = overlayView
        super.init(window: window)
        setupDrag()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Observe changes in keyboard layout
    func updateKeyboardLayout(_ layoutName: String) {
        overlayView.layoutName = layoutName
    }
    
    private func setupDrag() {
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        overlayView.addGestureRecognizer(pan)
    }
    @objc private func handleDrag(_ gesture: NSPanGestureRecognizer) {
        guard let window = self.window else { return }
        if NSEvent.modifierFlags.contains(.option) {
            let location = gesture.location(in: nil)
            switch gesture.state {
            case .began:
                initialDragLocation = location
            case .changed:
                if let initial = initialDragLocation {
                    let dx = location.x - initial.x
                    let dy = location.y - initial.y
                    var frame = window.frame
                    frame.origin.x += dx
                    frame.origin.y += dy
                    window.setFrameOrigin(frame.origin)
                    onPositionChanged?(window.frame.origin)
                }
            default:
                break
            }
        }
    }
}

final class KeyboardLayoutOverlayView: NSView {
    var layoutName: String = "---" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    
    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = min(bounds.width, bounds.height) * 0.22
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor(calibratedWhite: 0.1, alpha: 0.60).setFill()
        path.fill()
        
        let textColor: NSColor = .white
        
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: textColor,
            .font: NSFont.monospacedSystemFont(ofSize: 48, weight: .medium)
        ]
        
        let string = layoutName
        let size = string.size(withAttributes: attrs)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        string.draw(at: point, withAttributes: attrs)
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Allow click events only if Option key is pressed, so overlay is transparent for normal clicks
        if NSEvent.modifierFlags.contains(.option) {
            return super.hitTest(point)
        }
        return nil
    }
}
