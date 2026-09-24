import AppKit
import WebKit

struct CustomWidgetPackage: Codable, Equatable {
    var version = 1
    var name: String
    var html: String
    var css: String
    var height: Double = 190
    static let starter = CustomWidgetPackage(
        name: "Violet pulse",
        html: """
            <section class="card">
              <div class="eyebrow">MY AMBIENT SPACE</div>
              <div class="time" data-ambient="time"></div>
              <div class="usage">CPU <b data-ambient="cpu"></b> · RAM <b data-ambient="memory"></b></div>
              <div class="track"><div class="fill"></div></div>
            </section>
            """,
        css: """
            .card { margin: 10px; padding: 22px; border-radius: 24px; color: #f5edff;
              background: linear-gradient(135deg, #291a48ed, #100d20ed); border: 1px solid #a984fa66; }
            .eyebrow { font-size: 10px; letter-spacing: 3px; color: #c6a9ff; }
            .time { font-size: 40px; font-weight: 300; margin: 8px 0; }
            .usage { font-size: 12px; }
            .track { height: 4px; margin-top: 16px; background: #ffffff18; border-radius: 3px; }
            .fill { width: var(--cpu); height: 100%; background: #b795ff; border-radius: inherit; }
            """)
    func validated() throws -> CustomWidgetPackage {
        guard version == 1 else {
            throw ImportFailure.message("This widget uses an unsupported package version.")
        }
        guard html.utf8.count + css.utf8.count <= 262_144, name.count <= 120,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            height.isFinite, (80...600).contains(height)
        else {
            throw ImportFailure.message(
                "Use a name, HTML/CSS under 256 KB, and a height from 80 to 600 points.")
        }
        return self
    }
    var document: String {
        // Content is deliberately offline. No page scripts, remote resources, frames or file access.
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style>html,body{margin:0;background:transparent;color:white;font-family:system-ui;overflow:hidden}*{box-sizing:border-box}</style>
        <style>\(css)</style></head><body>\(html)</body></html>
        """
    }
}

@MainActor final class CustomWidgetHost: NSObject, WKNavigationDelegate {
    let view: WKWebView
    private(set) var ready = false
    private var updating = false
    private var failed = false
    private var didLoadInitialDocument = false
    var error: ((String) -> Void)?
    var onReady: (() -> Void)?
    init(package: CustomWidgetPackage, size: NSSize, scale: Double) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        view = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        super.init()
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.pageZoom = scale
        view.loadHTMLString(package.document, baseURL: nil)
    }
    func update(_ readings: SystemReadings) {
        guard ready, !updating, !failed else { return }
        updating = true
        let values: [String: String] = [
            "time": readings.date.formatted(date: .omitted, time: .shortened),
            "date": readings.date.formatted(date: .complete, time: .omitted),
            "cpu": readings.cpuText, "memory": readings.memoryText,
            "download": readings.downloadText, "upload": readings.uploadText,
        ]
        view.callAsyncJavaScript(
            """
            for (const node of document.querySelectorAll('[data-ambient]')) {
              const value = values[node.getAttribute('data-ambient')];
              if (value !== undefined && node.textContent !== value) node.textContent = value;
            }
            document.documentElement.style.setProperty('--cpu', cpu + '%');
            document.documentElement.style.setProperty('--memory', memory + '%');
            return true;
            """,
            arguments: [
                "values": values, "cpu": readings.cpu ?? 0, "memory": readings.memoryPercent,
            ], in: nil, in: .defaultClient
        ) { [weak self] result in
            self?.updating = false
            if case .failure(let error) = result {
                self?.failed = true
                self?.error?("Custom widget update failed: \(error.localizedDescription)")
            }
        }
    }
    func stop() {
        ready = false
        onReady = nil
        view.stopLoading()
        view.navigationDelegate = nil
        view.removeFromSuperview()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        onReady?()
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let allow =
            !didLoadInitialDocument && action.navigationType == .other
            && action.targetFrame?.isMainFrame == true
            && action.request.url?.absoluteString == "about:blank"
        if allow { didLoadInitialDocument = true }
        decisionHandler(allow ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        error?("The custom widget stopped. Apply its code again to reload it.")
    }
}
