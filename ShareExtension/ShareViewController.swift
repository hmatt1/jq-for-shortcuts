import SwiftUI
import UIKit

/// The share sheet entry point (R7.1, R7.2): Open in Playground, or Run
/// Saved Filter with the result and a Copy button.
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(
            items: extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? [],
            openApp: { [weak self] url in self?.openContainingApp(url) ?? false },
            complete: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        )
        self.model = model

        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        Task { await model.load() }
    }

    /// The sheet can also be swiped away, which skips Done.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model?.removeTemporaryCopy()
    }

    /// Share extensions have no direct API to open their app. The responder
    /// chain still reaches the UIApplication object, whose openURL method is
    /// called through the Objective-C runtime because the Swift API is
    /// marked unavailable in extensions. Returns false when that fails, and
    /// the shared input waits in the inbox until the app opens.
    private func openContainingApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.isKind(of: UIApplication.self), current.responds(to: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let function = unsafeBitCast(current.method(for: selector), to: OpenURL.self)
                function(current, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }
}
