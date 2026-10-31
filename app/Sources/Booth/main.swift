import AppKit
import BoothCore

let options = LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))

MainActor.assumeIsolated {
    Log.info("Booth \(AppInfo.version) pid \(ProcessInfo.processInfo.processIdentifier): \(CommandLine.arguments.joined(separator: " "))")
    for problem in options.problems { Log.error("launch arguments: \(problem)") }

    if options.isHeadless {
        let status = runHeadless(options)
        Log.flush()
        exit(status)
    }

    if options.motionProbe { MotionProbe.run() }

    let app = NSApplication.shared
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

/// Modes that do their job and exit without starting the menu bar app.
@MainActor
private func runHeadless(_ options: LaunchOptions) -> Int32 {
    if let directory = options.renderStatesDirectory {
        _ = NSApplication.shared
        BundledFonts.registerIfNeeded()
        return SnapshotRenderer.run(outputDir: directory)
    }
    if let directory = options.renderGlyphsDirectory {
        _ = NSApplication.shared
        return GlyphRenderer.renderAll(to: directory)
    }
    if let directory = options.renderDemoDirectory {
        _ = NSApplication.shared
        BundledFonts.registerIfNeeded()
        return DemoRenderer.run(outputDir: directory)
    }
    if let input = options.selfTestInput {
        return EngineSelfTest.run(input: input, engineName: options.selfTestEngineName, enginePath: options.enginePath)
    }
    return 0
}
