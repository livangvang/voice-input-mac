import AppKit

/// Dock 圖示。執行時畫，不夾帶圖檔——五根音柱用程式畫比維護一組 @1x/@2x 檔案省事。
///
/// 圖示本身就是狀態顯示，這是「要在 Dock 裡看到」的重點：不用點開、不用切過去，
/// 掃一眼就知道現在能不能用。
///
/// 配色規則跟選單列一致：橘色**只**代表「正在收音」。連不上、熱鍵壞掉一律用灰階
/// 加斜線——橘色代表「活著」，就不能同時代表「壞了」，不然一眼分不出是哪一種。
@MainActor
enum AppIcon {
    private static var lastKey = ""

    static func apply(_ s: AppStatus) {
        let key = "\(s.phase.rawValue)|\(s.hotkeyState)|\(s.serverReachable ?? false)"
        // 每 0.5 秒重畫一次圖示是白費工，狀態沒變就跳過。
        // 秒數走 badge，那個本來就要每次更新。
        if key != lastKey {
            lastKey = key
            NSApp.applicationIconImage = render(s)
        }

        if let elapsed = s.elapsed {
            NSApp.dockTile.badgeLabel = String(format: "%.0fs", elapsed)
        } else if NSApp.dockTile.badgeLabel != nil {
            NSApp.dockTile.badgeLabel = nil
        }
    }

    private static func render(_ s: AppStatus) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        // 圓角底：深色方塊，跟面板同一個底色，Dock 上不會太搶。
        let bg = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 432, height: 432),
                              xRadius: 96, yRadius: 96)
        NSColor(srgbRed: 0.04, green: 0.04, blue: 0.04, alpha: 1).setFill()
        bg.fill()

        let barColor: NSColor
        switch s.phase {
        case .recording:
            barColor = NSColor(srgbRed: 0.918, green: 0.333, blue: 0.016, alpha: 1)  // #EA5504
        case .transcribing:
            barColor = NSColor(white: 0.65, alpha: 1)
        case .idle:
            // 查不到的時候用中間灰：不宣告正常，也不宣告故障。
            switch s.hotkeyState {
            case .working: barColor = NSColor(white: 0.95, alpha: 1)
            case .unknown: barColor = NSColor(white: 0.68, alpha: 1)
            case .broken:  barColor = NSColor(white: 0.42, alpha: 1)
            }
        }
        barColor.setFill()

        // 五根音柱，中間高兩側低——靜態的波形剪影，不試圖表示真實音量。
        let heights: [CGFloat] = [96, 168, 232, 168, 96]
        let barW: CGFloat = 40
        let gap: CGFloat = 26
        let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
        var x = (size.width - totalW) / 2

        for h in heights {
            let rect = NSRect(x: x, y: (size.height - h) / 2, width: barW, height: h)
            NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + gap
        }

        // 斜線＝現在按熱鍵不會有任何反應。畫在最上層，蓋過音柱才看得出是「停用」。
        // 只在**確定**壞掉時畫：查不到就畫斜線的話，等於用最醒目的方式散播一個猜測。
        if s.hotkeyState == .broken {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 128, y: 128))
            slash.line(to: NSPoint(x: 384, y: 384))
            slash.lineWidth = 34
            slash.lineCapStyle = .round
            NSColor(srgbRed: 0.04, green: 0.04, blue: 0.04, alpha: 1).setStroke()
            slash.stroke()

            let inner = NSBezierPath()
            inner.move(to: NSPoint(x: 128, y: 128))
            inner.line(to: NSPoint(x: 384, y: 384))
            inner.lineWidth = 18
            inner.lineCapStyle = .round
            NSColor(srgbRed: 0.973, green: 0.443, blue: 0.443, alpha: 1).setStroke()
            inner.stroke()
        }

        return image
    }
}
