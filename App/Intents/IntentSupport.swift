import AppIntents
import Foundation
import JQEngine
import UniformTypeIdentifiers

/// Shortcuts shows an error's localized string resource in its alert, so
/// every action failure carries its R8 wording.
extension FilterError: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        "\(message)"
    }
}

/// The output modes as Shortcuts shows them (R3.12).
enum OutputModeOption: String, AppEnum {
    case itemPerResult
    case jsonArray
    case rawLines
    case compactJSON
    case prettyJSON

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Output Mode")

    static let caseDisplayRepresentations: [OutputModeOption: DisplayRepresentation] = [
        .itemPerResult: DisplayRepresentation(title: "One item per result"),
        .jsonArray: DisplayRepresentation(title: "One JSON array"),
        .rawLines: DisplayRepresentation(title: "Raw text lines"),
        .compactJSON: DisplayRepresentation(title: "Compact JSON"),
        .prettyJSON: DisplayRepresentation(title: "Pretty JSON"),
    ]

    var mode: OutputMode {
        OutputMode(rawValue: rawValue) ?? .itemPerResult
    }

    init(_ mode: OutputMode) {
        self = OutputModeOption(rawValue: mode.rawValue) ?? .itemPerResult
    }
}

/// Names the kind of content that cannot be read as JSON, for R8.4.
enum InputKinds {
    /// "an image", "a PDF"..., or nil when the type may hold JSON text.
    static func unreadableKind(for type: UTType) -> String? {
        if type.conforms(to: .json) || type.conforms(to: .text) || type.conforms(to: .propertyList) {
            return nil
        }
        if type.conforms(to: .image) { return String(localized: "an image") }
        if type.conforms(to: .pdf) { return String(localized: "a PDF") }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return String(localized: "a video") }
        if type.conforms(to: .audio) { return String(localized: "audio") }
        if type.conforms(to: .archive) { return String(localized: "an archive") }
        if type.conforms(to: .spreadsheet) { return String(localized: "a spreadsheet") }
        if type.conforms(to: .presentation) { return String(localized: "a presentation") }
        if type.conforms(to: .font) { return String(localized: "a font") }
        if type.conforms(to: .contact) { return String(localized: "a contact") }
        if type.conforms(to: .calendarEvent) { return String(localized: "a calendar event") }
        if type.conforms(to: .executable) { return String(localized: "an app or program") }
        return nil
    }
}

/// Reads action parameters into the bytes the engine runs on (R2.1, R2.2).
///
/// Every Input parameter lists `supportedContentTypes: [.json, .plainText,
/// .text, .data]` as a literal, since App Intents reads parameter options at
/// build time. JSON comes first so Shortcuts hands dictionaries over as JSON,
/// text covers Text values, and data lets any other file through, so the
/// action can say what it is (R8.4) instead of Shortcuts refusing it.
enum IntentInput {
    /// `allowEmpty` is for the filter actions: an empty variable runs the
    /// filter on no values and returns nothing, as an empty input does (R2.3).
    static func data(from files: [IntentFile], context: RunContext, canRunInApp: Bool,
                     allowEmpty: Bool = false) throws -> Data {
        if files.isEmpty {
            if allowEmpty { return Data() }
            throw FilterError.emptyInput
        }
        let limit = RunLimits.inputLimit(for: context)
        var parts: [Data] = []
        var total = 0
        for file in files {
            if let type = file.type, let kind = InputKinds.unreadableKind(for: type) {
                throw FilterError.unreadableInput(kind: kind)
            }
            // R9.9: check the size before reading a file into memory.
            if let url = file.fileURL,
               let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               total + size > limit {
                throw FilterError.inputTooLarge(bytes: total + size, limit: limit, context: context, canRunInApp: canRunInApp)
            }
            let data = InputAssembler.normalizePropertyList(file.data)
            total += data.count
            parts.append(data)
        }
        return try InputAssembler.assemble(parts)
    }

    /// A Shortcuts value as one JSON value: JSON as it is, other text as a string.
    static func jsonValue(from files: [IntentFile]) throws -> JSON {
        try InputAssembler.jsonValue(from: files.map { InputAssembler.normalizePropertyList($0.data) })
    }

    /// Timeout in seconds, kept within what the action accepts.
    static func timeout(_ seconds: Int) -> Double {
        min(max(Double(seconds), 1), RunLimits.maximumTimeout)
    }
}

/// Runs filters for the Run JSON Filter and Run Saved Filter actions: in the
/// background, or in the app with a progress screen (R3.34), and records
/// input history when it is on (R9.5).
enum ActionRunner {
    static func run(_ request: FilterRequest, actionName: String, outputMode: OutputMode,
                    showProgress: Bool) async -> FilterOutcome {
        let outcome: FilterOutcome
        if showProgress {
            outcome = await runWithProgress(request, actionName: actionName)
        } else {
            outcome = await FilterRunner.run(request)
        }
        InputHistoryStore.shared.record(
            actionName: actionName,
            filter: request.filter,
            argumentsJSON: request.argumentsText,
            outputMode: outputMode,
            input: request.input,
            errorMessage: outcome.error?.message
        )
        return outcome
    }

    private static func runWithProgress(_ request: FilterRequest, actionName: String) async -> FilterOutcome {
        let progress = await MainActor.run {
            AppModel.shared.beginActionRun(actionName: actionName, filter: request.filter, inputBytes: request.input.count)
        }
        let task = Task.detached(priority: .userInitiated) {
            await FilterRunner.run(request)
        }
        await MainActor.run {
            progress.onCancel = { task.cancel() }
        }
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        await MainActor.run {
            AppModel.shared.finishActionRun(progress, outcome: outcome)
        }
        return outcome
    }
}

extension AppIntent {
    /// Brings the app forward for Run in App (R3.34). Returns false when the
    /// system could not, in which case the run continues in the background.
    func continueInAppIfRequested(_ requested: Bool) async -> Bool {
        guard requested else { return false }
        do {
            try await continueInForeground(alwaysConfirm: false)
            return true
        } catch {
            return false
        }
    }
}
