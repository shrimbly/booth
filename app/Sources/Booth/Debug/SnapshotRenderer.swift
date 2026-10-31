import AppKit
import SwiftUI

/// `--render-states DIR`: renders every `AppModel.Fixture` in light and dark at 2× as
/// `DIR/<fixture>-<light|dark>.png` (SPEC §3.9), using the real popover views over frozen fake
/// models. The views draw a solid glass panel and freeze the signature wave at t = 1300 ms.
@MainActor
enum SnapshotRenderer {
    static func run(outputDir: URL) -> Int32 {
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            Log.error("render-states: cannot create \(outputDir.path): \(error)")
            return 1
        }
        if !BundledFonts.isSignatureFontAvailable {
            Log.error("render-states: Geist Serif is not registered; the signature falls back to New York")
        }
        var failures = 0
        for fixture in AppModel.Fixture.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let name = "\(fixture.rawValue)-\(scheme == .dark ? "dark" : "light").png"
                let url = outputDir.appendingPathComponent(name)
                let model = AppModel.fixture(fixture)
                if model.effectiveScreen != fixture.expectedScreen {
                    Log.error("render-states: \(fixture.rawValue) shows \(model.effectiveScreen.rawValue), expected \(fixture.expectedScreen.rawValue)")
                    failures += 1
                }
                let content = PopoverRootView(model: model, chrome: .snapshot)
                    .environment(\.colorScheme, scheme)
                if writePNG(of: content, to: url) {
                    Log.info("render-states: wrote \(url.path)")
                } else {
                    failures += 1
                    Log.error("render-states: failed to render \(name)")
                }
            }
        }
        return failures == 0 ? 0 : 1
    }

    static func writePNG<Content: View>(of content: Content, to url: URL, scale: CGFloat = 2) -> Bool {
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return false }
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Log.error("render-states: \(url.path): \(error)")
            return false
        }
    }
}
