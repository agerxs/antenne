// Dessine l'icône d'Antenne : Antenne/Assets.xcassets/AppIcon.appiconset (iPhone, Mac)
// et les icônes adaptatives d'antenne_android (fond et motif séparés).
// Usage : swift scripts/app-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = root.appending(path: "Antenne/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Le motif, dans un carré de 1024 : fond nuit, écran orange, antennes « oreilles de lapin », lecture.
func drawBackground(in ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let background = CGGradient(colorsSpace: space, colors: [color(0x111A2E), color(0x22325E)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])
}

func drawArtwork(in ctx: CGContext, withBackground: Bool = true) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    if withBackground { drawBackground(in: ctx) }

    // Repère du dessin : origine en haut à gauche, comme une maquette.
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    let screen = CGRect(x: 192, y: 408, width: 640, height: 452)
    let earBase = CGPoint(x: 512, y: screen.minY - 6)
    ctx.setStrokeColor(color(0xF4F1EA))
    ctx.setLineWidth(36)
    ctx.setLineCap(.round)
    for (angle, length) in [(-34.0, 270.0), (24.0, 236.0)] {
        let radians = (angle - 90) * .pi / 180
        let tip = CGPoint(x: earBase.x + cos(radians) * length, y: earBase.y + sin(radians) * length)
        ctx.move(to: earBase)
        ctx.addLine(to: tip)
        ctx.strokePath()
        ctx.setFillColor(color(0xF4F1EA))
        ctx.fillEllipse(in: CGRect(x: tip.x - 30, y: tip.y - 30, width: 60, height: 60))
    }

    let screenPath = CGPath(roundedRect: screen, cornerWidth: 96, cornerHeight: 96, transform: nil)
    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFF9A4A), color(0xF2552C)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(glow, start: CGPoint(x: screen.minX, y: screen.minY), end: CGPoint(x: screen.maxX, y: screen.maxY), options: [])
    ctx.restoreGState()

    // Triangle de lecture aux angles arrondis.
    let play = CGMutablePath()
    let center = CGPoint(x: screen.midX + 14, y: screen.midY)
    let points = [CGPoint(x: center.x - 70, y: center.y - 108), CGPoint(x: center.x + 112, y: center.y),
                  CGPoint(x: center.x - 70, y: center.y + 108)]
    play.move(to: CGPoint(x: (points[2].x + points[0].x) / 2, y: (points[2].y + points[0].y) / 2))
    for index in 0..<3 {
        play.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % 3], radius: 26)
    }
    play.closeSubpath()
    ctx.addPath(play)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
}

func render(size: Int, mac: Bool) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: mac ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
    let scale = CGFloat(size) / 1024
    ctx.scaleBy(x: scale, y: scale)
    if mac {
        // Grille des icônes Mac : un carré arrondi de 824 points centré, avec une ombre douce.
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(color(0x111A2E))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.translateBy(x: tile.minX, y: tile.minY)
        ctx.scaleBy(x: tile.width / 1024, y: tile.height / 1024)
    }
    drawArtwork(in: ctx)
    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
try render(size: 1024, mac: false).write(to: iconSet.appending(path: "ios-1024.png"))
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios-1024.png"])
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "mac-\(points)@\(scale)x.png"
        try render(size: points * scale, mac: true).write(to: iconSet.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appending(path: "Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.write(to: iconSet.deletingLastPathComponent().appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("Icône écrite dans \(iconSet.path)")

// Android : icône adaptative (108 dp, motif dans la zone sûre de 66 dp) et icône classique.
enum AndroidLayer { case background, foreground }

func renderAndroid(size: Int, layer: AndroidLayer) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    switch layer {
    case .background:
        drawBackground(in: ctx)
    case .foreground:
        let inset: CGFloat = 1024 * 0.15
        ctx.translateBy(x: inset, y: inset)
        ctx.scaleBy(x: (1024 - 2 * inset) / 1024, y: (1024 - 2 * inset) / 1024)
        drawArtwork(in: ctx, withBackground: false)
    }
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let androidRes = root.appending(path: "antenne_android/android/app/src/main/res")
if FileManager.default.fileExists(atPath: androidRes.path) {
    for (density, scale) in [("mdpi", 1.0), ("hdpi", 1.5), ("xhdpi", 2.0), ("xxhdpi", 3.0), ("xxxhdpi", 4.0)] {
        let folder = androidRes.appending(path: "mipmap-\(density)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try renderAndroid(size: Int(108 * scale), layer: .background).write(to: folder.appending(path: "ic_launcher_background.png"))
        try renderAndroid(size: Int(108 * scale), layer: .foreground).write(to: folder.appending(path: "ic_launcher_foreground.png"))
        try render(size: Int(48 * scale), mac: false).write(to: folder.appending(path: "ic_launcher.png"))
    }
    let adaptive = androidRes.appending(path: "mipmap-anydpi-v26")
    try FileManager.default.createDirectory(at: adaptive, withIntermediateDirectories: true)
    try """
    <?xml version="1.0" encoding="utf-8"?>
    <adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
        <background android:drawable="@mipmap/ic_launcher_background" />
        <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    </adaptive-icon>
    """.write(to: adaptive.appending(path: "ic_launcher.xml"), atomically: true, encoding: .utf8)
    print("Icônes Android écrites dans \(androidRes.path)")
}
