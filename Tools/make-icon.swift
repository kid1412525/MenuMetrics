import AppKit

/// AppIcon.icns を生成する (ビルドスクリプトから呼ばれる)。
/// 引数: 出力先の .icns パス

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: make-icon <output.icns>\n".data(using: .utf8)!)
    exit(1)
}
let outputPath = CommandLine.arguments[1]

func renderIcon(pixels: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    defer { image.unlockFocus() }
    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS のアイコンは周囲に余白をとった角丸長方形が基本形
    let inset = pixels * 0.085
    let rect = NSRect(x: inset, y: inset, width: pixels - inset * 2, height: pixels - inset * 2)
    let radius = rect.width * 0.2237

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    NSGradient(
        starting: NSColor(srgbRed: 0.16, green: 0.42, blue: 0.96, alpha: 1),
        ending: NSColor(srgbRed: 0.48, green: 0.24, blue: 0.89, alpha: 1)
    )?.draw(in: rect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // 中央にゲージのシンボルを白で載せる
    let configuration = NSImage.SymbolConfiguration(pointSize: rect.width * 0.60, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let target = NSRect(
            x: rect.midX - symbol.size.width / 2,
            y: rect.midY - symbol.size.height / 2,
            width: symbol.size.width,
            height: symbol.size.height
        )
        NSColor.white.set()
        symbol.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }
    return image
}

let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MenuMetrics-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    let image = renderIcon(pixels: CGFloat(variant.points * variant.scale))
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { continue }
    let suffix = variant.scale == 1 ? "" : "@2x"
    try png.write(to: iconset.appendingPathComponent("icon_\(variant.points)x\(variant.points)\(suffix).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
