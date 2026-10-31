import AppKit
import BoothCore

/// The menu bar glyph (SPEC §3.7; Glyph.dc.html, brand "booth"): a rounded booth frame with a
/// lamp. Drawn with Core Graphics in an 18-unit box, y down, so the numbers match the SVG.
enum GlyphRenderer {
    static let size = NSSize(width: 18, height: 18)
    /// The working lamp. The only colour Booth shows in the menu bar.
    static let workColor = NSColor(srgbRed: 10 / 255, green: 132 / 255, blue: 255 / 255, alpha: 1)

    private static let frameRect = CGRect(x: 3.25, y: 2.25, width: 11.5, height: 13.5)
    private static let frameCornerRadius: CGFloat = 3.6
    private static let lampCenter = CGPoint(x: 9, y: 7.2)
    private static let attentionDotCenter = CGPoint(x: 15.2, y: 3)

    /// `0.5 + 0.5·sin(2π·phase)`; the working lamp breathes once per 1.4 s.
    static let breathPeriod: CFTimeInterval = 1.4

    static func breathe(atPhase phase: Double) -> Double {
        0.5 + 0.5 * sin(2 * .pi * phase)
    }

    /// The status item image. Every mode but working is a template (the menu bar tints it);
    /// working is drawn in `ink`, the menu bar's text colour, with a coloured lamp.
    ///
    /// The image draws itself at whatever resolution it lands on, so it stays crisp on 2×
    /// and 1× menu bars alike.
    static func image(_ mode: GlyphMode, breathe: Double = 1, scale: CGFloat = 1, ink: NSColor) -> NSImage {
        let drawnInk = mode.isTemplate ? NSColor.black : ink
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(mode, breathe: breathe, scale: scale, ink: drawnInk.cgColor, in: context)
            return true
        }
        image.isTemplate = mode.isTemplate
        image.accessibilityDescription = "Booth"
        return image
    }

    /// Draws the glyph into `context`, whose user space must be the 18-unit box with y down.
    /// `scale` grows it about the centre (target 1.14, drop pulse 1.25).
    static func draw(_ mode: GlyphMode, breathe: Double, scale: CGFloat, ink: CGColor, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -size.width / 2, y: -size.height / 2)

        let dim: CGFloat = mode == .attention ? 0.45 : 1
        let frame = CGPath(roundedRect: frameRect, cornerWidth: frameCornerRadius, cornerHeight: frameCornerRadius, transform: nil)
        let work = workColor.cgColor

        // Painted in the SVG's order: halo, frame fill, frame, lamp, attention dot.
        if mode == .working {
            fillCircle(lampCenter, radius: 3.4 + 0.9 * breathe, color: work, alpha: 0.28 * breathe, in: context)
        }
        if mode == .target {
            context.setAlpha(0.16)
            context.setFillColor(ink)
            context.addPath(frame)
            context.fillPath()
        }
        context.setAlpha(dim)
        context.setStrokeColor(ink)
        context.setLineWidth(mode == .target ? 1.8 : 1.5)
        context.addPath(frame)
        context.strokePath()

        switch mode {
        case .working:
            fillCircle(lampCenter, radius: 2.1, color: work, alpha: 0.65 + 0.35 * breathe, in: context)
        case .done, .target:
            fillCircle(lampCenter, radius: 2.1, color: ink, alpha: 1, in: context)
        case .idle, .attention:
            context.setAlpha(dim)
            context.setStrokeColor(ink)
            context.setLineWidth(1.3)
            context.strokeEllipse(in: circleRect(lampCenter, radius: 1.85))
        }
        if mode == .attention {
            fillCircle(attentionDotCenter, radius: 2.6, color: ink, alpha: 1, in: context)
        }
    }

    private static func fillCircle(_ center: CGPoint, radius: CGFloat, color: CGColor, alpha: CGFloat, in context: CGContext) {
        context.setAlpha(alpha)
        context.setFillColor(color)
        context.fillEllipse(in: circleRect(center, radius: radius))
    }

    private static func circleRect(_ center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

// MARK: - --render-glyphs DIR

extension GlyphRenderer {
    /// Writes every mode in a light and a dark menu bar at 2× (`<mode>-<tone>.png`, working at
    /// five breath phases) plus `sheet.png`, a GlyphStates.dc.html-style overview, and exits.
    @MainActor
    static func renderAll(to directory: URL) -> Int32 {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.error("render-glyphs: cannot create \(directory.path): \(error)")
            return 1
        }
        var failures = 0
        func write(_ name: String, width: CGFloat, height: CGFloat, scale: CGFloat = 2, draw: (CGContext) -> Void) {
            let url = directory.appendingPathComponent(name)
            if writePNG(to: url, width: width, height: height, scale: scale, draw: draw) {
                Log.info("render-glyphs: wrote \(url.path)")
            } else {
                failures += 1
                Log.error("render-glyphs: failed to write \(url.path)")
            }
        }

        for tone in MenuBarTone.allCases {
            for mode in GlyphMode.allCases {
                let phases: [Double?] = mode == .working ? SheetColumn.workingPhases : [nil]
                for phase in phases {
                    let suffix = phase.map { String(format: "-phase%02d", Int(($0 * 100).rounded())) } ?? ""
                    write("\(mode.rawValue)-\(tone.rawValue)\(suffix).png", width: size.width, height: size.height) { context in
                        draw(mode, breathe: breathe(atPhase: phase ?? 0.25), scale: 1, ink: tone.ink, in: context)
                    }
                }
            }
        }
        write("sheet.png", width: ContactSheet.width, height: ContactSheet.height, draw: ContactSheet.draw)
        return failures == 0 ? 0 : 1
    }

    /// Renders `draw` (y-down user space of `width` × `height` points) into a PNG at `scale`.
    private static func writePNG(to url: URL, width: CGFloat, height: CGFloat, scale: CGFloat, draw: (CGContext) -> Void) -> Bool {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return false }
        bitmap.size = NSSize(width: width, height: height)
        let context = graphics.cgContext
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Log.error("render-glyphs: \(url.path): \(error)")
            return false
        }
    }
}

