import Foundation

/// Settings in the App Group's defaults. The Playground's input is not among
/// them: the app keeps no input unless input history is on (R2.11).
enum AppSettings {
    enum Key {
        static let inputHistoryEnabled = "inputHistoryEnabled"
        static let galleryOfferShown = "galleryOfferShown"
    }

    /// R9.5: input history is off until the person turns it on.
    static var inputHistoryEnabled: Bool {
        get { AppGroup.defaults.bool(forKey: Key.inputHistoryEnabled) }
        set { AppGroup.defaults.set(newValue, forKey: Key.inputHistoryEnabled) }
    }

    /// R1.5: the gallery is offered once, after the first save.
    static var galleryOfferShown: Bool {
        get { AppGroup.defaults.bool(forKey: Key.galleryOfferShown) }
        set { AppGroup.defaults.set(newValue, forKey: Key.galleryOfferShown) }
    }
}
