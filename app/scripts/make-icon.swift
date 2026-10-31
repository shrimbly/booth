// Renders the Booth app icon (AppIcon.dc.html, brand "booth", light appearance) with CoreGraphics
// at every iconset size, then packs the set with iconutil.
//
//     swift app/scripts/make-icon.swift OUTPUT_DIR
//
// Writes OUTPUT_DIR/Booth.iconset/*.png, OUTPUT_DIR/Booth.icns and a preview, OUTPUT_DIR/Booth-1024.png.
// Each size is drawn from vector geometry at its own pixel size rather than downscaled from 1024.

import CoreGraphics
import Foundation
import ImageIO

// MARK: - Design

/// Geometry from AppIcon.dc.html, as fractions of the tile's side. Like the mockup's CSS, the frame's
/// border is drawn inside its box and its radius is the outer one.
enum Design {
    static let cornerRadius = 0.225
    static let frameWidth = 0.46
    static let frameHeight = 0.54
    static let frameTop = 0.23
    static let frameBorder = 0.04
    static let frameRadius = 0.14
    static let lampDiameter = 0.14
    static let lampTop = frameTop + 0.125
    /// The mockup's `inset 0 0 0 max(0.5px, 0.4%) rgba(0,0,0,0.08)` hairline ring.
    static let ringWidth = 0.004
    static let ringColor = RGBA(0, 0, 0, 0.08)
    static let gradientTop = RGBA(0xFF, 0xFF, 0xFF)
    static let gradientBottom = RGBA(0xEC, 0xEC, 0xEA)
    static let ink = RGBA(0x1D, 0x1D, 0x1F)
}

/// The macOS (Big Sur and later) icon grid: an 824-unit tile centred on a 1024-unit canvas, the margin
/// leaving room for a drop shadow so the icon sits in the Dock and Finder like the system's own.
/// Like the system icons, the inset is rounded to whole pixels (16 px: a 12 px tile at 2; 32 px: 26 at 3).
enum Grid {
    static let tileInset = 100.0 / 1024
    /// A tight contact shadow for definition, plus the mockup's wide, soft `0 2% 5%` one, darkened from
    /// 12 % to 20 % so the white tile still separates from light Finder and Dock backgrounds
    /// (fractions of the tile).
    static let shadows = [
        Shadow(offsetY: 0.006, blur: 0.012, color: RGBA(0, 0, 0, 0.16)),
        Shadow(offsetY: 0.02, blur: 0.05, color: RGBA(0, 0, 0, 0.20)),
    ]
}

struct Shadow {
    var offsetY: Double
    var blur: Double
    var color: RGBA
}

struct RGBA {
    var red, green, blue: Double
    var alpha: Double

    init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        (self.red, self.green, self.blue, self.alpha) = (red / 255, green / 255, blue / 255, alpha)
    }

    var cgColor: CGColor {
        CGColor(colorSpace: sRGB, components: [red, green, blue, alpha])!
    }
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Rendering

/// Draws the icon on a square canvas `pixels` wide.
func renderIcon(pixels: Int) -> CGImage {
    let canvas = Double(pixels)
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not create a \(pixels)px bitmap context") }

    // Work top-down, like the CSS mockup.
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)

    let inset = (canvas * Grid.tileInset).rounded()
    let tile = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
    let side = tile.width
    let tilePath = continuousRoundedRect(tile, radius: side * Design.cornerRadius)

    drawShadows(of: tilePath, side: side, in: context)

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: sRGB,
        colors: [Design.gradientTop.cgColor, Design.gradientBottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: tile.midX, y: tile.minY), end: CGPoint(x: tile.midX, y: tile.maxY), options: []
    )
    // Stroking the clipped outline at twice the width leaves an inner hairline of the full width.
    context.addPath(tilePath)
    context.setStrokeColor(Design.ringColor.cgColor)
    context.setLineWidth(2 * max(0.5, side * Design.ringWidth))
    context.strokePath()
    context.restoreGState()

    drawBooth(in: tile, context: context)

    guard let image = context.makeImage() else { fail("could not render the \(pixels)px icon") }
    return image
}

/// Fills the tile once per shadow. Every fill is covered by the gradient afterwards, so only the
/// shadows show. Shadow offsets are in device space, where +y points up, whatever the CTM.
func drawShadows(of tilePath: CGPath, side: Double, in context: CGContext) {
    for shadow in Grid.shadows {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -shadow.offsetY * side), blur: shadow.blur * side,
            color: shadow.color.cgColor
        )
        context.addPath(tilePath)
        context.setFillColor(Design.gradientBottom.cgColor)
        context.fillPath()
        context.restoreGState()
    }
}

/// The booth: a rounded frame with a lamp near its top, both in ink.
func drawBooth(in tile: CGRect, context: CGContext) {
    let layout = BoothLayout(tile: tile)
    let frameShape = CGMutablePath()
    frameShape.addPath(roundedRect(layout.frame, radius: layout.frameRadius))
    frameShape.addPath(roundedRect(
        layout.frame.insetBy(dx: layout.border, dy: layout.border), radius: max(0, layout.frameRadius - layout.border)
    ))
    context.setFillColor(Design.ink.cgColor)
    context.addPath(frameShape)
    context.fillPath(using: .evenOdd)
    // Two pixels across, a circle only reads as grey; filling the pixels keeps the lamp in full ink.
    if layout.lamp.width <= 2 {
        context.fill(layout.lamp)
    } else {
        context.fillEllipse(in: layout.lamp)
    }
}

