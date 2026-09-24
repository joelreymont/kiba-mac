// Renders the Kiba app icon, the twin-reservoir mark (two green cells on a
// dark slate rounded square), as the PNG set `iconutil` turns into an .icns.
//
// Usage: swift Scripts/icon.swift <outdir>
//   <outdir> is created when missing; name it `<something>.iconset` to hand it
//   to `iconutil -c icns`.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The 1024 px master grid (macOS icon template): artwork inset 100 px,
/// corner radius 185 px.
enum Grid {
    static let canvas: CGFloat = 1024
    static let inset: CGFloat = 100
    static let corner: CGFloat = 185
    static let shadowBlur: CGFloat = 28
    static let shadowDrop: CGFloat = 12
    static let shadowAlpha: CGFloat = 0.35
}

/// The two reservoirs, left fuller than right.
enum Cells {
    static let width: CGFloat = 196
    static let height: CGFloat = 540
    static let gap: CGFloat = 92
    static let corner: CGFloat = 64
    /// Clearance between a cell's wall and its water.
    static let wall: CGFloat = 26
    static let levels: [CGFloat] = [0.78, 0.52]
}

enum Palette {
    static let slateTop = rgb(0x334155)
    static let slateBottom = rgb(0x151C27)
    static let well = rgb(0x0B1119, alpha: 0.55)
    static let rim = rgb(0x5B6B80, alpha: 0.55)
    static let greenTop = rgb(0x6FD9A4)
    static let greenBottom = rgb(0x2E9E6B)
    static let sheen = rgb(0xFFFFFF, alpha: 0.10)

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        let byte = CGFloat(UInt8.max)
        return CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / byte,
            green: CGFloat((hex >> 8) & 0xFF) / byte,
            blue: CGFloat(hex & 0xFF) / byte,
            alpha: alpha)
    }
}

/// Reports on stderr and exits with a sysexits status.
func die(_ why: String, _ status: Int32) -> Never {
    FileHandle.standardError.write(Data("icon.swift: \(why)\n".utf8))
    exit(status)
}

/// Every image an .iconset holds: point size and scale.
let variants: [(points: Int, scale: Int)] = [16, 32, 128, 256, 512].flatMap { [($0, 1), ($0, 2)] }

func gradient(_ top: CGColor, _ bottom: CGColor) -> CGGradient {
    guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray,
                             locations: nil) else {
        die("could not build a gradient", EX_SOFTWARE)
    }
    return g
}

func draw(_ ctx: CGContext) {
    let tile = CGRect(x: Grid.inset, y: Grid.inset, width: Grid.canvas - 2 * Grid.inset,
                      height: Grid.canvas - 2 * Grid.inset)
    let body = CGPath(roundedRect: tile, cornerWidth: Grid.corner, cornerHeight: Grid.corner, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -Grid.shadowDrop), blur: Grid.shadowBlur,
                  color: CGColor(gray: 0, alpha: Grid.shadowAlpha))
    ctx.addPath(body)
    ctx.setFillColor(Palette.slateBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient(Palette.slateTop, Palette.slateBottom),
                           start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    ctx.restoreGState()

    let total = CGFloat(Cells.levels.count) * Cells.width + CGFloat(Cells.levels.count - 1) * Cells.gap
    var x = (Grid.canvas - total) / 2
    let y = (Grid.canvas - Cells.height) / 2
    for level in Cells.levels {
        let cell = CGRect(x: x, y: y, width: Cells.width, height: Cells.height)
        let wall = CGPath(roundedRect: cell, cornerWidth: Cells.corner, cornerHeight: Cells.corner, transform: nil)
        ctx.addPath(wall)
        ctx.setFillColor(Palette.well)
        ctx.fillPath()
        ctx.addPath(wall)
        ctx.setStrokeColor(Palette.rim)
        ctx.setLineWidth(Cells.wall / 3)
        ctx.strokePath()

        let inner = cell.insetBy(dx: Cells.wall, dy: Cells.wall)
        let water = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height * level)
        let radius = Cells.corner - Cells.wall
        let shape = CGPath(roundedRect: water, cornerWidth: radius, cornerHeight: min(radius, water.height / 2),
                           transform: nil)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.drawLinearGradient(gradient(Palette.greenTop, Palette.greenBottom),
                               start: CGPoint(x: 0, y: water.maxY), end: CGPoint(x: 0, y: water.minY), options: [])
        ctx.setFillColor(Palette.sheen)
        ctx.fill(CGRect(x: water.minX, y: water.maxY - Cells.wall, width: water.width, height: Cells.wall))
        ctx.restoreGState()
        x += Cells.width + Cells.gap
    }
}

func render(pixels: Int) -> CGImage {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        die("could not create a \(pixels) px bitmap", EX_SOFTWARE)
    }
    let s = CGFloat(pixels) / Grid.canvas
    ctx.scaleBy(x: s, y: s)
    draw(ctx)
    guard let img = ctx.makeImage() else { die("could not finish the \(pixels) px bitmap", EX_SOFTWARE) }
    return img
}

func write(_ img: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        die("cannot write \(url.path)", EX_CANTCREAT)
    }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { die("cannot write \(url.path)", EX_IOERR) }
}

let args = CommandLine.arguments
guard args.count == 2 else { die("usage: swift Scripts/icon.swift <outdir>", EX_USAGE) }
let dir = URL(fileURLWithPath: args[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
} catch {
    die("cannot create \(dir.path): \(error.localizedDescription)", EX_CANTCREAT)
}
for v in variants {
    let suffix = v.scale == 1 ? "" : "@\(v.scale)x"
    write(render(pixels: v.points * v.scale), to: dir.appendingPathComponent("icon_\(v.points)x\(v.points)\(suffix).png"))
}
