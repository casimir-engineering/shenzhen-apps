// Standalone OS WKWebView probe. This is not the Tauri release application.
// Build: swiftc scripts/perf/native-webkit-benchmark.swift -o artifacts/perf/native-webkit-benchmark
// Run while Vite is running. PERF_CASES=1,100 adds model scenarios; default probes capabilities/rAF only.
import Cocoa
import WebKit

@MainActor
final class Probe: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var finished = false
    var started = false
    var polls = 0
    let output = ProcessInfo.processInfo.environment["PERF_OUTPUT"] ?? "artifacts/perf/native-webkit-info.json"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "WebKit performance probe")
        appMenu.addItem(withTitle: "Quit WebKit performance probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "System WKWebView performance probe"
        window.minSize = NSSize(width: 400, height: 300)
        window.collectionBehavior.insert(.fullScreenPrimary)
        webView = WKWebView(frame: window.contentView!.bounds)
        webView.autoresizingMask = [.width,.height]
        webView.navigationDelegate = self
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let base = ProcessInfo.processInfo.environment["PERF_BASE_URL"] ?? "http://127.0.0.1:1420"
        webView.load(URLRequest(url: URL(string: base + "/tests/perf/index.html?source=current&timer=1")!))
        Timer.scheduledTimer(withTimeInterval: 900, repeats: false) { _ in
            Task { @MainActor in self.fail("Native WebKit benchmark timed out after 15 minutes") }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pollReady() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error.localizedDescription) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error.localizedDescription) }
    func pollReady() {
        guard !finished && !started else { return }
        polls += 1
        webView.evaluateJavaScript("Boolean(window.bench)") { value,error in
            if let error { self.fail(error.localizedDescription); return }
            if value as? Bool == true { self.runProbe(); return }
            if self.polls > 600 { self.fail("Benchmark module did not initialize"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.pollReady() }
        }
    }
    func runProbe() {
        started = true
        let env = ProcessInfo.processInfo.environment
        let cases = (env["PERF_CASES"] ?? "").split(separator: ",").map(String.init)
        let durationMs = Double(env["PERF_DURATION_MS"] ?? "8000") ?? 8000
        let body = """
        const info = await window.bench.info();
        let model = null;
        const results = [];
        if (cases.length) {
          model = await window.bench.load();
          for (const scenario of cases) {
            const unique = scenario.startsWith('unique');
            const copies = Number(scenario.replace('unique',''));
            results.push(await window.bench.run({copies,unique,durationMs}));
          }
        }
        return JSON.stringify({engine:'standalone system WKWebView (not Tauri release)',recordedAt:new Date().toISOString(),...info,model,cases:results});
        """
        webView.callAsyncJavaScript(body, arguments: ["cases":cases,"durationMs":durationMs], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                guard let json = value as? String, let data = json.data(using: .utf8) else { self.fail("WebKit returned no JSON result"); return }
                do {
                    let url = URL(fileURLWithPath: self.output)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    print(json)
                    self.finished = true
                    NSApp.terminate(nil)
                } catch { self.fail(error.localizedDescription) }
            case .failure(let error): self.fail(error.localizedDescription)
            }
        }
    }
    func fail(_ message: String) {
        guard !finished else { return }
        finished = true
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let probe = Probe()
    app.setActivationPolicy(.regular)
    app.delegate = probe
    withExtendedLifetime(probe) { app.run() }
}
