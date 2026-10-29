import Foundation

/// Localization lookup with an in-app language override. The app defaults to
/// Russian; the user can switch to English or follow the system language.
public enum L10n {
    public enum Language: String, CaseIterable, Sendable {
        case system
        case russian = "ru"
        case english = "en"
    }

    /// Set once at startup and whenever the user changes the setting.
    public private(set) static var language: Language = .russian

    private static var overrideBundle: Bundle?
    /// SwiftPM's generated `Bundle.module` accessor expects the resource
    /// bundle beside the executable when the app is assembled without Xcode.
    /// A signed macOS app must keep resources under `Contents/Resources`, so
    /// prefer that standard location and retain Bundle.module for `swift run`.
    private static let resourceBundle: Bundle = {
        let name = "VoxLocal_VoxLocalCore.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return Bundle.module
    }()

    public static func setLanguage(_ lang: Language) {
        language = lang
        switch lang {
        case .system:
            overrideBundle = nil
        case .russian, .english:
            if let path = resourceBundle.path(forResource: lang.rawValue, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                overrideBundle = bundle
            } else {
                overrideBundle = nil
            }
        }
    }

    public static func t(_ key: String) -> String {
        let bundle = overrideBundle ?? resourceBundle
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    public static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: args)
    }
}
