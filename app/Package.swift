// swift-tools-version: 6.0
import PackageDescription

// 這個 target 不開 sandbox（build.sh 也不加 entitlements）。
// 不是偷懶——狀態檔在 $DARWIN_USER_TEMP_DIR，一開 sandbox 就會被重導到
// App 自己的 container，App 會讀到一個永遠空的目錄，什麼狀態都看不到。
let package = Package(
    name: "VoiceInputApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VoiceInputApp",
            path: "Sources/VoiceInputApp"
        )
    ]
)
