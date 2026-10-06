import SwiftUI

/// The progress screen for an action with Run in App on (R3.34). The
/// shortcut gets its result as soon as the run ends; this screen then shows
/// how it ended and offers the way back to Shortcuts.
struct RunInAppView: View {
    @Environment(\.openURL) private var openURL
    let progress: ActionRunProgress

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            switch progress.phase {
            case .running:
                ProgressView()
                    .controlSize(.large)
                Text("Running \(progress.actionName)")
                    .font(.title3.weight(.semibold))
                TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
                    Text("\(Int(context.date.timeIntervalSince(progress.startedAt))) s · \(ByteCount.describe(progress.inputBytes)) input")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            case .finished(let succeeded, let message):
                Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(succeeded ? .green : .red)
                    .accessibilityHidden(true)
                Text(succeeded ? "Done. The result went back to your shortcut." : "The run failed.")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
            }
            Text(progress.filterPreview)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .padding(.horizontal)
            Spacer()
            switch progress.phase {
            case .running:
                Button("Cancel Run", role: .destructive) {
                    progress.cancel()
                }
                .buttonStyle(.bordered)
            case .finished:
                Button {
                    if let url = URL(string: "shortcuts://") {
                        openURL(url)
                    }
                } label: {
                    Label("Back to Shortcuts", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .interactiveDismissDisabled(progress.phase == .running)
    }
}
