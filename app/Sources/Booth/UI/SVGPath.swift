import CoreGraphics
import SwiftUI

/// Builds a `Path` from SVG path data, so icons can be pasted from their SVG source unchanged.
///
/// Supports the commands the popover's icons use — M, L, H, V, C, A and Z, absolute and
/// relative, with implicit repetition and compact numbers such as `2.73.73` or `0-2`.
/// Parsing stops at the first malformed token and returns what was built so far.
enum SVGPath {
    static func parse(_ data: String) -> Path {
        var builder = Builder()
        var scanner = Scanner(data)
        var command: UInt8?
        while true {
            if let next = scanner.command() {
                command = next
            } else if command == nil || !scanner.hasNumber() {
                break
            }
            guard let current = command, let repeated = builder.apply(current, from: &scanner) else {
                assert(scanner.isAtEnd, "malformed SVG path data: \(data)")
                break
            }
            command = repeated
        }
        return builder.path
    }

    /// Appends an SVG elliptical arc (endpoint parameterisation, SVG 1.1 §F.6.5) as cubic Béziers
    /// of at most 90° each.
    static func addArc(
        to path: inout Path, from start: CGPoint, to end: CGPoint, radii: CGSize,
        rotation degrees: CGFloat, largeArc: Bool, sweep: Bool
    ) {
        guard start != end else { return }
        var rx = abs(radii.width), ry = abs(radii.height)
        guard rx > 0, ry > 0 else {
            path.addLine(to: end)
            return
        }
        let phi = degrees * .pi / 180
        let (cosPhi, sinPhi) = (cos(phi), sin(phi))
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        // Radii too small to span the endpoints are scaled up just enough.
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coefficient = max(0, numerator / denominator).squareRoot()
        if largeArc == sweep { coefficient = -coefficient }
        let cx1 = coefficient * rx * y1 / ry
        let cy1 = -coefficient * ry * x1 / rx
        let center = CGPoint(
            x: cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2,
            y: sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2)

        func angle(_ u: CGVector, _ v: CGVector) -> CGFloat {
            atan2(u.dx * v.dy - u.dy * v.dx, u.dx * v.dx + u.dy * v.dy)
        }
        let from = CGVector(dx: (x1 - cx1) / rx, dy: (y1 - cy1) / ry)
        let to = CGVector(dx: (-x1 - cx1) / rx, dy: (-y1 - cy1) / ry)
        let theta = angle(CGVector(dx: 1, dy: 0), from)
        var delta = angle(from, to)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        func point(onUnitCircle u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + rx * u * cosPhi - ry * v * sinPhi,
                y: center.y + rx * u * sinPhi + ry * v * cosPhi)
        }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(segments)
        let handle = 4 / 3 * tan(step / 4)
        for index in 0..<segments {
            let a = theta + step * CGFloat(index)
            let b = a + step
            let isLast = index == segments - 1
            path.addCurve(
                to: isLast ? end : point(onUnitCircle: cos(b), sin(b)),
                control1: point(onUnitCircle: cos(a) - handle * sin(a), sin(a) + handle * cos(a)),
                control2: point(onUnitCircle: cos(b) + handle * sin(b), sin(b) - handle * cos(b)))
        }
    }
}

private extension SVGPath {
    struct Builder {
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero

        /// Draws one command's worth of arguments. Returns the command that implicit repetition
        /// continues with (a moveto continues as a lineto), or nil on malformed data.
        mutating func apply(_ command: UInt8, from scanner: inout Scanner) -> UInt8? {
            let isRelative = command >= UInt8(ascii: "a")
            let origin = isRelative ? current : .zero
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }

            switch command | 0x20 { // lowercased
            case UInt8(ascii: "m"):
                guard let target = point() else { return nil }
                path.move(to: target)
                current = target
                subpathStart = target
                return isRelative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let target = point() else { return nil }
                path.addLine(to: target)
                current = target
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return nil }
                current = CGPoint(x: origin.x + x, y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return nil }
                current = CGPoint(x: current.x, y: origin.y + y)
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let control1 = point(), let control2 = point(), let target = point() else { return nil }
                path.addCurve(to: target, control1: control1, control2: control2)
                current = target
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let largeArc = scanner.flag(), let sweep = scanner.flag(), let target = point()
                else { return nil }
                SVGPath.addArc(
                    to: &path, from: current, to: target, radii: CGSize(width: rx, height: ry),
                    rotation: rotation, largeArc: largeArc, sweep: sweep)
                current = target
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = subpathStart
            default:
                return nil
            }
            return command
        }
    }

    /// Tokenises path data: command letters, numbers and arc flags.
    struct Scanner {
        private let bytes: [UInt8]
        private var index = 0

        init(_ text: String) { bytes = Array(text.utf8) }

        var isAtEnd: Bool { index >= bytes.count }

        mutating func command() -> UInt8? {
            skipSeparators()
            guard let byte = peek, Self.isLetter(byte) else { return nil }
            index += 1
            return byte
        }

        mutating func hasNumber() -> Bool {
            skipSeparators()
            guard let byte = peek else { return false }
            return Self.isDigit(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".")
        }

        mutating func number() -> CGFloat? {
            guard hasNumber() else { return nil }
            let start = index
            if peek == UInt8(ascii: "-") || peek == UInt8(ascii: "+") { index += 1 }
            var sawDigit = false, sawDot = false
            while let byte = peek {
                if Self.isDigit(byte) {
                    sawDigit = true
                } else if byte == UInt8(ascii: "."), !sawDot {
                    sawDot = true
                } else {
                    break
                }
                index += 1
            }
            if sawDigit, peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
                index += 1
                if peek == UInt8(ascii: "-") || peek == UInt8(ascii: "+") { index += 1 }
                while let byte = peek, Self.isDigit(byte) { index += 1 }
            }
            guard sawDigit, let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else { return nil }
            return CGFloat(value)
        }

        /// Arc flags are a single 0 or 1 and may be written without separators (`a2 2 0 001 2 2`).
        mutating func flag() -> Bool? {
            skipSeparators()
            guard let byte = peek, byte == UInt8(ascii: "0") || byte == UInt8(ascii: "1") else { return nil }
            index += 1
            return byte == UInt8(ascii: "1")
        }

        private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        private mutating func skipSeparators() {
            while let byte = peek, byte == UInt8(ascii: " ") || byte == UInt8(ascii: ",") || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            }
        }

        private static func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

        private static func isLetter(_ byte: UInt8) -> Bool { (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z") }
    }
}