/// The frame and lamp for a tile, snapped so every straight edge falls on a pixel boundary and both
/// shapes centre on whole pixels. That keeps 16 and 32 px crisp, with a clear gap between the lamp and
/// the frame; at large sizes the rounding is invisible.
struct BoothLayout {
    var frame: CGRect
    var border: Double
    var frameRadius: Double
    var lamp: CGRect

    init(tile: CGRect) {
        let side = tile.width
        let width = nearest(side * Design.frameWidth, withParityOf: side)
        let height = (width * Design.frameHeight / Design.frameWidth).rounded()
        // Rounding down when the frame can't centre exactly: a shade high reads as optically centred.
        let top = (tile.midY - height / 2).rounded(.down)
        frame = CGRect(x: tile.midX - width / 2, y: top, width: width, height: height)
        border = max(1, (side * Design.frameBorder).rounded())
        frameRadius = side * Design.frameRadius

        let diameter = max(2, nearest(side * Design.lampDiameter, withParityOf: width))
        let lampTop = max((top + side * (Design.lampTop - Design.frameTop)).rounded(), top + border + 1)
        lamp = CGRect(x: tile.midX - diameter / 2, y: lampTop, width: diameter, height: diameter)
    }
}

/// The whole number nearest `value` with the same parity as `reference`, so a shape that size centres
/// on pixel boundaries inside a box `reference` pixels wide.
func nearest(_ value: Double, withParityOf reference: Double) -> Double {
    let parity = reference.rounded().truncatingRemainder(dividingBy: 2)
    return ((value - parity) / 2).rounded() * 2 + parity
}

/// A CSS-style rounded rectangle (circular corners), as the mockup draws the frame.
func roundedRect(_ rect: CGRect, radius: Double) -> CGPath {
    let radius = min(radius, rect.width / 2, rect.height / 2)
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - Continuous corners

/// Apple's continuous-curvature ("squircle") rounded rectangle, the shape of macOS app icon tiles.
/// The corner is the widely used reverse-engineering of `UIBezierPath(roundedRect:cornerRadius:)`:
/// each point is (distance back along the incoming edge, distance along the outgoing edge), in units
/// of the corner radius. A corner starts 1.528665 radii before the vertex instead of 1.
private enum CornerSegment {
    case line(Double, Double)
    case curve(to: (Double, Double), control1: (Double, Double), control2: (Double, Double))
}

private let cornerExtent = 1.52866483

private let cornerSegments: [CornerSegment] = [
    .line(cornerExtent, 0),
    .curve(to: (0.66993427, 0.06549600), control1: (1.08849323, 0), control2: (0.86840689, 0)),
    .line(0.63149399, 0.07491100),
    .curve(to: (0.07491176, 0.63149399), control1: (0.37282392, 0.16905899), control2: (0.16906013, 0.37282401)),
    .curve(to: (0, cornerExtent), control1: (0, 0.86840701), control2: (0, 1.08849299)),
]

func continuousRoundedRect(_ rect: CGRect, radius: Double) -> CGPath {
    let radius = min(radius, min(rect.width, rect.height) / 2 / cornerExtent)
    // Clockwise on screen (y down): each corner's vertex, incoming edge direction, outgoing edge direction.
    let corners: [(vertex: CGPoint, incoming: CGVector, outgoing: CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
    ]
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX + cornerExtent * radius, y: rect.minY))
    for corner in corners {
        func point(_ p: (Double, Double)) -> CGPoint {
            CGPoint(
                x: corner.vertex.x - p.0 * radius * corner.incoming.dx + p.1 * radius * corner.outgoing.dx,
                y: corner.vertex.y - p.0 * radius * corner.incoming.dy + p.1 * radius * corner.outgoing.dy
            )
        }
        for segment in cornerSegments {
            switch segment {
            case let .line(back, along):
                path.addLine(to: point((back, along)))
            case let .curve(end, control1, control2):
                path.addCurve(to: point(end), control1: point(control1), control2: point(control2))
            }
        }
    }
    path.closeSubpath()
    return path
}

// MARK: - Output

func writePNG(_ image: CGImage, to url: URL, scale: Int) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fail("could not create \(url.path)")
    }
    let dpi = 72 * scale
    CGImageDestinationAddImage(
        destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(url.path)") }
}

func run(_ executable: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    do {
        try process.run()
    } catch {
        fail("could not run \(executable): \(error.localizedDescription)")
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fail("\(executable) \(arguments.joined(separator: " ")) exited with \(process.terminationStatus)")
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

// MARK: - Main

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 1, let outputPath = arguments.first, !outputPath.hasPrefix("-") else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift OUTPUT_DIR\n".utf8))
    exit(64)
}

let manager = FileManager.default
let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
let iconset = outputDirectory.appendingPathComponent("Booth.iconset", isDirectory: true)
let icns = outputDirectory.appendingPathComponent("Booth.icns")
let preview = outputDirectory.appendingPathComponent("Booth-1024.png")

do {
    try? manager.removeItem(at: iconset)
    try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch {
    fail("could not create \(iconset.path): \(error.localizedDescription)")
}

var renders: [Int: CGImage] = [:]
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = renders[pixels] ?? renderIcon(pixels: pixels)
        renders[pixels] = image
        let suffix = scale == 1 ? "" : "@\(scale)x"
        writePNG(image, to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"), scale: scale)
    }
}
writePNG(renders[1024]!, to: preview, scale: 1)
run("/usr/bin/iconutil", ["--convert", "icns", "--output", icns.path, iconset.path])

print(icns.path)
print(preview.path)
