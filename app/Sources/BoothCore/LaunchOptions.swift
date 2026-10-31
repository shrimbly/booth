import Foundation

/// Command-line flags of the Booth binary (SPEC §2.1). Unknown arguments are kept in
/// `unrecognized` rather than rejected: macOS adds its own (`-psn_…`, `-NSDocumentRevisionsDebugMode YES`).
public struct LaunchOptions: Equatable, Sendable {
    /// `--demo`: simulated engine, no Python needed.
    public var demo = false
    /// `--open`: show the popover right after launch.
    public var openAtLaunch = false
    /// `--enqueue PATH…`
    public var enqueue: [URL] = []
    /// `--engine PATH`: engine executable override.
    public var enginePath: String?
    /// `--reset-defaults`
    public var resetDefaults = false
    /// `--render-states DIR`: write popover snapshots and exit.
    public var renderStatesDirectory: URL?
    /// `--render-glyphs DIR`: write menu bar glyph images and exit.
    public var renderGlyphsDirectory: URL?
    /// `--render-demo DIR`: write the frames of the website's demo video and exit.
    public var renderDemoDirectory: URL?
    /// `--motion-probe`: play the popover's transitions in a window for recording, then quit.
    public var motionProbe = false
    /// `--selftest-engine PATH`: run one real job on PATH headlessly and exit.
    public var selfTestInput: URL?
    /// `--selftest-engine-name sidon|mossformer2|df3` (default sidon).
    public var selfTestEngineName = EngineChoice.studio.engineName
    /// `--selftest-cancel-after SECONDS`: cancel the self-test job after this long, to exercise
    /// the cancel path.
    public var selfTestCancelAfter: Double?
    /// `--selftest-remix`: after the self-test job, re-save it at a different mix.
    public var selfTestRemix = false
    public var unrecognized: [String] = []
    /// Human-readable problems (a flag missing its value). Launch continues regardless.
    public var problems: [String] = []

    public init() {}

    /// The app runs headless and exits instead of starting the menu bar UI.
    public var isHeadless: Bool {
        renderStatesDirectory != nil || renderGlyphsDirectory != nil || renderDemoDirectory != nil || selfTestInput != nil
    }

    /// Parses arguments without the executable path (`CommandLine.arguments.dropFirst()`).
    /// Relative paths resolve against `currentDirectory`; `--flag=value` works too.
    public static func parse(_ arguments: [String], currentDirectory: String = FileManager.default.currentDirectoryPath) -> LaunchOptions {
        var options = LaunchOptions()
        var remaining = arguments.flatMap(splitInlineValue)[...]

        func fileURL(_ path: String) -> URL {
            let expanded = (path as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
            return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true))
                .standardizedFileURL
        }

        func value(for flag: String) -> String? {
            guard let next = remaining.first, !next.hasPrefix("-") else {
                options.problems.append("\(flag) needs a value")
                return nil
            }
            remaining.removeFirst()
            return next
        }

        while let argument = remaining.popFirst() {
            switch argument {
            case "--demo":
                options.demo = true
            case "--open":
                options.openAtLaunch = true
            case "--reset-defaults":
                options.resetDefaults = true
            case "--motion-probe":
                options.motionProbe = true
            case "--enqueue":
                var paths: [String] = []
                while let next = remaining.first, !next.hasPrefix("-") {
                    paths.append(next)
                    remaining.removeFirst()
                }
                if paths.isEmpty { options.problems.append("--enqueue needs at least one path") }
                options.enqueue += paths.map(fileURL)
            case "--engine":
                if let path = value(for: argument) { options.enginePath = fileURL(path).path }
            case "--render-states":
                if let path = value(for: argument) { options.renderStatesDirectory = directoryURL(fileURL(path)) }
            case "--render-glyphs":
                if let path = value(for: argument) { options.renderGlyphsDirectory = directoryURL(fileURL(path)) }
            case "--render-demo":
                if let path = value(for: argument) { options.renderDemoDirectory = directoryURL(fileURL(path)) }
            case "--selftest-engine":
                if let path = value(for: argument) { options.selfTestInput = fileURL(path) }
            case "--selftest-cancel-after":
                guard let text = value(for: argument) else { break }
                if let seconds = Double(text), seconds >= 0 {
                    options.selfTestCancelAfter = seconds
                } else {
                    options.problems.append("--selftest-cancel-after needs a number of seconds, not \(text)")
                }
            case "--selftest-remix":
                options.selfTestRemix = true
            case "--selftest-engine-name":
                guard let name = value(for: argument) else { break }
                if EngineChoice(engineName: name) != nil {
                    options.selfTestEngineName = name
                } else {
                    options.problems.append("unknown engine \(name); expected sidon, mossformer2 or df3")
                }
            default:
                options.unrecognized.append(argument)
            }
        }
        return options
    }

    /// `--flag=value` → `["--flag", "value"]`; everything else unchanged.
    private static func splitInlineValue(_ argument: String) -> [String] {
        guard argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") else { return [argument] }
        return [String(argument[..<equals]), String(argument[argument.index(after: equals)...])]
    }

    private static func directoryURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: true)
    }
}
