import SwiftUI

/// 配色與尺寸。值跟 voice-input-panel.html 對齊，兩個介面才不會長得像兩個產品。
enum Theme {
    /// Shadow 橘。只用在「正在收音」和主要動作，不用在錯誤——
    /// 橘色代表「活著」，就不能同時代表「壞了」，不然一眼分不出是哪一種。
    static let accent = Color(hex: 0xEA5504)

    static let bg = Color(hex: 0x0A0A0A)
    static let card = Color(hex: 0x151515)
    static let cardEdge = Color(hex: 0x212121)
    static let fg = Color(hex: 0xFFFFFF)
    static let dim = Color(hex: 0x999999)
    static let dimmer = Color(hex: 0x595757)

    static let good = Color(hex: 0x4ADE80)
    static let bad = Color(hex: 0xF87171)
    static let warn = Color(hex: 0xFBBF24)

    /// 音量軸上下限。跟 core.lua 的 AXIS_MIN/MAX、web/index.html 用同一組值，
    /// 三個介面才會把同一個數字畫在同一個位置。
    static let axisMin: Double = 80
    static let axisMax: Double = 16000
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// 音量 → 0..1 的位置（對數軸）。音量本身是對數的，線性軸會讓人聲全擠在右邊。
/// 這段跟 core.lua 的 M.axisPos 是同一個公式，改一邊要改兩邊。
func axisPos(_ v: Double?) -> Double {
    guard let v, v > 0 else { return 0 }
    let lo = log(Theme.axisMin)
    let hi = log(Theme.axisMax)
    let clamped = min(max(v, Theme.axisMin), Theme.axisMax)
    return min(max((log(clamped) - lo) / (hi - lo), 0), 1)
}

/// axisPos 的反函數：滑桿位置（0...1）→ 音量。靈敏度滑桿要用它把拖曳位置換回門檻值。
func axisValue(_ pos: Double) -> Double {
    let lo = log(Theme.axisMin)
    let hi = log(Theme.axisMax)
    return exp(lo + min(max(pos, 0), 1) * (hi - lo))
}
