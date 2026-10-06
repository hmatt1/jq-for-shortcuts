import Foundation

/// Where a run happens. Each place has its own limits (R7.7).
enum RunContext: String, Sendable, Codable {
    /// A Shortcuts action running without the app on screen. iOS ends these
    /// after about 30 seconds.
    case background
    /// A Shortcuts action with Run in App on, or the clipboard runner.
    case foreground
    /// A live Playground run while the person types.
    case playground
    /// The share extension, which has a much smaller memory budget.
    case shareExtension
}

/// The limits from R2.6, R3.16, R9.5 and R9.6. The design marks these values
/// as placeholders until they are measured on a device, so they all live here.
enum RunLimits {
    static let megabyte = 1 << 20

    /// R2.6: inputs above this stop a background run with the large-input error.
    static let backgroundInputLimit = 50 * megabyte
    /// The largest input the app takes while it is on screen.
    static let foregroundInputLimit = 250 * megabyte
    /// The share extension runs inside a small memory budget.
    static let shareExtensionInputLimit = 10 * megabyte

    /// R3.16 default.
    static let defaultTimeout: Double = 10
    /// The longest Timeout the action accepts.
    static let maximumTimeout: Double = 600
    /// iOS ends a background action at about 30 seconds. Stopping a little
    /// earlier leaves time to return a readable error instead.
    static let backgroundTimeCap: Double = 25

    /// The Playground lists at most this many results and stops the run there.
    static let playgroundResultLimit = 5_000
    /// Inputs above this open in the Playground without the tree browser.
    static let treeBrowserInputLimit = 10 * megabyte
    /// Inputs above this open read-only in the Playground, without the text editor.
    static let editableInputLimit = 2 * megabyte
    /// Saved Filters keep a sample input of at most this size (R1.3).
    static let sampleInputLimit = 5 * megabyte

    /// Parsed JSON takes several times the size of its text (R9.9).
    static let parsedSizeFactor = 6

    /// The timeout a run gets in `context`, and whether it was shortened to
    /// fit the background time limit.
    static func effectiveTimeout(requested: Double, context: RunContext) -> (seconds: Double, capped: Bool) {
        let clamped = min(max(requested.isFinite ? requested : defaultTimeout, 1), maximumTimeout)
        if context == .background, clamped > backgroundTimeCap {
            return (backgroundTimeCap, true)
        }
        return (clamped, false)
    }

    static func inputLimit(for context: RunContext) -> Int {
        switch context {
        case .background: return backgroundInputLimit
        case .foreground, .playground: return foregroundInputLimit
        case .shareExtension: return shareExtensionInputLimit
        }
    }

    /// R9.6: how much the process may grow during one run. It is the smaller
    /// of a fixed cap for the context and half of the memory the process may
    /// still allocate, so a run stops with an error well before iOS would end
    /// the process.
    static func memoryLimit(for context: RunContext) -> UInt64 {
        let fixedCap: UInt64
        switch context {
        case .background: fixedCap = 600 << 20
        case .foreground, .playground: fixedCap = 1536 << 20
        case .shareExtension: fixedCap = 48 << 20
        }
        guard let available = MemoryProbe.availableBytes() else { return fixedCap }
        return max(24 << 20, min(fixedCap, available / 2))
    }

    /// R9.9: whether an input of `bytes` would likely exhaust memory once
    /// parsed. Nil when the platform cannot say how much memory is left.
    static func inputLikelyExceedsMemory(bytes: Int) -> Bool {
        guard let available = MemoryProbe.availableBytes() else { return false }
        return UInt64(bytes) * UInt64(parsedSizeFactor) > available
    }
}

/// "82 MB" style sizes for messages.
enum ByteCount {
    static func describe(_ bytes: Int) -> String {
        let megabyte = Double(RunLimits.megabyte)
        if Double(bytes) >= megabyte {
            let value = Double(bytes) / megabyte
            if value >= 10 {
                return String(localized: "\(Int(value.rounded())) MB")
            }
            return String(localized: "\(String(format: "%.1f", value)) MB")
        }
        if bytes >= 1024 {
            return String(localized: "\(Int((Double(bytes) / 1024).rounded())) KB")
        }
        return String(localized: "\(bytes) bytes")
    }
}
