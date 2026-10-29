// swift-tools-version: 5.7
import PackageDescription
// 仅保留生产库，去除上游未启用的 iOS 预览依赖；源码与许可证保持原样。
let package = Package(name: "Pow", platforms: [.macOS(.v12)], products: [.library(name: "Pow", targets: ["Pow"])], targets: [.target(name: "Pow", resources: [.process("Assets.xcassets")])], swiftLanguageVersions: [.v5])
