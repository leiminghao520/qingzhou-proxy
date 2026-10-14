import AppKit
import Foundation

var candidateId = "A"
var outputDir = ".build/icon-png"

if CommandLine.arguments.count > 2 {
    candidateId = CommandLine.arguments[1]
    outputDir = CommandLine.arguments[2]
} else if CommandLine.arguments.count == 2 {
    let arg = CommandLine.arguments[1]
    if ["A", "B", "C", "D"].contains(arg.uppercased()) {
        candidateId = arg.uppercased()
    } else {
        outputDir = arg
    }
}

struct Candidate {
    let id: String
    let fileName: String
    let cropRect: NSRect
    let bgFillColor: NSColor
}

let map: [String: Candidate] = [
    "A": Candidate(
        id: "A",
        fileName: "qingzhou_proxy_icon_v2_1791884163506.jpg",
        cropRect: NSRect(x: 104, y: 104, width: 816, height: 816),
        bgFillColor: .white
    ),
    "B": Candidate(
        id: "B",
        fileName: "qingzhou_proxy_icon_minimal_1791884128366.jpg",
        cropRect: NSRect(x: 130, y: 130, width: 765, height: 765),
        bgFillColor: NSColor(calibratedRed: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
    ),
    "C": Candidate(
        id: "C",
        fileName: "qingzhou_proxy_icon_dynamic_1791884110895.jpg",
        cropRect: NSRect(x: 30, y: 30, width: 964, height: 964),
        bgFillColor: NSColor(calibratedRed: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
    ),
    "D": Candidate(
        id: "D",
        fileName: "qingzhou_proxy_icon_streamlined_1791883982336.jpg",
        cropRect: NSRect(x: 220, y: 220, width: 584, height: 584),
        bgFillColor: .white
    )
]

let brainDir = "/Users/leiminghao/.gemini/antigravity/brain/1dc97bf8-6d07-4f34-9bc1-ca38dd8c33ab"
let candidate = map[candidateId] ?? map["A"]!
let srcPath = "\(brainDir)/\(candidate.fileName)"

try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

guard let rawData = try? Data(contentsOf: URL(fileURLWithPath: srcPath)),
      let sourceRep = NSBitmapImageRep(data: rawData) else {
    fatalError("Failed to load source icon image: \(srcPath)")
}

let sourceImage = NSImage(size: NSSize(width: sourceRep.pixelsWide, height: sourceRep.pixelsHigh))
sourceImage.addRepresentation(sourceRep)

let canvasSize: CGFloat = 1024
let masterRep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize),
    pixelsHigh: Int(canvasSize),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: masterRep)!
NSGraphicsContext.current = ctx

let squircleRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185
let squirclePath = NSBezierPath(roundedRect: squircleRect, xRadius: cornerRadius, yRadius: cornerRadius)

// 1. Drop Shadow
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.30)
shadow.shadowOffset = NSSize(width: 0, height: -16)
shadow.shadowBlurRadius = 24
shadow.set()

candidate.bgFillColor.setFill()
squirclePath.fill()

NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

// 2. Clip & Draw Content
squirclePath.addClip()
sourceImage.draw(
    in: squircleRect,
    from: candidate.cropRect,
    operation: .sourceOver,
    fraction: 1.0
)

// 3. Subtle Inner Rim Specular Highlight
let innerRim = NSBezierPath(roundedRect: squircleRect.insetBy(dx: 1.0, dy: 1.0), xRadius: cornerRadius - 1.0, yRadius: cornerRadius - 1.0)
innerRim.lineWidth = 1.5
NSColor(calibratedWhite: 1.0, alpha: 0.25).setStroke()
innerRim.stroke()

NSGraphicsContext.restoreGraphicsState()

// Save Master 1024 PNG
let masterURL = URL(fileURLWithPath: outputDir).appendingPathComponent("size-1024.png")
try masterRep.representation(using: .png, properties: [:])!.write(to: masterURL)

// Generate all macOS iconset sizes: 16, 32, 64, 128, 256, 512
let masterImage = NSImage(size: NSSize(width: canvasSize, height: canvasSize))
masterImage.addRepresentation(masterRep)

for size in [16, 32, 64, 128, 256, 512] {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    
    masterImage.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize),
        operation: .copy,
        fraction: 1.0
    )
    
    NSGraphicsContext.restoreGraphicsState()
    
    let fileURL = URL(fileURLWithPath: outputDir).appendingPathComponent("size-\(size).png")
    try rep.representation(using: .png, properties: [:])!.write(to: fileURL)
}

print("ICON_GENERATION_SUCCESS for Candidate \(candidate.id)")
