import AppKit

@MainActor
final class FloatingIsland {
    private let panel: NSPanel
    private let view = IslandView()
    private var timer: Timer?
    var click: (() -> Void)? { get { view.click } set { view.click = newValue } }
    init() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let defaults = UserDefaults.standard
        let saved = NSPoint(x: defaults.double(forKey: "islandX"), y: defaults.double(forKey: "islandY"))
        let position = NSScreen.screens.contains { $0.visibleFrame.contains(saved) } && defaults.object(forKey: "islandX") != nil
            ? saved : NSPoint(x: screen.maxX - 80, y: screen.minY + 24)
        panel = NSPanel(contentRect: NSRect(origin: position, size: NSSize(width: 56, height: 56)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.contentView = view
        panel.orderFrontRegardless()
    }
    func update(phase: Phase, since: Date?, message: String?, asking: Bool) {
        view.phase = phase; view.since = since; view.message = message; view.asking = asking
        let width: CGFloat = phase == .idle && message == nil ? 56 : min(420, max(200, CGFloat((message ?? "").count) * 14 + 80))
        var frame = panel.frame
        frame.origin.x += frame.width - width; frame.size.width = width
        if let screen = panel.screen { frame.origin.x = max(screen.visibleFrame.minX, min(frame.origin.x, screen.visibleFrame.maxX - width)) }
        panel.setFrame(frame, display: true)
        view.needsDisplay = true
        if phase == .recording || asking {
            if timer == nil {
                timer = .scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.view.needsDisplay = true }
                }
            }
        } else { timer?.invalidate(); timer = nil }
    }
}

@MainActor
private final class IslandView: NSView {
    var phase: Phase = .idle
    var since: Date?
    var message: String?
    var asking = false
    var click: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let orange = NSColor(srgbRed: 0.918, green: 0.333, blue: 0.016, alpha: 1)
        NSColor(white: 0.04, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 28, yRadius: 28).fill()
        let center = NSPoint(x: bounds.maxX - 28, y: 28)
        let t = Date().timeIntervalSince(since ?? Date())
        let arc = NSBezierPath()
        let rotating = phase == .recording
        arc.appendArc(withCenter: center, radius: 26.5, startAngle: rotating ? CGFloat(t * 130) : 0,
                      endAngle: rotating ? CGFloat(t * 130 + 75) : 360)
        arc.lineWidth = rotating ? 2 : 3
        orange.withAlphaComponent(rotating || asking ? 1 : 0.35).setStroke(); arc.stroke()
        for i in 0..<3 {
            let height: CGFloat = rotating ? CGFloat(10 + 12 * (0.5 + 0.5 * sin(t * 7 + Double(i) * 1.6))) : [14,20,10][i]
            (i == 1 ? orange : NSColor.white).setFill()
            NSBezierPath(roundedRect: NSRect(x: center.x - 9 + CGFloat(i * 7), y: 18, width: 4, height: height),
                         xRadius: 2, yRadius: 2).fill()
        }
        if bounds.width > 56 {
            let text = message ?? (phase == .recording ? String(format: "● 收音中 %.1f", max(0,t)) : "辨識中…")
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            (text as NSString).draw(in: NSRect(x: 18, y: 17, width: bounds.width - 84, height: 24),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white, .paragraphStyle: style])
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startMouse = NSEvent.mouseLocation, startFrame = window.frame
        var dragged = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = NSEvent.mouseLocation
            if hypot(point.x - startMouse.x, point.y - startMouse.y) > 4 { dragged = true }
            if dragged { window.setFrameOrigin(NSPoint(x: startFrame.minX + point.x - startMouse.x, y: startFrame.minY + point.y - startMouse.y)) }
        }
        if dragged {
            UserDefaults.standard.set(window.frame.maxX - 56, forKey: "islandX")
            UserDefaults.standard.set(window.frame.minY, forKey: "islandY")
        } else { click?() }
    }
}
