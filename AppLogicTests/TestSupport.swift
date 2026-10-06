import Foundation
import JQEngine
import XCTest
#if canImport(AppCore)
@testable import AppCore
#endif

/// AppLogicTests is host-less and compiles Shared/Core straight into the test
/// bundle (see project.yml), so these tests call the same code the app, the
/// share extension and the controls extension run.

extension XCTestCase {
    /// A fresh App Group container for one test, removed afterwards.
    func useTemporaryContainer() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLogicTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        AppGroup.containerOverride = url
        addTeardownBlock {
            AppGroup.containerOverride = nil
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func run(_ filter: String, _ input: String, arguments: String? = nil, slurp: Bool = false,
             timeout: Double = 10, context: RunContext = .background, canRunInApp: Bool = true,
             resultLimit: Int? = nil, collectMessages: Bool = false) async -> FilterOutcome {
        await FilterRunner.run(FilterRequest(
            filter: filter,
            input: Data(input.utf8),
            argumentsText: arguments,
            slurp: slurp,
            timeout: timeout,
            context: context,
            canRunInApp: canRunInApp,
            collectMessages: collectMessages,
            resultLimit: resultLimit
        ))
    }

    func texts(_ results: [JSON]) -> [String] {
        results.map { JSONWriter.string($0) }
    }
}

private final class BundleToken {}

enum TestContent {
    /// The bundled content files: from the test bundle when the build copied
    /// them there, otherwise from App/Resources in the repository.
    static let library: ContentLibrary = {
        let bundle = Bundle(for: BundleToken.self)
        if bundle.url(forResource: "Presets", withExtension: "json") != nil {
            return ContentLibrary(bundle: bundle)
        }
        let resources = URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Resources", isDirectory: true)
        return ContentLibrary(directory: resources)
    }()
}
