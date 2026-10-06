import Foundation
#if canImport(os)
import os
#endif

/// The App Group shared by the app, the share extension and the controls
/// extension. Saved Filters, input history and settings live in its container,
/// so every entry point reads the same store (R7.5).
enum AppGroup {
    /// The tail that survives re-signing. Sideloading tools prefix the group
    /// with an account-specific token, so matching on the suffix finds it.
    private static let expectedSuffix = "com.hmatt1.jqforshortcuts"

    /// Optional build-time override: set `APP_GROUP_ID` in Info.plist when
    /// building with a different team.
    private static let infoPlistKey = "APP_GROUP_ID"

    #if canImport(os)
    private static let log = Logger(subsystem: "com.hmatt1.jqforshortcuts", category: "AppGroup")
    #endif

    /// The resolved, entitled group identifier, or nil when none is usable.
    static let identifier: String? = resolve()

    /// Overrides the container in tests.
    nonisolated(unsafe) static var containerOverride: URL?

    /// The shared container. Falls back to this process's Application
    /// Support directory when no group is entitled, so a build signed without
    /// the group still works on its own.
    static var containerURL: URL {
        if let containerOverride {
            return containerOverride
        }
        #if canImport(Darwin)
        if let identifier,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        #endif
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JQForShortcuts", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static var defaults: UserDefaults {
        if containerOverride == nil, let identifier, let shared = UserDefaults(suiteName: identifier) {
            return shared
        }
        return .standard
    }

    private static func resolve() -> String? {
        #if canImport(Darwin)
        var candidates: [String] = []
        if let override = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String, !override.isEmpty {
            candidates.append(override)
        }
        candidates.append("group." + expectedSuffix)
        let provisioned = provisionedAppGroups()
        candidates.append(contentsOf: provisioned.filter { $0.hasSuffix(expectedSuffix) })
        candidates.append(contentsOf: provisioned)

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) != nil {
                log.info("Resolved app group: \(candidate, privacy: .public)")
                return candidate
            }
        }
        log.error("No usable app group. Profile listed: \(provisioned, privacy: .public)")
        #endif
        return nil
    }

    /// App groups in this bundle's provisioning profile. In an extension,
    /// `Bundle.main` is the .appex, which carries its own profile.
    private static func provisionedAppGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<plist".utf8))?.lowerBound,
              let end = data.range(of: Data("</plist>".utf8), options: .backwards)?.upperBound,
              start < end,
              let plist = try? PropertyListSerialization.propertyList(from: data[start..<end], options: [], format: nil)
                as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else {
            return []
        }
        return groups
    }
}
