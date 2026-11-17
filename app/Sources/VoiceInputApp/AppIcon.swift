import AppKit

/// Dock uses the same three-bar-and-circle mark as Finder and Windows.
/// Recording, processing and unavailable states retain their distinct colors and badges.
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
        let style: VoiceLogo.Style
        if s.hotkeyState == .broken {
            style = .offline
        } else {
            switch s.phase {
            case .recording: style = .recording
            case .transcribing: style = .transcribing
            case .idle: style = s.hotkeyState == .unknown ? .unknown : .brand
            }
        }
        return VoiceLogo.image(style: style)
    }
}