/// The two menu bar tones Glyph.dc.html draws in.
private enum MenuBarTone: String, CaseIterable {
    case light, dark

    var ink: CGColor {
        switch self {
        case .light: CGColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1)
        case .dark: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }
}

private struct SheetColumn {
    var label: String
    var mode: GlyphMode
    var phase: Double

    /// GlyphStates.dc.html's working columns: 0.35 s, 0.7 s, 1.05 s and 1.4 s into a breath.
    static let workingPhases: [Double?] = [0, 0.25, 0.5, 0.75, 0.98]

    static let all = [
        SheetColumn(label: "Idle", mode: .idle, phase: 0),
        SheetColumn(label: "File over icon", mode: .target, phase: 0),
        SheetColumn(label: "Working · 0.35 s", mode: .working, phase: 0.25),
        SheetColumn(label: "0.7 s", mode: .working, phase: 0.5),
        SheetColumn(label: "1.05 s", mode: .working, phase: 0.75),
        SheetColumn(label: "1.4 s", mode: .working, phase: 0.98),
        SheetColumn(label: "Done", mode: .done, phase: 0),
        SheetColumn(label: "Needs attention", mode: .attention, phase: 0),
    ]
}

/// GlyphStates.dc.html: actual size in a light and a dark menu bar, then 4× on light and dark.
private enum ContactSheet {
    static let padding: CGFloat = 24
    static let columnWidth: CGFloat = 120
    static let gap: CGFloat = 12
    static let width = padding * 2 + CGFloat(SheetColumn.all.count) * columnWidth + CGFloat(SheetColumn.all.count - 1) * gap
    static let height: CGFloat = padding * 2 + 20 + 10 + (28 + 10) * 2 + (132 + 10) * 2

    static func draw(_ context: CGContext) {
        fill(CGRect(x: 0, y: 0, width: width, height: height), rgb: 0xF6F6F4, in: context)
        for (index, column) in SheetColumn.all.enumerated() {
            let x = padding + CGFloat(index) * (columnWidth + gap)
            var y = padding
            let label = NSAttributedString(string: column.label, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1),
            ])
            label.draw(at: CGPoint(x: x, y: y + 2))
            y += 30
            let breathe = GlyphRenderer.breathe(atPhase: column.phase)
            for tone in MenuBarTone.allCases {
                drawMenuBarCell(column, tone: tone, breathe: breathe, frame: CGRect(x: x, y: y, width: columnWidth, height: 28), in: context)
                y += 38
            }
            for tone in MenuBarTone.allCases {
                let card = CGRect(x: x, y: y, width: columnWidth, height: 132)
                fillRounded(card, radius: 12, rgb: tone == .light ? 0xFFFFFF : 0x1F1F22, alpha: 1, in: context)
                drawGlyph(column.mode, breathe: breathe, scale: 1, ink: tone.ink, size: 72, centeredIn: card, in: context)
                y += 142
            }
        }
    }

    /// A strip of menu bar with the 32×22 button; "File over icon" shows the tinted, grown button.
    private static func drawMenuBarCell(_ column: SheetColumn, tone: MenuBarTone, breathe: Double, frame: CGRect, in context: CGContext) {
        fillRounded(frame, radius: 6, rgb: tone == .light ? 0xE9E6E1 : 0x2A2A2D, alpha: 1, in: context)
        let isTarget = column.mode == .target
        let scale: CGFloat = isTarget ? 1.14 : 1
        if isTarget {
            let button = CGRect(x: frame.midX - 16 * scale, y: frame.midY - 11 * scale, width: 32 * scale, height: 22 * scale)
            fillRounded(button, radius: 6 * scale, rgb: tone == .light ? 0x000000 : 0xFFFFFF, alpha: tone == .light ? 0.14 : 0.22, in: context)
        }
        drawGlyph(column.mode, breathe: breathe, scale: scale, ink: tone.ink, size: 18, centeredIn: frame, in: context)
    }

    private static func drawGlyph(_ mode: GlyphMode, breathe: Double, scale: CGFloat, ink: CGColor, size: CGFloat, centeredIn rect: CGRect, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.midX - size / 2, y: rect.midY - size / 2)
        context.scaleBy(x: size / GlyphRenderer.size.width, y: size / GlyphRenderer.size.height)
        GlyphRenderer.draw(mode, breathe: breathe, scale: scale, ink: ink, in: context)
        context.restoreGState()
    }

    private static func fill(_ rect: CGRect, rgb: UInt32, in context: CGContext) {
        fillRounded(rect, radius: 0, rgb: rgb, alpha: 1, in: context)
    }

    private static func fillRounded(_ rect: CGRect, radius: CGFloat, rgb: UInt32, alpha: CGFloat, in context: CGContext) {
        context.saveGState()
        context.setFillColor(CGColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        context.restoreGState()
    }
}
