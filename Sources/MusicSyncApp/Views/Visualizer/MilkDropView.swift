import Support
import SwiftUI
import WebKit

/// MilkDrop presets, rendered by butterchurn (`Resources/Visualizer`) in a web view that the app feeds with the tap's samples.
@Observable @MainActor final class MilkDrop: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// User presets: MilkDrop `.milk` files and butterchurn `.json` files. A `.milk` file is converted on the page
    /// (bundled converter, offline) the first time it loads; the result is kept next to it as `.json`.
    nonisolated static var userFolder: URL { Paths.appSupport("Visualizer Presets") }

    private(set) var presets: [String] = []
    private(set) var current: String?
    /// `.milk` presets the converter could not handle.
    private(set) var failed: [String] = []
    @ObservationIgnored weak var webView: WKWebView?
    /// Hidden copy of the page that compiles the upcoming preset (see `index.html`).
    @ObservationIgnored var warmView: WKWebView?
    /// A title and options sent before the page loaded; applied once it has.
    @ObservationIgnored private var pendingTitle: String?
    @ObservationIgnored private var config = "{}"
    @ObservationIgnored private var loaded = false

    func step(_ by: Int) { run("ms.step(\(by))") }
    func random() { run("ms.random()") }
    func select(_ name: String) { run("ms.select(\(Self.literal(name)))") }

    /// MilkDrop's song title animation: the text flies in and melts into the preset.
    func title(_ text: String, seconds: Double = 4) {
        guard loaded else { pendingTitle = text; return }
        run("ms.title(\(Self.literal(text)), \(seconds))")
    }

    /// The resource folder; the SwiftPM bundle is in `Contents/Resources` of the app, or next to the binary in a build.
    /// Not `Bundle.module`: `scripts/bundle.sh` type-checks the sources without SwiftPM's generated accessor.
    static var page: URL? {
        let url = Bundle.main.url(forResource: "MusicSync_MusicSyncApp", withExtension: "bundle")
            ?? Bundle.main.bundleURL.appendingPathComponent("MusicSync_MusicSyncApp.bundle")
        return Bundle(url: url)?.url(forResource: "index", withExtension: "html", subdirectory: "Visualizer")
            ?? Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Visualizer")  // iPad app
    }

    /// JSON options for `ms.configure`.
    func configure(_ json: String) {
        config = json
        if loaded { run("ms.configure(\(json))") }
        run("ms.configure(\(json))", in: warmView)
    }

    /// Sends the folder's presets to both pages: `.json` as they are, `.milk` without a `.json` to the converter.
    func loadUserPresets() {
        let (script, names) = Self.jsonPresets()
        if let script { run(script); run(script, in: warmView) }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.userFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "milk" {
            let name = file.deletingPathExtension().lastPathComponent
            guard !names.contains(name), !failed.contains(name),
                  let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
            run("ms.convert(\(Self.literal(name)), \(Self.literal(text)))")
        }
    }

    /// `ms.addPresets` with the folder's `.json` presets, and their names.
    private static func jsonPresets() -> (script: String?, names: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: userFolder, includingPropertiesForKeys: nil)) ?? []
        var extra: [String: Any] = [:]
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let preset = try? JSONSerialization.jsonObject(with: data) {
                extra[file.deletingPathExtension().lastPathComponent] = preset
            }
        }
        guard !extra.isEmpty, let json = try? JSONSerialization.data(withJSONObject: extra), let text = String(data: json, encoding: .utf8) else {
            return (nil, [])
        }
        return ("ms.addPresets(\(text))", Set(extra.keys))
    }

    func feed(_ left: [Float], _ right: [Float]) {
        let byte = { (x: Float) in UInt8(max(min(128 + x * 127, 255), 0)) }
        let mono = Data(zip(left, right).map { byte(($0 + $1) / 2) })
        run("ms.feed('\(mono.base64EncodedString())','\(Data(left.map(byte)).base64EncodedString())','\(Data(right.map(byte)).base64EncodedString())')")
    }

    private func run(_ script: String, in view: WKWebView? = nil) { (view ?? webView)?.evaluateJavaScript(script, completionHandler: nil) }

    private static func literal(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "''"
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let names = body["presets"] as? [String] { presets = names }
        if let name = body["current"] as? String { current = name }
        if let name = body["converted"] as? String, let preset = body["preset"] as? String {
            try? Data(preset.utf8).write(to: Self.userFolder.appendingPathComponent(name).appendingPathExtension("json"))
            run("ms.addPresets({\(Self.literal(name)): \(preset)})", in: warmView)
        }
        if let name = body["upcoming"] as? String { run("ms.select(\(Self.literal(name)), 0)", in: warmView) }
        if let name = body["failed"] as? String {
            failed.append(name)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === warmView {
            run("ms.configure(\(config))", in: webView)
            if let script = Self.jsonPresets().script { run(script, in: webView) }
            return
        }
        loaded = true
        run("ms.configure(\(config))")
        if let pendingTitle { title(pendingTitle) }
        pendingTitle = nil
        loadUserPresets()
    }
}

@MainActor struct MilkDropView {
    let player: Player
    let milkDrop: MilkDrop

    func makeView(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(milkDrop, name: "visualizer")
        let view = FullBleedWebView(frame: .zero, configuration: config)
        #if os(macOS)
        view.setValue(false, forKey: "drawsBackground")
        #else
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        view.navigationDelegate = milkDrop
        milkDrop.webView = view
        if let page = MilkDrop.page {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
            // Not in a window: it never draws, it only compiles.
            let warm = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
            warm.navigationDelegate = milkDrop
            milkDrop.warmView = warm
            if var parts = URLComponents(url: page, resolvingAgainstBaseURL: false) {
                parts.fragment = "warm"
                if let url = parts.url { warm.loadFileURL(url, allowingReadAccessTo: page.deletingLastPathComponent()) }
            }
        }
        coordinator.start { [player, milkDrop] in
            let samples = player.mixer.equalizer.samples.latest(1024, at: player.mixer.time)
            milkDrop.feed(samples.left, samples.right)
        }
        return view
    }

    static func dismantle(_ view: WKWebView, _ coordinator: Coordinator) {
        coordinator.timer?.invalidate()
        (view.navigationDelegate as? MilkDrop)?.warmView = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "visualizer")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Feeds the page 60 times a second.
    @MainActor final class Coordinator {
        var timer: Timer?

        func start(_ tick: @escaping @MainActor () -> Void) {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        }
    }
}

#if os(macOS)
extension MilkDropView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { dismantle(view, coordinator) }
}
#else
extension MilkDropView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { dismantle(view, coordinator) }
}
#endif

/// Draws under the title bar too: a plain web view insets its page by the window's safe area (a dark band on top in Now Playing).
final class FullBleedWebView: WKWebView {
    #if os(macOS)
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    #else
    override var safeAreaInsets: UIEdgeInsets { .zero }
    #endif
}
