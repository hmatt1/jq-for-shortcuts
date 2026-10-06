import Foundation
import JQEngine
import Observation
import UIKit

/// App-wide state: the selected tab, the Playground, and requests that come
/// from intents, controls, links and the share sheet.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Tab: Hashable {
        case playground
        case library
        case reference
    }

    var selectedTab: Tab = .playground
    let playground = PlaygroundModel()
    let content = ContentLibrary.shared

    /// The one sheet over the tabs. A new sheet replaces the one showing.
    var sheet: AppSheet?
    /// An action running with Run in App on (R3.34).
    var activeRun: ActionRunProgress?
    /// R1.5: offered once, after the first save.
    var isGalleryOfferPresented = false
    /// Views that present their own sheets, dialogs or pickers close them
    /// when this changes, so a control or Run in App can show its screen.
    private(set) var dismissalGeneration = 0

    /// R9.5. Kept here so the views that offer recent runs update as soon as
    /// Settings changes it.
    var isInputHistoryEnabled: Bool {
        get { inputHistoryEnabledStorage }
        set {
            inputHistoryEnabledStorage = newValue
            AppSettings.inputHistoryEnabled = newValue
            if !newValue {
                InputHistoryStore.shared.clear()
            }
        }
    }
    private var inputHistoryEnabledStorage = AppSettings.inputHistoryEnabled

    private init() {}

    /// Intents can run before any window exists, so the handler is installed
    /// from `App.init()`.
    func installIntentNavigation() {
        IntentNavigation.handler = { [weak self] destination in
            self?.open(destination)
        }
    }

    func open(_ destination: AppDestination) {
        switch destination {
        case .playground:
            selectedTab = .playground
        case .library:
            selectedTab = .library
        case .reference:
            selectedTab = .reference
        case .clipboardRunner(let id):
            presentOverEverything { [weak self] in
                self?.sheet = .clipboardRunner(ClipboardRequest(savedFilterID: id))
            }
        case .sharedInput:
            presentOverEverything { [weak self] in
                self?.loadSharedInput()
            }
        }
    }

    /// Shows a screen that a control or a Run in App action asked for. UIKit
    /// shows one modal at a time, so whatever is open closes first.
    private func presentOverEverything(_ present: @escaping @MainActor () -> Void) {
        let wasPresenting = Self.isPresentingModal
        sheet = nil
        isGalleryOfferPresented = false
        dismissalGeneration &+= 1
        guard wasPresenting else {
            present()
            return
        }
        Task { @MainActor in
            // Long enough for the dismissal animation to finish.
            try? await Task.sleep(nanoseconds: 700_000_000)
            present()
        }
    }

    private static var isPresentingModal: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.rootViewController?.presentedViewController != nil }
    }

    func handle(url: URL) {
        if let destination = AppDestination(url: url) {
            open(destination)
        }
    }

    /// Picks up requests left by other processes while the app was away.
    func becameActive() {
        if let pending = PendingNavigation.take() {
            open(pending)
        }
        if PlaygroundInbox.hasItem {
            open(.sharedInput)
        }
    }

    @ObservationIgnored private var isTakingSharedInput = false

    private func loadSharedInput() {
        selectedTab = .playground
        guard !isTakingSharedInput else { return }
        isTakingSharedInput = true
        Task { @MainActor [weak self] in
            // The file can be large, so it is read off the main thread.
            let item = await Task.detached(priority: .userInitiated) { PlaygroundInbox.take() }.value
            self?.isTakingSharedInput = false
            if let item {
                self?.playground.loadInput(item.data, name: item.name)
            }
        }
    }

    // MARK: Opening content in the Playground

    func openInPlayground(filter: String, input: String, arguments: String = "", outputMode: OutputMode = .itemPerResult,
                          savedFilterID: UUID? = nil, name: String? = nil) {
        playground.load(filter: filter, input: input, arguments: arguments, outputMode: outputMode,
                        savedFilterID: savedFilterID, name: name)
        sheet = nil
        selectedTab = .playground
    }

    func openSavedFilter(_ filter: SavedFilter) {
        let sample = SavedFilterStore.shared.sampleInput(id: filter.id) ?? ""
        openInPlayground(filter: filter.filter, input: sample, arguments: filter.argumentsJSON,
                         outputMode: filter.outputMode, savedFilterID: filter.id, name: filter.name)
    }

    func openHistoryEntry(_ entry: HistoryEntry) {
        playground.load(filter: entry.filter, input: "", arguments: entry.argumentsJSON, outputMode: entry.outputMode,
                        savedFilterID: nil, name: nil)
        if let data = InputHistoryStore.shared.input(for: entry) {
            playground.loadInput(data, name: nil)
        }
        selectedTab = .playground
    }

    /// R1.5: after the first save, offer the gallery once.
    func didSaveFilter() {
        guard !AppSettings.galleryOfferShown else { return }
        AppSettings.galleryOfferShown = true
        isGalleryOfferPresented = true
    }

    // MARK: Run in App (R3.34)

    func beginActionRun(actionName: String, filter: String, inputBytes: Int) -> ActionRunProgress {
        let progress = ActionRunProgress(actionName: actionName, filterPreview: String(filter.prefix(400)), inputBytes: inputBytes)
        presentOverEverything { [weak self] in
            self?.activeRun = progress
        }
        return progress
    }

    func finishActionRun(_ progress: ActionRunProgress, outcome: FilterOutcome) {
        progress.finish(outcome)
        Task { @MainActor [weak self] in
            // The shortcut continues right away; the result stays on screen
            // long enough to read how the run ended.
            try? await Task.sleep(nanoseconds: outcome.error == nil ? 1_500_000_000 : 4_000_000_000)
            if self?.activeRun === progress {
                self?.activeRun = nil
            }
        }
    }
}

/// Progress of an action running in the app.
@MainActor
@Observable
final class ActionRunProgress: Identifiable {
    enum Phase: Equatable {
        case running
        case finished(succeeded: Bool, message: String?)
    }

    let id = UUID()
    let actionName: String
    let filterPreview: String
    let inputBytes: Int
    let startedAt = Date()
    private(set) var phase: Phase = .running
    private(set) var resultCount = 0
    /// Cancels the run; the action then reports that it was cancelled.
    var onCancel: (() -> Void)?

    init(actionName: String, filterPreview: String, inputBytes: Int) {
        self.actionName = actionName
        self.filterPreview = filterPreview
        self.inputBytes = inputBytes
    }

    func cancel() {
        onCancel?()
    }

    func finish(_ outcome: FilterOutcome) {
        resultCount = outcome.results.count
        phase = .finished(succeeded: outcome.error == nil, message: outcome.error?.message)
    }
}

struct ClipboardRequest: Identifiable, Equatable {
    let id = UUID()
    var savedFilterID: UUID?
}

/// The sheets shown over the tabs.
enum AppSheet: Identifiable, Equatable {
    case settings
    case gallery
    /// A Lock Screen control asked to run a Saved Filter on the clipboard (R7.4).
    case clipboardRunner(ClipboardRequest)

    var id: String {
        switch self {
        case .settings: return "settings"
        case .gallery: return "gallery"
        case .clipboardRunner(let request): return "clipboard-\(request.id)"
        }
    }
}
