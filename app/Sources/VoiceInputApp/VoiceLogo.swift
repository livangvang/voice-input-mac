import AppKit

/// The app mark follows the floating island: three bars on one baseline, inside a circle.
/// Artwork uses a fixed 512-point grid and renders directly at each requested pixel size.
@MainActor
enum VoiceLogo {
    enum Style: String, CaseIterable { case brand, recording, transcribing, unknown, offline }
    static let orange = NSColor(srgbRed: 234 / 255, green: 85 / 255, blue: 4 / 255, alpha: 1)
    static let background = NSColor(white: 0.04, alpha: 1)

    static func image(pixels: Int = 512, style: Style = .brand) -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 512)
        transform.concat()
        draw(style: style)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }

    private static func draw(style: Style) {
        background.setFill()
        NSBezierPath(ovalIn: NSRect(x: 40, y: 40, width: 432, height: 432)).fill()
        let muted = style == .transcribing || style == .unknown || style == .offline
        let accent = muted ? NSColor(white: style == .offline ? 0.42 : 0.65, alpha: 1) : orange
        let side = muted ? accent : (style == .recording ? orange : NSColor.white)
        let ring = NSBezierPath(ovalIn: NSRect(x: 56, y: 56, width: 400, height: 400))
        ring.lineWidth = 12
        accent.setStroke()
        ring.stroke()
        for (index, height) in [112.0, 160.0, 80.0].enumerated() {
            (index == 1 ? accent : side).setFill()
            NSBezierPath(roundedRect: NSRect(x: 184 + Double(index) * 56, y: 176,
                                           width: 32, height: height), xRadius: 16, yRadius: 16).fill()
        }
        if style == .offline {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 124, y: 124))
            slash.line(to: NSPoint(x: 388, y: 388))
            slash.lineCapStyle = .round
            slash.lineWidth = 30
            background.setStroke()
            slash.stroke()
            slash.lineWidth = 14
            NSColor(srgbRed: 0.973, green: 0.443, blue: 0.443, alpha: 1).setStroke()
            slash.stroke()
        }
    }
}
