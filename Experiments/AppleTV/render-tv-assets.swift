// Exports the existing MijiaLAN vector mark into Apple's layered tvOS catalog.
// Run from the repository root: swift Experiments/AppleTV/render-tv-assets.swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let brand = root.appendingPathComponent("tvOS/Assets.xcassets/AppIcon.brandassets")
let source = root.appendingPathComponent("../../Resources/AppIcon.icon/Assets/House.svg").standardizedFileURL
guard let house = NSImage(contentsOf: source) else { fatalError("Missing existing House.svg brand mark") }
let info: [String: Any] = ["author": "xcode", "version": 1]
let background = NSColor(srgbRed: 0.11765, green: 0.65098, blue: 0.58039, alpha: 1)

func json(_ value: [String: Any], at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

func render(width: Int, height: Int, fill: Bool, mark: Bool, at url: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let canvas = NSRect(x: 0, y: 0, width: width, height: height)
    NSColor.clear.setFill(); canvas.fill(using: .copy)
    if fill { background.setFill(); canvas.fill() }
    if mark {
        let side = CGFloat(height) * 1.3
        house.draw(in: NSRect(x: (CGFloat(width) - side) / 2, y: (CGFloat(height) - side) / 2, width: side, height: side))
    }
    NSGraphicsContext.restoreGraphicsState()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

try json(["info": info], at: brand.deletingLastPathComponent().appendingPathComponent("Contents.json"))
var assets: [[String: Any]] = []
for (name, width, height, scales) in [("App Icon", 400, 240, [1, 2]), ("App Store Icon", 1280, 768, [1])] {
    let stack = brand.appendingPathComponent(name + ".imagestack")
    try json(["info": info, "layers": [["filename": "Front.imagestacklayer"], ["filename": "Back.imagestacklayer"]]], at: stack.appendingPathComponent("Contents.json"))
    for layer in ["Front", "Back"] {
        let folder = stack.appendingPathComponent(layer + ".imagestacklayer")
        try json(["info": info], at: folder.appendingPathComponent("Contents.json"))
        var images: [[String: Any]] = []
        for scale in scales {
            let filename = "\(layer.lowercased())@\(scale)x.png"
            images.append(["idiom": "tv", "scale": "\(scale)x", "filename": filename])
            try render(width: width * scale, height: height * scale, fill: layer == "Back", mark: layer == "Front",
                at: folder.appendingPathComponent("Content.imageset/" + filename))
        }
        try json(["info": info, "images": images], at: folder.appendingPathComponent("Content.imageset/Contents.json"))
    }
    assets.append(["filename": name + ".imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "\(width)x\(height)"])
}
for (name, width, role) in [("Top Shelf", 1920, "top-shelf-image"), ("Top Shelf Wide", 2320, "top-shelf-image-wide")] {
    let folder = brand.appendingPathComponent(name + ".imageset")
    for scale in [1, 2] {
        try render(width: width * scale, height: 720 * scale, fill: true, mark: true, at: folder.appendingPathComponent("image@\(scale)x.png"))
    }
    try json(["info": info, "images": [1, 2].map { ["idiom": "tv", "scale": "\($0)x", "filename": "image@\($0)x.png"] }], at: folder.appendingPathComponent("Contents.json"))
    assets.append(["filename": name + ".imageset", "idiom": "tv", "role": role, "size": "\(width)x720"])
}
try json(["info": info, "assets": assets], at: brand.appendingPathComponent("Contents.json"))
try render(width: 800, height: 480, fill: true, mark: true, at: root.appendingPathComponent("Design/tvos-app-icon.png"))
print("Exported layered tvOS icons and Top Shelf assets from the existing House.svg.")
