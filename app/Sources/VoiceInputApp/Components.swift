import SwiftUI

/// 一項檢查：燈號、說明，壞掉時附一個能直接修的按鈕。
///
/// 「不知道」刻意跟「壞了」分開。Hammerspoon 沒在跑的時候查不到它的權限狀態，
/// 那時候顯示紅燈會是在指控一件沒被驗證的事，使用者會跑去改一個沒壞的設定。
struct CheckRow: View {
    enum State { case ok, bad, unknown }

    let title: String
    let detail: String
    let state: State
    let action: (String, () -> Void)?

    private var color: Color {
        switch state {
        case .ok: return Theme.good
        case .bad: return Theme.bad
        case .unknown: return Theme.dimmer
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.fg)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardEdge, lineWidth: 1))
    }
}

/// 最後一次辨識的結果卡。
struct LastResultCard: View {
    let result: LastResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(headline)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.dimmer)
                Spacer()
                if let sec = result.seconds {
                    Text(String(format: "%.1fs", sec))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.dimmer)
                }
            }

            Text(body_)
                .font(.system(size: 13))
                .foregroundStyle(result.kind == .ok ? Theme.fg : Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if let gate = result.gate {
                GateMeter(gate: gate)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardEdge, lineWidth: 1))
    }

    private var headline: String {
        switch result.kind {
        case .ok: return "上一句"
        case .skipped: return "被閘門擋下"
        case .error: return "錯誤"
        case .note: return "本地狀況"
        }
    }

    private var body_: String {
        switch result.kind {
        case .ok: return result.text ?? ""
        default: return result.reason ?? "（沒有說明）"
        }
    }
}

/// 音量條：上次量到的 p95 畫在對數軸上，門檻畫一條線。
///
/// 這裡刻意不是即時音量。sox 獨佔麥克風而且不回報音量，要做即時儀表得再開一條
/// 擷取串流，成本跟收益不成比例。而「我剛才那句到底有沒有過門檻」本來就是實際
/// 會想知道的問題——事後回答它就夠了。
struct GateMeter: View {
    let gate: Gate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cardEdge).frame(height: 6)

                    if let p95 = gate.p95 {
                        Capsule()
                            .fill(gate.passed == false ? Theme.dimmer : Theme.accent)
                            .frame(width: max(4, w * axisPos(p95)), height: 6)
                    }

                    if let need = gate.needP95 {
                        Rectangle()
                            .fill(Theme.fg.opacity(0.55))
                            .frame(width: 2, height: 12)
                            .offset(x: w * axisPos(need) - 1)
                    }
                }
                .frame(height: 12)
            }
            .frame(height: 12)

            Text(caption)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.dimmer)
                .lineLimit(2)
        }
    }

    private var caption: String {
        // 有解析成功就講人話，解析不到就把原文放上去——格式哪天改了，
        // 畫面要退化成「還看得懂」，不是變成空白。
        guard let p95 = gate.p95, let need = gate.needP95 else { return gate.raw }
        let verdict = gate.passed == false ? "沒過" : "過了"
        return "音量 \(Int(p95))／門檻 \(Int(need))　\(verdict)"
    }
}
