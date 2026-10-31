import AppKit
import CoreText

/// The bundled Geist Serif used for the "Booth" signature. Inside Booth.app the font is
/// registered by `ATSApplicationFontsPath`; unbundled runs register it from `app/Resources`.
enum BundledFonts {
    static let signatureFileName = "Fonts/GeistSerif-Regular.ttf"
    static let signatureFamily = "Geist Serif"
    /// Geist Serif ships one upright weight, 400; heavier weights are drawn (`SignatureGlyph`).
    static let signaturePostScriptName = "GeistSerif-Regular"

    /// Makes the signature font available to this process. Safe to call more than once.
    @discardableResult
    static func registerIfNeeded() -> Bool {
        if isSignatureFontAvailable { return true }
        guard let url = AppResources.url(signatureFileName) else {
            Log.error("signature font missing: \(signatureFileName)")
            return false
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            Log.error("could not register \(url.path): \(reason)")
        }
        return isSignatureFontAvailable
    }

    static var isSignatureFontAvailable: Bool {
        let font = CTFontCreateWithName(signaturePostScriptName as CFString, 12, nil)
        return CTFontCopyFamilyName(font) as String == signatureFamily
    }

    /// The signature font for Core Text drawing: Geist Serif, or New York when it could not be
    /// registered.
    static func signatureCTFontOrFallback(size: CGFloat) -> CTFont {
        if let font = signatureCTFont(size: size) { return font }
        let system = NSFont.systemFont(ofSize: size)
        let serif = system.fontDescriptor.withDesign(.serif) ?? system.fontDescriptor
        return NSFont(descriptor: serif, size: size) ?? system
    }

    static func signatureCTFont(size: CGFloat) -> CTFont? {
        guard isSignatureFontAvailable else { return nil }
        return CTFontCreateWithName(signaturePostScriptName as CFString, size, nil)
    }
}
