import SwiftUI

/// 靈敏度滑桿：這台 Mac 自己的門檻，留白＝跟著 Spark 全域值。
///
/// 對數軸跟音量條（GateMeter）同一把尺（Theme.axisMin/Max），拖到哪裡對照
/// 上面「上次量到」的位置就知道會不會過。拖曳中只改本地暫存值，放開才真的
/// 寫檔——不然每拖 1px 就寫一次檔案，SSD 磨損不說，寫檔本身也有延遲。
struct SensitivityCard: View {
    let local: Double?          // 這台的覆蓋值；nil＝跟著全域
    let global: Double?         // Spark 回報的全域門檻
    let lastP95: Double?        // 上次量到的音量，給拖曳時一個對照
    let onChange: (Double?) -> Void

    @State private var dragging: Double?

    private var effective: Double? { dragging ?? local ?? global }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("靈敏度")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.dimmer)
                Spacer()
                if local != nil {
                    Button("改回跟著 Spark") { onChange(nil) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                }
            }

            Slider(
                value: Binding(
                    get: { axisPos(dragging ?? local ?? global) },
                    set: { dragging = axisValue($0) }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    guard !editing, let v = dragging else { return }
                    dragging = nil
                    onChange(v)
                }
            )
            .tint(Theme.accent)

            HStack(spacing: 6) {
                Text(effective != nil ? "\(Int(effective!))" : "—")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.fg)
                Text(local != nil ? "這台自己的門檻" : "跟著 Spark 全域值")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dimmer)
                Spacer()
                if let lastP95 {
                    Text("上次量到 \(Int(lastP95))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.dimmer)
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardEdge, lineWidth: 1))
    }
}
