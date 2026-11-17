import AppKit

@main
struct ExportIcons {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func save(_ name: String, pixels: Int, style: VoiceLogo.Style = .brand) throws {
            let image = VoiceLogo.image(pixels: pixels, style: style)
            let rep = image.representations[0] as! NSBitmapImageRep
            guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
            try data.write(to: output.appendingPathComponent(name))
        }
        try save("logo.png", pixels: 1024)
        try save("preview.png", pixels: 256)
        for style in VoiceLogo.Style.allCases {
            try save("\(style.rawValue).png", pixels: 1024, style: style)
        }
        let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            try save("AppIcon.iconset/icon_\(size)x\(size).png", pixels: size)
            try save("AppIcon.iconset/icon_\(size)x\(size)@2x.png", pixels: size * 2)
        }
    }
}
