import JQEngine
import SwiftUI

/// Version, privacy, and the attributions for the engine (R9.14).
struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(marketing) (\(build))"
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: version)
                LabeledContent("Filter language", value: "jq \(JQ.compatibleVersion)")
            }
            Section("Privacy") {
                Text("JQ for Shortcuts collects no data. Filters run on this device, and the app has no accounts and makes no network requests.")
                Link("Privacy Policy", destination: URL(string: "https://hmatt1.github.io/jq-for-shortcuts/")!)
                Link("Support", destination: URL(string: "https://hmatt1.github.io/jq-for-shortcuts/support/")!)
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("jq")
                        .font(.headline)
                    Text("The filter engine is a Swift implementation of the jq language. Its built-in function definitions are adapted from jq's builtin.jq, and it is tested against jq's own test suite.")
                        .font(.callout)
                    Text(Self.jqLicense)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Acknowledgements")
            }
        }
        .navigationTitle("About")
    }

    static let jqLicense = """
    jq is copyright (C) 2012 Stephen Dolan

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}
